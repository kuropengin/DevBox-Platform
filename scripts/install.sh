#!/usr/bin/env bash
# DevBox Platform - インストールスクリプト (RHEL 9 系)
# 対応: AlmaLinux 9 / Rocky Linux 9 / RHEL 9
# 使い方: sudo bash install.sh
#
# 環境変数（任意）:
#   AUTHENTIK_URL    例: https://auth.example.com
#   AUTHENTIK_TOKEN  Authentik APIトークン
#   DEVBOX_DOMAIN    例: devbox.example.com  (デフォルト: devbox.example.com)

set -euo pipefail

DOMAIN="${DEVBOX_DOMAIN:-devbox.example.com}"
DEVBOX_DIR="/opt/devbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash install.sh"

# RHEL 9 系であることを確認
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
dnf install -y curl wget git python3

# CRB (CodeReady Builder) を有効化 — EPEL の一部パッケージに必要
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
  dnf install -y \
    xpra \
    xorg-x11-server-Xvfb \
    xauth \
    xorg-x11-utils \
    dejavu-sans-fonts \
    dbus-x11 \
    xterm

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
  dnf install -y \
    xfce4-session \
    xfce4-terminal \
    xfwm4 \
    xfdesktop \
    xfce4-panel \
    Thunar
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
  setsebool -P httpd_can_network_connect 1
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

# ─── 8. ディレクトリ作成 ──────────────────────────────────────────────────────
info "ディレクトリを作成中..."
mkdir -p \
  "${DEVBOX_DIR}/portal" \
  /etc/devbox/users \
  /etc/nginx/conf.d/devbox-users

# SELinux コンテキストを nginx 向けに設定
command -v chcon &>/dev/null && chcon -Rt httpd_sys_content_t "${DEVBOX_DIR}/portal"
ok "ディレクトリ作成完了"

# ─── 9. ポータル HTML ─────────────────────────────────────────────────────────
info "ポータル HTML をコピー中..."
cp "${REPO_DIR}/portal/index.html" "${DEVBOX_DIR}/portal/index.html"
ok "ポータル HTML → ${DEVBOX_DIR}/portal/index.html"

# ─── 10. systemd テンプレートユニット ────────────────────────────────────────
info "systemd ユニットをインストール中..."
for unit in devbox@.target vscode@.service xpra@.service; do
  cp "${REPO_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
ok "systemd ユニットインストール完了"

# ─── 11. nginx メイン設定 ─────────────────────────────────────────────────────
info "nginx を設定中..."
AUTHENTIK_URL="${AUTHENTIK_URL:-https://auth.example.com}"

cat > /etc/nginx/conf.d/devbox.conf << NGINX_EOF
# DevBox Platform - メインサーバー設定（install.sh が生成）
server {
    listen 80;
    server_name ${DOMAIN};

    # Authentik Forward Auth エンドポイント
    location /outpost.goauthentik.io {
        proxy_pass              ${AUTHENTIK_URL}/outpost.goauthentik.io;
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

    # ユーザー別ロケーション（adduser.sh が追加）
    include /etc/nginx/conf.d/devbox-users/*.conf;
}
NGINX_EOF

nginx -t && systemctl start nginx
ok "nginx 設定完了"

# ─── 12. Authentik アプリケーション登録（任意） ──────────────────────────────
if [[ -n "${AUTHENTIK_TOKEN:-}" ]]; then
  info "Authentik にアプリケーションを登録中..."
  PROVIDER_RESP=$(curl -sf \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"devbox-proxy\",\"authorization_flow\":\"default-provider-authorization-implicit-consent\",\"external_host\":\"http://${DOMAIN}\",\"internal_host\":\"http://127.0.0.1\",\"mode\":\"forward_single\"}" \
    "${AUTHENTIK_URL}/api/v3/providers/proxy/") || warn "Authentik プロバイダー作成をスキップ"

  if [[ -n "${PROVIDER_RESP:-}" ]]; then
    PROVIDER_PK=$(echo "$PROVIDER_RESP" | grep -o '"pk":[0-9]*' | head -1 | cut -d: -f2)
    curl -sf \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"DevBox\",\"slug\":\"devbox\",\"provider\":${PROVIDER_PK}}" \
      "${AUTHENTIK_URL}/api/v3/core/applications/" > /dev/null \
      || warn "Authentik アプリケーション作成をスキップ"
    ok "Authentik アプリケーション登録完了"
  fi
else
  warn "AUTHENTIK_TOKEN が未設定のため Authentik 登録をスキップ"
fi

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  インストール完了！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "次のステップ:"
echo "  1. Authentik でポータルプロバイダーを設定（Embedded Outpost）"
echo "  2. ユーザー追加: sudo bash scripts/adduser.sh <username>"
echo "  3. アクセス: http://${DOMAIN}/<username>/"
echo ""
