#!/usr/bin/env bash
# DevBox Platform - インストールスクリプト (RHEL 9 系)
# 対応: AlmaLinux 9 / Rocky Linux 9 / RHEL 9
# 使い方: sudo bash install.sh
#
# 環境変数（任意）:
#   DEVBOX_DOMAIN          例: devbox.example.com  (デフォルト: devbox.example.com)
#   LLDAP_ADMIN_PASSWORD   初期管理者パスワード（未設定時は自動生成）
#   SKIP_LLDAP=yes         LLDAP / LemonLDAP::NG のセットアップをスキップ

set -euo pipefail

DOMAIN="${DEVBOX_DOMAIN:-devbox.example.com}"
DEVBOX_DIR="/opt/devbox"
LLDAP_BASE_DN="dc=devbox,dc=local"
LLNG_CLI="/usr/libexec/lemonldap-ng/bin/lemonldap-ng-cli"
TLS_DIR="/etc/devbox/tls"
TLS_CERT="${TLS_DIR}/devbox.crt"
TLS_KEY="${TLS_DIR}/devbox.key"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib-vscode-extensions.sh
source "${SCRIPT_DIR}/lib-vscode-extensions.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# .env ファイルが存在すれば読み込む（環境変数を上書き）
for env_path in "${REPO_DIR}/install.env" "${SCRIPT_DIR}/install.env" "/etc/devbox/install.env"; do
  if [[ -f "$env_path" ]]; then
    info ".env を読み込み中: ${env_path}"
    set -a
    # shellcheck disable=SC1090
    source "$env_path"
    set +a
    break
  fi
done

# .env を読み込んだ後に DOMAIN を再評価
DOMAIN="${DEVBOX_DOMAIN:-devbox.example.com}"

# LemonLDAP::NG は Cookie ドメインに IP アドレスを許可しない（RFC2396 hostname
# 文法で検証されており、数字だけのラベルは拒否される）。IP を指定された場合は
# sslip.io（IP をホスト名として解決する公開 DNS）経由のホスト名に変換する。
if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  warn "DEVBOX_DOMAIN が IP アドレスです。LemonLDAP::NG の制約により sslip.io 経由のホスト名に変換します"
  DOMAIN="${DOMAIN//./-}.sslip.io"
  info "実際のアクセス先: https://${DOMAIN}（インターネット経由の DNS 解決が必要です）"
fi

# ─── LLDAP + LemonLDAP::NG セットアップ（dnf の RPM パッケージ、ビルド不要） ──
#
# LLDAP は Fedora/EPEL に公式パッケージが無いため、openSUSE Build Service (OBS)
# が提供する CentOS 9 Stream 向け非公式ビルド（GPG 署名済み）を dnf リポジトリ
# として登録して利用する。以後は `dnf update` だけで追随でき、Authentik の
# ようにアップデートのたびに npm/uv でソースビルドする必要はない。
#
# 認証・認可（ログイン画面、セッション Cookie、nginx Forward Auth）は
# LemonLDAP::NG（EPEL 公式パッケージ）が担い、LLDAP を LDAP バックエンドとして
# 利用する。Basic 認証と異なり、専用ログインページとセッション管理を持つ。

setup_lldap() {
  info "LLDAP をインストール中（RPM パッケージ、ビルド不要）..."

  mkdir -p /etc/devbox /etc/devbox/users

  # ─── OBS リポジトリ登録 ──────────────────────────────────────────────────────
  if [[ ! -f /etc/yum.repos.d/lldap.repo ]]; then
    cat > /etc/yum.repos.d/lldap.repo << 'REPO_EOF'
[home_Masgalor_LLDAP]
name=LLDAP - Light LDAP implementation for authentication (CentOS-9_Stream)
type=rpm-md
baseurl=https://download.opensuse.org/repositories/home:/Masgalor:/LLDAP/CentOS-9_Stream/
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/home:/Masgalor:/LLDAP/CentOS-9_Stream/repodata/repomd.xml.key
enabled=1
REPO_EOF
  fi

  dnf install -y lldap lldap-set-password

  # ─── 認証情報の生成（初回のみ） ──────────────────────────────────────────────
  if [[ ! -f /etc/devbox/lldap.env ]]; then
    local jwt_secret key_seed admin_pass
    jwt_secret=$(openssl rand -hex 32)
    key_seed=$(openssl rand -hex 16)
    admin_pass="${LLDAP_ADMIN_PASSWORD:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}"

    cat > /etc/devbox/lldap.env << ENV_EOF
LLDAP_BASE_DN=${LLDAP_BASE_DN}
LLDAP_ADMIN_USER=admin
LLDAP_ADMIN_PASSWORD=${admin_pass}
LLDAP_JWT_SECRET=${jwt_secret}
LLDAP_KEY_SEED=${key_seed}
ENV_EOF
    chmod 600 /etc/devbox/lldap.env
  fi

  # shellcheck disable=SC1091
  source /etc/devbox/lldap.env

  # ─── 設定ファイル（HTTP は localhost のみ。nginx の /lldap/ 経由で公開） ────
  sed -i \
    -e "s|^jwt_secret = .*|jwt_secret = \"${LLDAP_JWT_SECRET}\"|" \
    -e "s|^key_seed = .*|key_seed = \"${LLDAP_KEY_SEED}\"|" \
    -e "s|^ldap_user_pass = .*|ldap_user_pass = \"${LLDAP_ADMIN_PASSWORD}\"|" \
    -e "s|^#ldap_base_dn = .*|ldap_base_dn = \"${LLDAP_BASE_DN}\"|" \
    -e 's|^#http_host = "0.0.0.0"|http_host = "127.0.0.1"|' \
    /etc/lldap/lldap_config.toml
  chown -R lldap:lldap /etc/lldap

  systemctl enable --now lldap

  # ─── 起動待機 ─────────────────────────────────────────────────────────────────
  info "LLDAP の起動を待機中..."
  local ready=false
  for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:17170/" &>/dev/null; then
      ready=true; break
    fi
    sleep 2
  done

  if [[ "$ready" == "false" ]]; then
    warn "LLDAP の起動がタイムアウトしました"
    warn "  journalctl -u lldap -n 50 --no-pager"
    return 1
  fi
  ok "LLDAP 起動完了"

  setup_lemonldap || return 1

  echo ""
  echo -e "  ${CYAN}LLDAP 管理画面${NC}: https://${DOMAIN}/lldap/"
  echo -e "  ${CYAN}Admin${NC}    : ${LLDAP_ADMIN_USER}"
  echo -e "  ${CYAN}Password${NC} : ${LLDAP_ADMIN_PASSWORD}"
  echo    "  ※ 認証情報は /etc/devbox/lldap.env に保存されています"
}

# ─── LemonLDAP::NG セットアップ（ログイン画面 + Forward Auth、EPEL 公式パッケージ） ──
setup_lemonldap() {
  info "LemonLDAP::NG をインストール中（EPEL 公式パッケージ）..."

  dnf install -y lemonldap-ng lemonldap-ng-fastcgi-server lemonldap-ng-selinux

  # パッケージが /etc/nginx/conf.d/ に配置するサンプル設定（server_name が
  # auth.example.com 等のプレースホルダードメインで、server{} で囲われて
  # いないものもある）は devbox.conf と競合する（例: handler-nginx.conf の
  # error_page が http コンテキストのデフォルトとして効いてしまう）ため削除する。
  rm -f /etc/nginx/conf.d/portal-nginx.conf \
        /etc/nginx/conf.d/manager-nginx.conf \
        /etc/nginx/conf.d/api-nginx.conf \
        /etc/nginx/conf.d/handler-nginx.conf \
        /etc/nginx/conf.d/test-nginx.conf

  # shellcheck disable=SC1091
  source /etc/devbox/lldap.env

  # ポータル/マネージャーの静的アセットを /_auth/static 配下に変更し、
  # nginx で LLDAP 用に予約する /static/ と衝突しないようにする。
  sed -i 's|^staticPrefix = /static$|staticPrefix = /_auth/static|' /etc/lemonldap-ng/lemonldap-ng.ini

  local merge_file
  merge_file="$(mktemp)"
  # lemonldap-ng-cli は内部で apache ユーザーに権限を落として設定ファイルを
  # 読むため、root:root 600（mktemp のデフォルト）のままだと権限エラーになる。
  chmod 644 "$merge_file"
  cat > "$merge_file" << JSON_EOF
{
  "authentication": "LDAP",
  "userDB": "LDAP",
  "passwordDB": "LDAP",
  "registerDB": "Null",
  "ldapServer": "ldap://127.0.0.1:3890",
  "ldapBase": "ou=people,${LLDAP_BASE_DN}",
  "managerDn": "uid=${LLDAP_ADMIN_USER},ou=people,${LLDAP_BASE_DN}",
  "managerPassword": "${LLDAP_ADMIN_PASSWORD}",
  "domain": "${DOMAIN}",
  "portal": "https://${DOMAIN}/_auth/",
  "staticPrefix": "/_auth/static",
  "cookieName": "devboxauth",
  "securedCookie": 1,
  "notification": 0,
  "applicationList": {},
  "locationRules": {
    "${DOMAIN}": { "default": "accept" }
  },
  "exportedVars": {},
  "groups": {},
  "macros": {},

  "portalDisplayRegister": 0,
  "portalDisplayAppslist": 0,
  "portalDisplayLoginHistory": 0,
  "portalDisplayRefreshMyRights": 0,
  "portalDisplayChangePassword": 1,
  "portalDisplayLogout": 1,
  "loginHistoryEnabled": 0,
  "portalCheckLogins": 0
}
JSON_EOF

  # 手組みの JSON を restore すると cfgDate 欠落で設定が壊れるため、必ず
  # merge（既存設定への差分適用、cfgDate 等は自動採番）を使う。
  if ! "$LLNG_CLI" -yes 1 merge "$merge_file" >/dev/null 2>&1; then
    rm -f "$merge_file"
    warn "LemonLDAP::NG の設定投入に失敗しました"
    return 1
  fi
  rm -f "$merge_file"

  systemctl enable --now llng-fastcgi-server

  info "LemonLDAP::NG FastCGI デーモンの起動を待機中..."
  local ready=false
  for i in $(seq 1 30); do
    if [[ -S /run/llng-fastcgi-server/llng-fastcgi.sock ]]; then
      ready=true; break
    fi
    sleep 1
  done

  if [[ "$ready" == "false" ]]; then
    warn "LemonLDAP::NG FastCGI デーモンの起動に失敗しました"
    warn "  journalctl -u llng-fastcgi-server -n 50 --no-pager"
    return 1
  fi
  ok "LemonLDAP::NG 起動完了"
}

# ──────────────────────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash install.sh"

if ! grep -qiE 'rhel|almalinux|rocky' /etc/os-release 2>/dev/null; then
  warn "RHEL 9 系以外の環境です。続行しますが動作を保証しません"
fi
MAJOR_VER=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
[[ "$MAJOR_VER" -lt 9 ]] && die "RHEL 9 以上が必要です (検出: ${MAJOR_VER})"

echo ""
echo "╔══════════════════════════════════╗"
echo "║   DevBox Platform Installer      ║"
echo "║   RHEL 9 系                      ║"
echo "╚══════════════════════════════════╝"
echo ""

# ─── 1. EPEL + 基本パッケージ ─────────────────────────────────────────────────
info "EPEL リポジトリと基本パッケージをインストール中..."
dnf install -y epel-release
dnf install -y curl wget git python3 openssl rsync

dnf config-manager --set-enabled crb 2>/dev/null || \
  dnf config-manager --set-enabled powertools 2>/dev/null || \
  warn "CRB/PowerTools の有効化に失敗しました（続行します）"
ok "基本パッケージ完了"

# ─── 2. VS Code（code serve-web） ─────────────────────────────────────────────
if ! command -v code &>/dev/null; then
  info "VS Code をインストール中..."
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  cat > /etc/yum.repos.d/vscode.repo << 'REPO_EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO_EOF
  dnf install -y code
  ok "VS Code インストール完了: $(code --version 2>&1 | head -1)"
else
  ok "VS Code は導入済み: $(code --version 2>&1 | head -1)"
fi

# ─── 3. Java（Eclipse Temurin 25 JDK） ────────────────────────────────────────
if ! java -version 2>&1 | grep -q '"25'; then
  info "Java（Temurin 25 JDK）をインストール中..."
  rpm --import https://packages.adoptium.net/artifactory/api/gpg/key/public

  # Adoptium は AlmaLinux/Rocky 向けの専用リポジトリを提供していないため、
  # RHEL 系はすべて "rhel" のリポジトリパスを利用する。
  cat > /etc/yum.repos.d/adoptium.repo << 'REPO_EOF'
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/rhel/$releasever/$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
REPO_EOF

  dnf install -y temurin-25-jdk
  ok "Java インストール完了: $(java -version 2>&1 | head -1)"
else
  ok "Java（25系）は導入済み: $(java -version 2>&1 | head -1)"
fi

# ─── 4. Claude Code CLI ────────────────────────────────────────────────────────
# システム全体に一度だけインストールする（dnf パッケージ、ユーザーごとの
# 個別インストールは不要）。VS Code の Claude 拡張機能はこの CLI を起動する
# ように adduser.sh がユーザーごとに設定する（claudeCode.claudeProcessWrapper）。
# CLI 自体の設定・セッション状態は $HOME/.claude/ に保存されるため、
# バイナリを共有していてもユーザー間で干渉しない。
if ! command -v claude &>/dev/null; then
  info "Claude Code CLI をインストール中..."
  cat > /etc/yum.repos.d/claude-code.repo << 'REPO_EOF'
[claude-code]
name=Claude Code
baseurl=https://downloads.claude.ai/claude-code/rpm/stable
enabled=1
gpgcheck=1
gpgkey=https://downloads.claude.ai/keys/claude-code.asc
REPO_EOF
  dnf install -y claude-code
  ok "Claude Code CLI インストール完了: $(claude --version 2>&1 | head -1)"
else
  ok "Claude Code CLI は導入済み: $(claude --version 2>&1 | head -1)"
fi
CLAUDE_BIN="$(command -v claude)"

# ─── 5. VS Code 拡張機能（マスターセットを root が管理） ─────────────────────
# ここでは root 専用のマスターディレクトリに拡張機能をインストールするだけで、
# 実際の配布は adduser.sh（新規ユーザー作成時）と update-extensions.sh
# （既存ユーザーへの更新反映）が行う。各ユーザーには独立したコピーを
# 配布し、本人には読み取り専用の権限しか与えないため、
#   - ユーザー間で拡張機能ディレクトリを共有しない（同時書き込みによる
#     extensions.json 破損などの干渉が起きない）
#   - 追加インストール・アンインストールは root（本スクリプト経由）以外
#     には行えない
# という2点を両立する。
info "VS Code 拡張機能（マスターセット）を準備中..."
vscode_ext_build_master
vscode_ext_sync_to_all_users
ok "VS Code 拡張機能マスターセット準備完了 → ${VSCODE_EXT_MASTER_DIR}"

# ─── 6. Xpra + xpra-html5 ─────────────────────────────────────────────────────
if ! command -v xpra &>/dev/null; then
  info "Xpra をインストール中..."
  dnf install -y xpra xorg-x11-server-Xvfb xauth xorg-x11-utils \
    dejavu-sans-fonts dbus-x11 xterm

  info "xpra-html5 をソースからインストール中..."
  git clone --depth=1 https://github.com/Xpra-org/xpra-html5 /tmp/xpra-html5
  cd /tmp/xpra-html5 && python3 ./setup.py install
  cd / && rm -rf /tmp/xpra-html5
  ok "Xpra インストール完了: $(xpra --version 2>&1 | head -1)"
else
  ok "Xpra は導入済み: $(xpra --version 2>&1 | head -1)"
fi

# ─── 7. XFCE デスクトップ ─────────────────────────────────────────────────────
if ! command -v xfce4-session &>/dev/null; then
  info "XFCE をインストール中..."
  dnf install -y xfce4-session xfce4-terminal xfwm4 xfdesktop xfce4-panel Thunar
  ok "XFCE インストール完了"
else
  ok "XFCE は導入済み"
fi

# ─── 8. nginx ──────────────────────────────────────────────────────────────────
if ! command -v nginx &>/dev/null; then
  info "nginx をインストール中..."
  dnf install -y nginx
fi
systemctl enable nginx
ok "nginx 準備完了: $(nginx -v 2>&1)"

# ─── 9. TLS 証明書（自己署名） ─────────────────────────────────────────────────
# VS Code Web の webview（拡張機能の Webview、Markdown プレビュー等）はブラウザの
# Web Crypto API（crypto.subtle）を使うが、これは HTTPS（セキュアコンテキスト）
# でしか利用できない。閉域網でも動くよう、外部の認証局を使わない自己署名証明書
# を生成して HTTPS 化する（初回アクセス時にブラウザの警告を承認する必要がある）。
info "TLS 証明書（自己署名）を準備中..."
mkdir -p "${TLS_DIR}"
if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TLS_KEY" -out "$TLS_CERT" \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN}" 2>/dev/null
  chmod 600 "$TLS_KEY"
  ok "自己署名証明書を生成 → ${TLS_CERT}"
else
  ok "TLS 証明書は既存のものを使用: ${TLS_CERT}"
fi

# ─── 10. SELinux — nginx のプロキシ通信を許可 ──────────────────────────────────
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
  info "SELinux ポリシーを設定中..."
  setsebool -P httpd_can_network_connect 1 || warn "setsebool に失敗しました（続行します）"
  ok "SELinux: httpd_can_network_connect 有効"
fi

# ─── 11. firewalld — HTTP/HTTPS を開放 ─────────────────────────────────────────
if systemctl is-active --quiet firewalld 2>/dev/null; then
  info "firewalld で HTTP/HTTPS を開放中..."
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
  ok "firewalld 設定完了"
fi

# ─── 12. LLDAP + LemonLDAP::NG セットアップ ────────────────────────────────────
LLDAP_ENABLED="no"
LLDAP_ADMIN_URL="http://127.0.0.1:17170"

if [[ "${SKIP_LLDAP:-no}" == "yes" ]]; then
  warn "LLDAP / LemonLDAP::NG のセットアップをスキップします (SKIP_LLDAP=yes)"
else
  info "LLDAP / LemonLDAP::NG をセットアップ中..."
  if setup_lldap; then
    LLDAP_ENABLED="yes"
    ok "LLDAP / LemonLDAP::NG セットアップ完了"
  else
    warn "LLDAP / LemonLDAP::NG のセットアップに失敗しました。認証なしで続行します"
  fi
fi

# ─── 13. ディレクトリ作成 ──────────────────────────────────────────────────────
info "ディレクトリを作成中..."
mkdir -p "${DEVBOX_DIR}/portal" /etc/devbox/users /etc/nginx/conf.d/devbox-users

if command -v restorecon &>/dev/null; then
  restorecon -Rv "${DEVBOX_DIR}/portal" 2>/dev/null || true
elif command -v chcon &>/dev/null; then
  chcon -Rt httpd_sys_content_t "${DEVBOX_DIR}/portal" 2>/dev/null || true
fi
ok "ディレクトリ作成完了"

# ─── 14. ポータル HTML ────────────────────────────────────────────────────────
info "ポータル HTML をコピー中..."
cp "${REPO_DIR}/portal/index.html" "${DEVBOX_DIR}/portal/index.html"
ok "ポータル HTML → ${DEVBOX_DIR}/portal/index.html"

# ─── 15. systemd テンプレートユニット ────────────────────────────────────────
info "systemd ユニットをインストール中..."
for unit in devbox@.target vscode@.service xpra@.service; do
  cp "${REPO_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
ok "systemd ユニットインストール完了"

# ─── 16. プラットフォーム設定を保存（adduser.sh が参照） ─────────────────────
LLDAP_ADMIN_USER=""
LLDAP_ADMIN_PASSWORD=""
[[ -f /etc/devbox/lldap.env ]] && {
  LLDAP_ADMIN_USER=$(grep '^LLDAP_ADMIN_USER=' /etc/devbox/lldap.env | cut -d= -f2 || echo "")
  LLDAP_ADMIN_PASSWORD=$(grep '^LLDAP_ADMIN_PASSWORD=' /etc/devbox/lldap.env | cut -d= -f2 || echo "")
}

cat > /etc/devbox/platform.conf << PLATFORM_EOF
DEVBOX_DOMAIN=${DOMAIN}
LLDAP_URL=${LLDAP_ADMIN_URL}
LLDAP_BASE_DN=${LLDAP_BASE_DN}
LLDAP_ADMIN_USER=${LLDAP_ADMIN_USER}
LLDAP_ADMIN_PASSWORD=${LLDAP_ADMIN_PASSWORD}
LLDAP_ENABLED=${LLDAP_ENABLED}
CLAUDE_BIN=${CLAUDE_BIN}
PLATFORM_EOF
chmod 600 /etc/devbox/platform.conf

# ─── 17. nginx メイン設定 ─────────────────────────────────────────────────────
info "nginx を設定中..."

if [[ "$LLDAP_ENABLED" == "yes" ]]; then
  cat > /etc/nginx/conf.d/devbox.conf << NGINX_EOF
# DevBox Platform - メインサーバー設定（install.sh が生成）
map \$lmlocation \$lmerror_location {
    ~^      \$lmlocation;
    default @lmAuth401;
}
upstream llng_upstream {
    server unix:/run/llng-fastcgi-server/llng-fastcgi.sock;
}
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;

    # \$lmlocation・\$original_uri は本来ユーザー毎の nginx 設定
    # （devbox-users/*.conf）内で set / auth_request_set により定義されるが、
    # まだ一人もユーザーを追加していないときはその宣言がどこにも存在せず、
    # map ディレクティブや /lmauth の参照先が見つからずに nginx の設定検証が
    # 失敗する。ここで空文字のデフォルトを宣言し、devbox.conf 単体で常に
    # 有効な設定になるようにする。
    set \$lmlocation "";
    set \$original_uri "";

    # --- LemonLDAP::NG ポータル（ログイン画面、/_auth/ 配下） ---
    location /_auth/static/ {
        alias /usr/share/lemonldap-ng/portal/htdocs/static/;
    }
    location ~ ^/_auth(?<sc>/.*\.psgi)(?:\$|/) {
        include /etc/nginx/fastcgi_params;
        fastcgi_pass              llng_upstream;
        fastcgi_param HTTP_HOST   \$host;
        fastcgi_param LLTYPE      psgi;
        fastcgi_param SCRIPT_FILENAME /usr/share/lemonldap-ng/portal/htdocs\$sc;
        fastcgi_param SCRIPT_NAME /_auth\$sc;
        fastcgi_split_path_info   ^(/_auth/.*\.psgi)(/.*)\$;
        fastcgi_param PATH_INFO   \$fastcgi_path_info;
        fastcgi_param UNIQUE_ID   \$request_id;
    }
    location /_auth/ {
        rewrite ^/_auth/(.*)\$ /_auth/index.psgi/\$1 last;
    }

    # --- LLDAP 管理画面（/lldap/。static/pkg/api/auth は絶対パス前提のため予約） ---
    location = /lldap {
        return 301 /lldap/;
    }
    location /lldap/ {
        proxy_pass       http://127.0.0.1:17170/;
        proxy_set_header Host \$host;
    }
    location /static/ {
        proxy_pass http://127.0.0.1:17170/static/;
    }
    location /pkg/ {
        proxy_pass http://127.0.0.1:17170/pkg/;
    }
    location /api/ {
        proxy_pass        http://127.0.0.1:17170/api/;
        proxy_set_header  Host \$host;
    }
    location /auth/ {
        proxy_pass        http://127.0.0.1:17170/auth/;
        proxy_set_header  Host \$host;
    }

    # --- Forward Auth ハンドラ（nginx auth_request から呼ばれる） ---
    location = /lmauth {
        internal;
        include /etc/nginx/fastcgi_params;
        fastcgi_pass             llng_upstream;
        fastcgi_pass_request_body off;
        fastcgi_param CONTENT_LENGTH "";
        fastcgi_param HTTP_HOST  \$host;
        fastcgi_param X_ORIGINAL_URI \$original_uri;
        fastcgi_param UNIQUE_ID  \$request_id;
    }
    location @lmAuth401 {
        return 401;
    }

    location = / {
        return 200 "DevBox Platform\n";
        add_header Content-Type text/plain;
    }

    include /etc/nginx/conf.d/devbox-users/*.conf;
}
NGINX_EOF
  ok "nginx: LemonLDAP::NG（専用ログイン画面 + LDAP 認証）付きで設定"
else
  warn "nginx: 認証なしで設定（LLDAP / LemonLDAP::NG 未設定）"
  cat > /etc/nginx/conf.d/devbox.conf << NGINX_EOF
# DevBox Platform - 認証なし設定（install.sh が生成）
# LLDAP を設定したら SKIP_LLDAP=no で install.sh を再実行
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;

    location = / {
        return 200 "DevBox Platform\n";
        add_header Content-Type text/plain;
    }

    include /etc/nginx/conf.d/devbox-users/*.conf;
}
NGINX_EOF
fi

nginx -t && systemctl start nginx && ok "nginx 設定完了" || die "nginx 設定に失敗しました"

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  インストール完了！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "次のステップ:"
echo "  ユーザー追加: sudo bash scripts/adduser.sh <username>"
echo "  アクセス    : https://${DOMAIN}/<username>/"
if [[ "$LLDAP_ENABLED" == "yes" ]]; then
  echo "  LLDAP       : https://${DOMAIN}/lldap/"
fi
echo ""
