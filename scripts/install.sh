#!/usr/bin/env bash
# DevBox Platform - インストールスクリプト (RHEL 9 系)
# 対応: AlmaLinux 9 / Rocky Linux 9 / RHEL 9
# 使い方: sudo bash install.sh
#
# 環境変数（任意）:
#   DEVBOX_DOMAIN          例: devbox.example.com  (デフォルト: devbox.example.com)
#   LLDAP_ADMIN_PASSWORD   初期管理者パスワード（未設定時は自動生成）
#   SKIP_LLDAP=yes         LLDAP のセットアップをスキップ

set -euo pipefail

DOMAIN="${DEVBOX_DOMAIN:-devbox.example.com}"
DEVBOX_DIR="/opt/devbox"
AUTH_LDAP_DIR="/opt/devbox/auth-ldap"
LLDAP_BASE_DN="dc=devbox,dc=local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

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

# ─── LLDAP セットアップ関数（dnf の RPM パッケージ、ビルド不要） ──────────────
#
# LLDAP は Fedora/EPEL に公式パッケージが無いため、openSUSE Build Service (OBS)
# が提供する CentOS 9 Stream 向け非公式ビルド（GPG 署名済み）を dnf リポジトリ
# として登録して利用する。以後は `dnf update` だけで追随でき、Authentik の
# ようにアップデートのたびに npm/uv でソースビルドする必要はない。
#
# Forward Auth は nginx の auth_request から、LLDAP に対して LDAP bind を行う
# だけの小さな Python 標準ライブラリ製ブリッジ（auth_ldap.py）で実現する。
# ldapwhoami は openldap-clients（RHEL 公式パッケージ）を利用する。

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

  dnf install -y lldap lldap-set-password openldap-clients

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

  # ─── 設定ファイル ─────────────────────────────────────────────────────────────
  sed -i \
    -e "s|^jwt_secret = .*|jwt_secret = \"${LLDAP_JWT_SECRET}\"|" \
    -e "s|^key_seed = .*|key_seed = \"${LLDAP_KEY_SEED}\"|" \
    -e "s|^ldap_user_pass = .*|ldap_user_pass = \"${LLDAP_ADMIN_PASSWORD}\"|" \
    -e "s|^#ldap_base_dn = .*|ldap_base_dn = \"${LLDAP_BASE_DN}\"|" \
    /etc/lldap/lldap_config.toml
  chown -R lldap:lldap /etc/lldap

  systemctl enable --now lldap

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=17170/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  fi

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

  setup_auth_ldap || return 1

  echo ""
  echo -e "  ${CYAN}LLDAP 管理画面${NC}: http://${DOMAIN}:17170"
  echo -e "  ${CYAN}Admin${NC}    : ${LLDAP_ADMIN_USER}"
  echo -e "  ${CYAN}Password${NC} : ${LLDAP_ADMIN_PASSWORD}"
  echo    "  ※ 認証情報は /etc/devbox/lldap.env に保存されています"
}

# ─── auth-ldap ブリッジ（nginx auth_request → LDAP bind、単なる Python スクリプト） ──
setup_auth_ldap() {
  info "auth-ldap ブリッジをセットアップ中..."

  mkdir -p "${AUTH_LDAP_DIR}"
  cp "${REPO_DIR}/scripts/auth-ldap/auth_ldap.py" "${AUTH_LDAP_DIR}/auth_ldap.py"

  id devbox-auth &>/dev/null || useradd -r -d "${AUTH_LDAP_DIR}" -s /sbin/nologin devbox-auth

  # shellcheck disable=SC1091
  source /etc/devbox/lldap.env

  cat > "${AUTH_LDAP_DIR}/.env" << ENV_EOF
LDAP_URL=ldap://127.0.0.1:3890
LDAP_BASE_DN=${LLDAP_BASE_DN}
LISTEN_HOST=127.0.0.1
LISTEN_PORT=9091
ENV_EOF
  chmod 600 "${AUTH_LDAP_DIR}/.env"
  chown -R devbox-auth:devbox-auth "${AUTH_LDAP_DIR}"

  cat > /etc/systemd/system/auth-ldap.service << UNIT_EOF
[Unit]
Description=DevBox auth_request -> LDAP (LLDAP) bridge
After=lldap.service
Requires=lldap.service

[Service]
Type=simple
User=devbox-auth
Group=devbox-auth
WorkingDirectory=${AUTH_LDAP_DIR}
EnvironmentFile=${AUTH_LDAP_DIR}/.env
ExecStart=/usr/bin/python3 ${AUTH_LDAP_DIR}/auth_ldap.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

  systemctl daemon-reload
  systemctl enable --now auth-ldap

  info "auth-ldap ブリッジの起動を待機中..."
  local ready=false
  for i in $(seq 1 30); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:9091/verify" 2>/dev/null)" == "401" ]]; then
      ready=true; break
    fi
    sleep 1
  done

  if [[ "$ready" == "false" ]]; then
    warn "auth-ldap ブリッジの起動がタイムアウトしました"
    warn "  journalctl -u auth-ldap -n 50 --no-pager"
    return 1
  fi
  ok "auth-ldap ブリッジ起動完了"
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
dnf install -y curl wget git python3 openssl

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

# ─── 3. Xpra + xpra-html5 ─────────────────────────────────────────────────────
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

# ─── 4. XFCE デスクトップ ─────────────────────────────────────────────────────
if ! command -v xfce4-session &>/dev/null; then
  info "XFCE をインストール中..."
  dnf install -y xfce4-session xfce4-terminal xfwm4 xfdesktop xfce4-panel Thunar
  ok "XFCE インストール完了"
else
  ok "XFCE は導入済み"
fi

# ─── 5. nginx ──────────────────────────────────────────────────────────────────
if ! command -v nginx &>/dev/null; then
  info "nginx をインストール中..."
  dnf install -y nginx
fi
systemctl enable nginx
ok "nginx 準備完了: $(nginx -v 2>&1)"

# ─── 6. SELinux — nginx のプロキシ通信を許可 ──────────────────────────────────
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
  info "SELinux ポリシーを設定中..."
  setsebool -P httpd_can_network_connect 1 || warn "setsebool に失敗しました（続行します）"
  ok "SELinux: httpd_can_network_connect 有効"
fi

# ─── 7. firewalld — HTTP/HTTPS を開放 ─────────────────────────────────────────
if systemctl is-active --quiet firewalld 2>/dev/null; then
  info "firewalld で HTTP/HTTPS を開放中..."
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
  ok "firewalld 設定完了"
fi

# ─── 8. LLDAP セットアップ ──────────────────────────────────────────────────
LLDAP_ENABLED="no"
LLDAP_ADMIN_URL="http://127.0.0.1:17170"

if [[ "${SKIP_LLDAP:-no}" == "yes" ]]; then
  warn "LLDAP のセットアップをスキップします (SKIP_LLDAP=yes)"
else
  info "LLDAP をセットアップ中..."
  if setup_lldap; then
    LLDAP_ENABLED="yes"
    ok "LLDAP セットアップ完了"
  else
    warn "LLDAP のセットアップに失敗しました。認証なしで続行します"
  fi
fi

# ─── 9. ディレクトリ作成 ──────────────────────────────────────────────────────
info "ディレクトリを作成中..."
mkdir -p "${DEVBOX_DIR}/portal" /etc/devbox/users /etc/nginx/conf.d/devbox-users

if command -v restorecon &>/dev/null; then
  restorecon -Rv "${DEVBOX_DIR}/portal" 2>/dev/null || true
elif command -v chcon &>/dev/null; then
  chcon -Rt httpd_sys_content_t "${DEVBOX_DIR}/portal" 2>/dev/null || true
fi
ok "ディレクトリ作成完了"

# ─── 10. ポータル HTML ────────────────────────────────────────────────────────
info "ポータル HTML をコピー中..."
cp "${REPO_DIR}/portal/index.html" "${DEVBOX_DIR}/portal/index.html"
ok "ポータル HTML → ${DEVBOX_DIR}/portal/index.html"

# ─── 11. systemd テンプレートユニット ────────────────────────────────────────
info "systemd ユニットをインストール中..."
for unit in devbox@.target vscode@.service xpra@.service; do
  cp "${REPO_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
ok "systemd ユニットインストール完了"

# ─── 12. プラットフォーム設定を保存（adduser.sh が参照） ─────────────────────
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
PLATFORM_EOF
chmod 600 /etc/devbox/platform.conf

# ─── 13. nginx メイン設定 ─────────────────────────────────────────────────────
info "nginx を設定中..."

if [[ "$LLDAP_ENABLED" == "yes" ]]; then
  cat > /etc/nginx/conf.d/devbox.conf << NGINX_EOF
# DevBox Platform - メインサーバー設定（install.sh が生成）
server {
    listen 80;
    server_name ${DOMAIN};

    location = /auth-ldap {
        internal;
        proxy_pass              http://127.0.0.1:9091/verify;
        proxy_pass_request_body off;
        proxy_set_header        Content-Length "";
        proxy_set_header        Authorization \$http_authorization;
    }

    location @basic_auth_prompt {
        add_header WWW-Authenticate 'Basic realm="DevBox Platform"' always;
        return 401;
    }

    location = / {
        return 200 "DevBox Platform\n";
        add_header Content-Type text/plain;
    }

    include /etc/nginx/conf.d/devbox-users/*.conf;
}
NGINX_EOF
  ok "nginx: LDAP (LLDAP) Basic 認証付きで設定"
else
  warn "nginx: 認証なしで設定（LLDAP 未設定）"
  cat > /etc/nginx/conf.d/devbox.conf << NGINX_EOF
# DevBox Platform - 認証なし設定（install.sh が生成）
# LLDAP を設定したら SKIP_LLDAP=no で install.sh を再実行
server {
    listen 80;
    server_name ${DOMAIN};

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
echo "  アクセス    : http://${DOMAIN}/<username>/"
if [[ "$LLDAP_ENABLED" == "yes" ]]; then
  echo "  LLDAP       : http://${DOMAIN}:17170"
fi
echo ""
