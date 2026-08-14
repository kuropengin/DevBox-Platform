#!/usr/bin/env bash
# DevBox Platform - インストールスクリプト (RHEL 9 系)
# 対応: AlmaLinux 9 / Rocky Linux 9 / RHEL 9
# 使い方: sudo bash install.sh
#
# 環境変数（任意）:
#   DEVBOX_DOMAIN             例: devbox.example.com  (デフォルト: devbox.example.com)
#   AUTHENTIK_ADMIN_PASSWORD  初期管理者パスワード（未設定時は自動生成）
#   SKIP_AUTHENTIK=yes        Authentik のセットアップをスキップ

set -euo pipefail

DOMAIN="${DEVBOX_DOMAIN:-devbox.example.com}"
DEVBOX_DIR="/opt/devbox"
AUTHENTIK_DIR="/opt/authentik"
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

# ─── Authentik セットアップ関数（ネイティブインストール） ────────────────────────

setup_authentik() {
  info "Authentik を直接インストール中..."

  # PostgreSQL, Redis, Python 3.12, ビルド依存パッケージ
  dnf install -y \
    postgresql-server postgresql-contrib \
    python3.12 python3.12-devel \
    redis \
    gcc openssl-devel libpq-devel \
    openldap-devel cyrus-sasl-devel libffi-devel

  # PostgreSQL 初期化（初回のみ）
  if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
    info "PostgreSQL を初期化中..."
    postgresql-setup --initdb
  fi
  systemctl enable --now postgresql

  # pg_hba.conf にローカル接続のパスワード認証を追加（idempotent）
  local hba=/var/lib/pgsql/data/pg_hba.conf
  grep -q 'authentik' "$hba" || \
    sed -i '/^local\s*all\s*all/i local   authentik   authentik   md5\nhost    authentik   authentik   127.0.0.1/32   md5' "$hba"
  systemctl reload postgresql 2>/dev/null || systemctl restart postgresql

  # 認証情報の生成（初回のみ）
  if [[ ! -f /etc/devbox/authentik.env ]]; then
    local pg_pass secret_key admin_pass bootstrap_token
    pg_pass=$(openssl rand -hex 16)
    secret_key=$(openssl rand -hex 32)
    admin_pass="${AUTHENTIK_ADMIN_PASSWORD:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}"
    bootstrap_token=$(openssl rand -hex 32)

    cat > /etc/devbox/authentik.env << ENV_EOF
AUTHENTIK_PG_PASS=${pg_pass}
AUTHENTIK_SECRET_KEY=${secret_key}
AUTHENTIK_BOOTSTRAP_EMAIL=admin@${DOMAIN}
AUTHENTIK_BOOTSTRAP_PASSWORD=${admin_pass}
AUTHENTIK_BOOTSTRAP_TOKEN=${bootstrap_token}
ENV_EOF
    chmod 600 /etc/devbox/authentik.env
  fi

  # shellcheck disable=SC1091
  source /etc/devbox/authentik.env

  # PostgreSQL ユーザー・DB 作成（冪等）
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='authentik'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER authentik WITH PASSWORD '${AUTHENTIK_PG_PASS}';"
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='authentik'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE authentik OWNER authentik;"

  # Redis 起動
  systemctl enable --now redis

  # authentik システムユーザー
  id authentik &>/dev/null || useradd -r -d /opt/authentik -s /sbin/nologin authentik
  mkdir -p /opt/authentik
  chown authentik:authentik /opt/authentik

  # Python 仮想環境 + pip install authentik（初回のみ）
  if [[ ! -x /opt/authentik/venv/bin/ak ]]; then
    info "Authentik Python パッケージをインストール中（時間がかかる場合があります）..."
    sudo -u authentik python3.12 -m venv /opt/authentik/venv
    sudo -u authentik /opt/authentik/venv/bin/pip install --upgrade pip --quiet
    sudo -u authentik /opt/authentik/venv/bin/pip install authentik --quiet
  else
    ok "Authentik は導入済み"
  fi

  # サービス用環境ファイルを生成
  cat > /opt/authentik/.env << ENV_EOF
AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY}
AUTHENTIK_POSTGRESQL__HOST=localhost
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__PASSWORD=${AUTHENTIK_PG_PASS}
AUTHENTIK_REDIS__HOST=localhost
AUTHENTIK_BOOTSTRAP_EMAIL=${AUTHENTIK_BOOTSTRAP_EMAIL}
AUTHENTIK_BOOTSTRAP_PASSWORD=${AUTHENTIK_BOOTSTRAP_PASSWORD}
AUTHENTIK_BOOTSTRAP_TOKEN=${AUTHENTIK_BOOTSTRAP_TOKEN}
AUTHENTIK_ERROR_REPORTING__ENABLED=false
ENV_EOF
  chown authentik:authentik /opt/authentik/.env
  chmod 600 /opt/authentik/.env

  # データベースマイグレーション
  info "データベースマイグレーションを実行中..."
  sudo -u authentik /opt/authentik/venv/bin/ak migrate

  # systemd サービスを登録
  cat > /etc/systemd/system/authentik-server.service << UNIT_EOF
[Unit]
Description=Authentik Server
After=postgresql.service redis.service
Requires=postgresql.service redis.service

[Service]
Type=simple
User=authentik
Group=authentik
WorkingDirectory=/opt/authentik
EnvironmentFile=/opt/authentik/.env
ExecStart=/opt/authentik/venv/bin/ak server
Restart=on-failure
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT_EOF

  cat > /etc/systemd/system/authentik-worker.service << UNIT_EOF
[Unit]
Description=Authentik Worker
After=authentik-server.service
Requires=postgresql.service redis.service

[Service]
Type=simple
User=authentik
Group=authentik
WorkingDirectory=/opt/authentik
EnvironmentFile=/opt/authentik/.env
ExecStart=/opt/authentik/venv/bin/ak worker
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

  systemctl daemon-reload
  systemctl enable --now authentik-server authentik-worker

  # firewalld に Authentik ポートを追加
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=9000/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  fi

  # 起動待機（最大 5 分）
  info "Authentik の起動を待機中（最大 5 分）..."
  local ready=false
  for i in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:9000/-/health/ready/" &>/dev/null; then
      ready=true; break
    fi
    sleep 5
  done

  if [[ "$ready" == "false" ]]; then
    warn "Authentik の起動がタイムアウトしました"
    warn "  journalctl -u authentik-server -n 50 --no-pager"
    return 1
  fi

  ok "Authentik 起動完了"
  configure_authentik_api "${AUTHENTIK_BOOTSTRAP_TOKEN}" && ok "Authentik API 設定完了" || warn "Authentik API 設定に失敗しました"

  echo ""
  echo -e "  ${CYAN}Authentik 管理画面${NC}: http://${DOMAIN}:9000"
  echo -e "  ${CYAN}Email${NC}    : ${AUTHENTIK_BOOTSTRAP_EMAIL}"
  echo -e "  ${CYAN}Password${NC} : ${AUTHENTIK_BOOTSTRAP_PASSWORD}"
  echo    "  ※ 認証情報は /etc/devbox/authentik.env に保存されています"
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

# ─── 8. Authentik セットアップ ────────────────────────────────────────────────
AUTHENTIK_ENABLED="no"
AUTHENTIK_API_URL="http://127.0.0.1:9000"

if [[ "${SKIP_AUTHENTIK:-no}" == "yes" ]]; then
  warn "Authentik のセットアップをスキップします (SKIP_AUTHENTIK=yes)"
else
  info "Authentik をセットアップ中..."
  if setup_authentik; then
    AUTHENTIK_ENABLED="yes"
    ok "Authentik セットアップ完了"
  else
    warn "Authentik のセットアップに失敗しました。認証なしで続行します"
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
AUTHENTIK_TOKEN=""
[[ -f "${AUTHENTIK_DIR}/.env" ]] && \
  AUTHENTIK_TOKEN=$(grep AUTHENTIK_BOOTSTRAP_TOKEN "${AUTHENTIK_DIR}/.env" | cut -d= -f2 || echo "")

cat > /etc/devbox/platform.conf << PLATFORM_EOF
DEVBOX_DOMAIN=${DOMAIN}
AUTHENTIK_URL=${AUTHENTIK_API_URL}
AUTHENTIK_TOKEN=${AUTHENTIK_TOKEN}
AUTHENTIK_ENABLED=${AUTHENTIK_ENABLED}
PLATFORM_EOF

# ─── 13. nginx メイン設定 ─────────────────────────────────────────────────────
info "nginx を設定中..."

if [[ "$AUTHENTIK_ENABLED" == "yes" ]]; then
  cat > /etc/nginx/conf.d/devbox.conf << NGINX_EOF
# DevBox Platform - メインサーバー設定（install.sh が生成）
server {
    listen 80;
    server_name ${DOMAIN};

    location /outpost.goauthentik.io {
        proxy_pass              ${AUTHENTIK_API_URL}/outpost.goauthentik.io;
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        proxy_pass_request_body off;
        proxy_set_header        Content-Length "";
    }

    location @goauthentik_proxy_signin {
        internal;
        add_header Set-Cookie \$auth_cookie;
        return 302 /outpost.goauthentik.io/start?rd=\$request_uri;
    }

    location = / {
        return 200 "DevBox Platform\n";
        add_header Content-Type text/plain;
    }

    include /etc/nginx/conf.d/devbox-users/*.conf;
}
NGINX_EOF
  ok "nginx: Authentik 認証付きで設定"
else
  warn "nginx: 認証なしで設定（Authentik 未設定）"
  cat > /etc/nginx/conf.d/devbox.conf << NGINX_EOF
# DevBox Platform - 認証なし設定（install.sh が生成）
# Authentik を設定したら SKIP_AUTHENTIK=no で install.sh を再実行
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
if [[ "$AUTHENTIK_ENABLED" == "yes" ]]; then
  echo "  Authentik   : http://${DOMAIN}:9000"
fi
echo ""
