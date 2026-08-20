#!/usr/bin/env bash
# DevBox Platform - front サーバー インストールスクリプト (RHEL 9 系)
# 対応: AlmaLinux 9 / Rocky Linux 9 / RHEL 9
# 使い方: sudo bash install-front.sh
#
# front サーバーの役割: 認証（LLDAP + LemonLDAP::NG）とポータル配信、
# および各 backend サーバーへの認証済みリバースプロキシ。
# ユーザーごとの実体（vscode@/xpra@ サービスや Java/Tomcat 等の開発ツール）は
# install-backend.sh を実行した backend サーバー側に置く。
#
# 1台構成にしたい場合は、このスクリプトと install-backend.sh を同一ホストで
# 実行すればよい（FRONT_ALLOWED_SOURCE=127.0.0.1 を指定）。front 用と
# backend 用の nginx 設定はファイル名・リッスンポートが分かれているため
# 同居しても衝突しない。
#
# 環境変数（任意）:
#   DEVBOX_DOMAIN          例: devbox.example.com  (デフォルト: devbox.example.com)
#   LLDAP_ADMIN_PASSWORD   初期管理者パスワード（未設定時は自動生成）
#   SKIP_LLDAP=yes         LLDAP / LemonLDAP::NG のセットアップをスキップ
#   ANTHROPIC_API_KEY      必須。Headroom（LLMプロキシ）が使う実 Anthropic APIキー
#   BACKEND_ALLOWED_SOURCES  Headroomのポートを許可する backend の IP/CIDR
#                            （カンマ区切りで複数可）。未設定時は一切開放しない
#   USER_HOME_BASE         任意。ポータルがVS Code初回アクセス時に自動で開く
#                          ~/workspace のパス計算に使う（デフォルト: /home）。
#                          backend側のinstall-backend.envのUSER_HOME_BASEと
#                          同じ値を指定すること（一致しないと初回オープンの
#                          パスが正しく解決できない）。

set -euo pipefail

DOMAIN="${DEVBOX_DOMAIN:-devbox.example.com}"
DEVBOX_DIR="/opt/devbox"
USER_HOME_BASE="${USER_HOME_BASE:-/home}"
USER_HOME_BASE="${USER_HOME_BASE%/}"
LLDAP_BASE_DN="dc=devbox,dc=local"
LLNG_CLI="/usr/libexec/lemonldap-ng/bin/lemonldap-ng-cli"
TLS_DIR="/etc/devbox/tls"
TLS_CERT="${TLS_DIR}/devbox.crt"
TLS_KEY="${TLS_DIR}/devbox.key"
DEVBOX_HEADROOM_PORT=8787
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=../lib-common.sh
source "${SCRIPT_DIR}/../lib-common.sh"

# .env ファイルが存在すれば読み込む（環境変数を上書き）
for env_path in "${REPO_DIR}/install-front.env" "${SCRIPT_DIR}/install-front.env" "/etc/devbox/install-front.env"; do
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

  mkdir -p /etc/devbox

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
  # いないものもある）は devbox-front.conf と競合する（例: handler-nginx.conf の
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
  "timeout": 259200,
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

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash install-front.sh"
[[ "$USER_HOME_BASE" == /* ]] || die "USER_HOME_BASE は絶対パスで指定してください（指定値: ${USER_HOME_BASE}）"

if ! grep -qiE 'rhel|almalinux|rocky' /etc/os-release 2>/dev/null; then
  warn "RHEL 9 系以外の環境です。続行しますが動作を保証しません"
fi
MAJOR_VER=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
[[ "$MAJOR_VER" -lt 9 ]] && die "RHEL 9 以上が必要です (検出: ${MAJOR_VER})"

echo ""
echo "╔══════════════════════════════════╗"
echo "║   DevBox Platform - front        ║"
echo "║   RHEL 9 系                      ║"
echo "╚══════════════════════════════════╝"
echo ""

# ─── 1. EPEL + 基本パッケージ ─────────────────────────────────────────────────
info "EPEL リポジトリと基本パッケージをインストール中..."
dnf install -y epel-release
dnf install -y curl python3 openssl

dnf config-manager --set-enabled crb 2>/dev/null || \
  dnf config-manager --set-enabled powertools 2>/dev/null || \
  warn "CRB/PowerTools の有効化に失敗しました（続行します）"
ok "基本パッケージ完了"

# ─── 2. nginx ──────────────────────────────────────────────────────────────────
if ! command -v nginx &>/dev/null; then
  info "nginx をインストール中..."
  dnf install -y nginx
fi
systemctl enable nginx
ok "nginx 準備完了: $(nginx -v 2>&1)"

# ─── 3. TLS 証明書（自己署名） ─────────────────────────────────────────────────
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

# ─── 4. SELinux — nginx のプロキシ通信を許可 ──────────────────────────────────
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
  info "SELinux ポリシーを設定中..."
  setsebool -P httpd_can_network_connect 1 || warn "setsebool に失敗しました（続行します）"
  ok "SELinux: httpd_can_network_connect 有効"
fi

# ─── 5. firewalld — HTTPS を開放 ───────────────────────────────────────────────
# front は 443 のみで待ち受ける（80 は backend 専用のため front では使わない。
# 詳細は下記 nginx メイン設定のコメント参照）。
if systemctl is-active --quiet firewalld 2>/dev/null; then
  info "firewalld で HTTPS を開放中..."
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
  ok "firewalld 設定完了"
fi

# ─── 6. LLDAP + LemonLDAP::NG セットアップ ────────────────────────────────────
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

# ─── 7. ディレクトリ作成 ──────────────────────────────────────────────────────
info "ディレクトリを作成中..."
mkdir -p "${DEVBOX_DIR}/portal" /etc/devbox/registrations /etc/nginx/conf.d/devbox-front-users

if command -v restorecon &>/dev/null; then
  restorecon -Rv "${DEVBOX_DIR}/portal" 2>/dev/null || true
elif command -v chcon &>/dev/null; then
  chcon -Rt httpd_sys_content_t "${DEVBOX_DIR}/portal" 2>/dev/null || true
fi
ok "ディレクトリ作成完了"

# ─── 8. ポータル HTML ─────────────────────────────────────────────────────────
# __USER_HOME_BASE__ プレースホルダーを USER_HOME_BASE の実際の値に置換して
# 配置する（VS Code初回アクセス時に自動で開く ~/workspace のパス計算に使う。
# backend側のUSER_HOME_BASEと一致している必要がある）。
info "ポータル HTML をコピー中..."
sed "s|__USER_HOME_BASE__|${USER_HOME_BASE}|g" "${REPO_DIR}/portal/index.html" > "${DEVBOX_DIR}/portal/index.html"
ok "ポータル HTML → ${DEVBOX_DIR}/portal/index.html"

# ─── 9. Headroom（LLMプロキシ） ────────────────────────────────────────────────
# 各ユーザーが Anthropic の実 API キーを個別に持たずに済むよう、front に
# Headroom を導入し、実キーは front だけが保持する。backend 上のユーザーは
# ANTHROPIC_BASE_URL でここを経由する（scripts/backend/lib-claude.sh 参照）。
[[ -z "${ANTHROPIC_API_KEY:-}" ]] && die "ANTHROPIC_API_KEY が未設定です。install-front.env に指定してください"

info "Headroom（LLMプロキシ）をインストール中..."
if ! command -v python3.11 &>/dev/null; then
  # headroom-ai は Python 3.10 以上が必須。RHEL 9 系の既定 python3 は 3.9 の
  # ため、AppStream の python3.11 を別途インストールして使う（実機確認済み:
  # 既定 python3.9 では "No matching distribution found" で失敗する）。
  dnf install -y python3.11 python3.11-pip
fi
if ! command -v headroom &>/dev/null; then
  python3.11 -m pip install "headroom-ai[proxy]"
fi
HEADROOM_BIN="$(command -v headroom || echo "")"
if [[ -z "$HEADROOM_BIN" ]]; then
  die "headroom コマンドが見つかりません（pip install に失敗した可能性があります）"
elif [[ "$HEADROOM_BIN" != "/usr/local/bin/headroom" ]]; then
  warn "headroom の実体が /usr/local/bin/headroom ではありません（${HEADROOM_BIN}）"
  warn "  systemd/headroom.service の ExecStart パスを合わせて修正してください"
fi
ok "Headroom インストール完了: $(headroom --version 2>&1 | head -1)"

# front↔backend（Headroomクライアント）間の共有シークレット。
# DEVBOX_INTERNAL_TOKEN（backend→front用、逆方向）とは別のトークン。
# 既存インストールを再実行した場合は既存の値を使い回す。
DEVBOX_HEADROOM_TOKEN="${DEVBOX_HEADROOM_TOKEN:-}"
if [[ -z "$DEVBOX_HEADROOM_TOKEN" && -f /etc/devbox/platform.conf ]]; then
  DEVBOX_HEADROOM_TOKEN=$(grep '^DEVBOX_HEADROOM_TOKEN=' /etc/devbox/platform.conf | cut -d= -f2 || echo "")
fi
[[ -z "$DEVBOX_HEADROOM_TOKEN" ]] && DEVBOX_HEADROOM_TOKEN=$(openssl rand -hex 32)

# Headroom は ANTHROPIC_API_KEY 環境変数だけでは上流(Anthropic)を認証しない
# （実機検証済み。設定しても upstream へ x-api-key が付与されず
# "x-api-key header is required" で拒否される）。ANTHROPIC_TARGET_API_HEADERS
# で x-api-key・anthropic-version を強制上書き注入させるのが正しい方法。
# この値は内部にダブルクォートを含む JSON なので、systemd/headroom.service
# が bash 経由で source する前提でシングルクォートで囲む（実機検証済み:
# ダブルクォートを裸で置くと bash の source 時にクォートが剥がされ壊れる）。
# テンプレート（templates/headroom.env.template）の __PLACEHOLDER__ を sed で
# 置換して生成する。置換値は sed のメタ文字（\ & 区切り文字|）を含みうる
# 外部由来の値（APIキー等）なので、置換前にエスケープする。
_headroom_sed_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//&/\\&}
  s=${s//|/\\|}
  printf '%s' "$s"
}
mkdir -p /etc/devbox
sed \
  -e "s|__ANTHROPIC_API_KEY__|$(_headroom_sed_escape "$ANTHROPIC_API_KEY")|" \
  -e "s|__DEVBOX_HEADROOM_TOKEN__|$(_headroom_sed_escape "$DEVBOX_HEADROOM_TOKEN")|" \
  -e "s|__DEVBOX_HEADROOM_PORT__|$(_headroom_sed_escape "$DEVBOX_HEADROOM_PORT")|" \
  "${REPO_DIR}/templates/headroom.env.template" > /etc/devbox/headroom.env
chmod 600 /etc/devbox/headroom.env

cp "${REPO_DIR}/systemd/headroom.service" /etc/systemd/system/headroom.service
systemctl daemon-reload
systemctl enable --now headroom
ok "Headroom 起動完了（ポート ${DEVBOX_HEADROOM_PORT}）"

# backend からのみ到達可能にする（front→backend の DEVBOX_INTERNAL_TOKEN と
# 対称の、backend→front 向けのアクセス制限）。
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if [[ -n "${BACKEND_ALLOWED_SOURCES:-}" ]]; then
    info "firewalld で ${DEVBOX_HEADROOM_PORT} 番を backend からのみ開放中..."
    IFS=',' read -ra _backend_sources <<< "$BACKEND_ALLOWED_SOURCES"
    for src in "${_backend_sources[@]}"; do
      src="$(echo -n "$src" | xargs)"
      [[ -z "$src" ]] && continue
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"${src}\" port protocol=\"tcp\" port=\"${DEVBOX_HEADROOM_PORT}\" accept"
    done
    firewall-cmd --reload
    ok "firewalld 設定完了（許可元: ${BACKEND_ALLOWED_SOURCES}）"
  else
    warn "BACKEND_ALLOWED_SOURCES が未設定のため、${DEVBOX_HEADROOM_PORT} 番ポートは firewalld で開放しません"
    warn "  backend サーバーからの接続を許可するには、後で以下を実行してください:"
    warn "  firewall-cmd --permanent --zone=public --add-rich-rule='rule family=\"ipv4\" source address=\"<backendのIP>\" port protocol=\"tcp\" port=\"${DEVBOX_HEADROOM_PORT}\" accept'"
    warn "  firewall-cmd --reload"
  fi
fi

# ─── 10. プラットフォーム設定を保存（register-user.sh が参照） ───────────────
LLDAP_ADMIN_USER=""
LLDAP_ADMIN_PASSWORD=""
[[ -f /etc/devbox/lldap.env ]] && {
  LLDAP_ADMIN_USER=$(grep '^LLDAP_ADMIN_USER=' /etc/devbox/lldap.env | cut -d= -f2 || echo "")
  LLDAP_ADMIN_PASSWORD=$(grep '^LLDAP_ADMIN_PASSWORD=' /etc/devbox/lldap.env | cut -d= -f2 || echo "")
}

# backend の 80 番ポートは front からのプロキシしか受け付けないよう
# firewalld で制限するが、それだけに頼らない多層防御として、このトークンを
# 各 backend にも配布し、front→backend 間の全リクエストに付与・検証させる
# （install-backend.sh 側。firewalld が無効/誤設定でも直接アクセスは拒否される）。
# 既存インストールを再実行した場合は既存の値を使い回す。
DEVBOX_INTERNAL_TOKEN="${DEVBOX_INTERNAL_TOKEN:-}"
if [[ -z "$DEVBOX_INTERNAL_TOKEN" && -f /etc/devbox/platform.conf ]]; then
  DEVBOX_INTERNAL_TOKEN=$(grep '^DEVBOX_INTERNAL_TOKEN=' /etc/devbox/platform.conf | cut -d= -f2 || echo "")
fi
[[ -z "$DEVBOX_INTERNAL_TOKEN" ]] && DEVBOX_INTERNAL_TOKEN=$(openssl rand -hex 32)

cat > /etc/devbox/platform.conf << PLATFORM_EOF
DEVBOX_DOMAIN=${DOMAIN}
LLDAP_URL=${LLDAP_ADMIN_URL}
LLDAP_BASE_DN=${LLDAP_BASE_DN}
LLDAP_ADMIN_USER=${LLDAP_ADMIN_USER}
LLDAP_ADMIN_PASSWORD=${LLDAP_ADMIN_PASSWORD}
LLDAP_ENABLED=${LLDAP_ENABLED}
DEVBOX_INTERNAL_TOKEN=${DEVBOX_INTERNAL_TOKEN}
DEVBOX_HEADROOM_TOKEN=${DEVBOX_HEADROOM_TOKEN}
PLATFORM_EOF
chmod 600 /etc/devbox/platform.conf

# ─── 11. nginx メイン設定 ─────────────────────────────────────────────────────
info "nginx を設定中..."

if [[ "$LLDAP_ENABLED" == "yes" ]]; then
  cat > /etc/nginx/conf.d/devbox-front.conf << NGINX_EOF
# DevBox Platform - front メインサーバー設定（install-front.sh が生成）
map \$lmlocation \$lmerror_location {
    ~^      \$lmlocation;
    default @lmAuth401;
}
upstream llng_upstream {
    server unix:/run/llng-fastcgi-server/llng-fastcgi.sock;
}
# backend サーバーは 80 番ポートしか開放できないため、front は 80 番を
# 使わない（HTTP→HTTPS の自動リダイレクトは提供しない）。ユーザーは
# https:// を直接指定してアクセスすること。
server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;

    # \$lmlocation・\$original_uri は本来ユーザー毎の nginx 設定
    # （devbox-front-users/*.conf）内で set / auth_request_set により定義されるが、
    # まだ一人もユーザーを登録していないときはその宣言がどこにも存在せず、
    # map ディレクティブや /lmauth の参照先が見つからずに nginx の設定検証が
    # 失敗する。ここで空文字のデフォルトを宣言し、devbox-front.conf 単体で常に
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

    include /etc/nginx/conf.d/devbox-front-users/*.conf;
}
NGINX_EOF
  ok "nginx: LemonLDAP::NG（専用ログイン画面 + LDAP 認証）付きで設定"
else
  warn "nginx: 認証なしで設定（LLDAP / LemonLDAP::NG 未設定）"
  cat > /etc/nginx/conf.d/devbox-front.conf << NGINX_EOF
# DevBox Platform - front 認証なし設定（install-front.sh が生成）
# LLDAP を設定したら SKIP_LLDAP=no で install-front.sh を再実行
# backend サーバーは 80 番ポートしか開放できないため、front は 80 番を
# 使わない（HTTP→HTTPS の自動リダイレクトは提供しない）。ユーザーは
# https:// を直接指定してアクセスすること。
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

    include /etc/nginx/conf.d/devbox-front-users/*.conf;
}
NGINX_EOF
fi

nginx -t && systemctl start nginx && ok "nginx 設定完了" || die "nginx 設定に失敗しました"

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  front インストール完了！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "次のステップ:"
echo "  1. backend サーバーで scripts/backend/install-backend.sh を実行"
echo "     （FRONT_ALLOWED_SOURCE=<このホストのIP/CIDR> と、下記の"
echo "      DEVBOX_INTERNAL_TOKEN・HEADROOM_BASE_URL・DEVBOX_HEADROOM_TOKEN"
echo "      を install-backend.env に指定）"
echo "  2. backend で scripts/backend/adduser-backend.sh <username> <email> を実行してユーザーを作成"
echo "  3. この front サーバーで"
echo "     scripts/front/register-user.sh <username> --backend <backendのIP> を実行して登録"
echo ""
echo -e "  ${YELLOW}DEVBOX_INTERNAL_TOKEN${NC}（backend の install-backend.env にそのままコピーしてください）:"
echo "  ${DEVBOX_INTERNAL_TOKEN}"
echo ""
echo -e "  ${YELLOW}DEVBOX_HEADROOM_TOKEN${NC}（同じく install-backend.env にコピー）:"
echo "  ${DEVBOX_HEADROOM_TOKEN}"
echo ""
echo -e "  ${YELLOW}HEADROOM_BASE_URL${NC}（同じく install-backend.env に指定）:"
echo "  http://<このホストのIP>:${DEVBOX_HEADROOM_PORT}"
echo ""
echo "  ※ これらのトークンは他人に見せず、/etc/devbox/platform.conf"
echo "     （権限600）にのみ保存されています。"
echo ""
echo "  アクセス: https://${DOMAIN}/<username>/"
if [[ "$LLDAP_ENABLED" == "yes" ]]; then
  echo "  LLDAP   : https://${DOMAIN}/lldap/"
fi
echo ""
