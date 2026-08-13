#!/usr/bin/env bash
# DevBox Platform - ユーザー追加スクリプト
# 使い方: sudo bash adduser.sh <username> [オプション]
#
# オプション:
#   --cpu    CPU上限（systemd CPUQuota、例: 200%）  デフォルト: 200%
#   --mem    メモリ上限（MemoryMax、例: 4G）         デフォルト: 4G
#
# 必要な環境変数（任意）:
#   AUTHENTIK_URL    例: https://auth.example.com
#   AUTHENTIK_TOKEN  Authentik APIトークン
#   DEVBOX_DOMAIN    例: devbox.example.com

set -euo pipefail

DEVBOX_DOMAIN="${DEVBOX_DOMAIN:-devbox.example.com}"
DEVBOX_DIR="/opt/devbox"
VSCODE_PORT_BASE=10000
XPRA_PORT_BASE=14500

# platform.conf が存在すれば設定を読み込む
[[ -f /etc/devbox/platform.conf ]] && source /etc/devbox/platform.conf

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash adduser.sh <username>"
[[ $# -lt 1 ]]    && die "使い方: bash adduser.sh <username> [--cpu 200%] [--mem 4G]"

USERNAME="$1"; shift

# ─── 引数パース ───────────────────────────────────────────────────────────────
CPU_QUOTA="200%"
MEMORY_MAX="4G"
while [[ $# -gt 0 ]]; do
  case $1 in
    --cpu) CPU_QUOTA="$2";  shift 2 ;;
    --mem) MEMORY_MAX="$2"; shift 2 ;;
    *) die "不明なオプション: $1" ;;
  esac
done

# ─── バリデーション ────────────────────────────────────────────────────────────
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "無効なユーザー名: $USERNAME"
id "$USERNAME" &>/dev/null && die "ユーザー '$USERNAME' はすでに存在します"

echo ""
info "ユーザー '$USERNAME' を追加します (CPU: ${CPU_QUOTA}, Memory: ${MEMORY_MAX})"
echo ""

# ─── 1. Linux ユーザー作成 ─────────────────────────────────────────────────────
info "Linux ユーザーを作成中..."
useradd --create-home --shell /bin/bash --comment "DevBox User" "$USERNAME"
USER_UID=$(id -u "$USERNAME")
ok "ユーザー作成完了 (UID: ${USER_UID})"

# ─── 2. ポート計算 ─────────────────────────────────────────────────────────────
# UID オフセットでポートを決定（UID 1000 → 10000 / 14500）
UID_OFFSET=$((USER_UID - 1000))
VSCODE_PORT=$((VSCODE_PORT_BASE + UID_OFFSET))
XPRA_PORT=$((XPRA_PORT_BASE + UID_OFFSET))
XPRA_DISPLAY=$((100 + UID_OFFSET))

# ポート競合チェック
for port in $VSCODE_PORT $XPRA_PORT; do
  ss -tlnp | grep -q ":${port} " && die "ポート ${port} はすでに使用中です"
done

ok "ポート割り当て: VS Code=${VSCODE_PORT}, Xpra=${XPRA_PORT}, Display=:${XPRA_DISPLAY}"

# ─── 3. ユーザー設定ファイル ───────────────────────────────────────────────────
info "設定ファイルを作成中..."
mkdir -p /etc/devbox/users
cat > "/etc/devbox/users/${USERNAME}.conf" << EOF
# DevBox user config - adduser.sh が生成
USERNAME=${USERNAME}
VSCODE_PORT=${VSCODE_PORT}
XPRA_PORT=${XPRA_PORT}
XPRA_DISPLAY=${XPRA_DISPLAY}
CPU_QUOTA=${CPU_QUOTA}
MEMORY_MAX=${MEMORY_MAX}
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
ok "設定ファイル → /etc/devbox/users/${USERNAME}.conf"

# ─── 4. systemd ユニット有効化 ─────────────────────────────────────────────────
info "systemd ユニットを有効化中..."
# code-server と xpra に CPUQuota/MemoryMax のドロップインを作成
for service in "vscode@${USERNAME}" "xpra@${USERNAME}"; do
  mkdir -p "/etc/systemd/system/${service}.service.d"
  cat > "/etc/systemd/system/${service}.service.d/resources.conf" << EOF
[Service]
CPUQuota=${CPU_QUOTA}
MemoryMax=${MEMORY_MAX}
EOF
done

systemctl daemon-reload
systemctl enable --now "devbox@${USERNAME}.target"
ok "systemd: devbox@${USERNAME}.target 有効化完了 (vscode@${USERNAME} / xpra@${USERNAME})"

# ─── 5. nginx 設定追加 ─────────────────────────────────────────────────────────
info "nginx 設定を追加中..."
mkdir -p /etc/nginx/conf.d/devbox-users

# Authentik 有効時は auth_request ブロックを含める
if [[ "${AUTHENTIK_ENABLED:-no}" == "yes" ]]; then
  AUTH_BLOCK='    auth_request      /outpost.goauthentik.io/auth/nginx;
    error_page 401  = @goauthentik_proxy_signin;
    auth_request_set  $auth_cookie $upstream_http_set_cookie;
    add_header        Set-Cookie $auth_cookie;'
else
  AUTH_BLOCK=''
fi

cat > "/etc/nginx/conf.d/devbox-users/${USERNAME}.conf" << NGINX_EOF
# DevBox nginx config for ${USERNAME}

location /${USERNAME}/ {
${AUTH_BLOCK}
    alias   ${DEVBOX_DIR}/portal/;
    index   index.html;
}

location /${USERNAME}/vscode/ {
${AUTH_BLOCK}
    proxy_pass         http://127.0.0.1:${VSCODE_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection upgrade;
    proxy_set_header   Accept-Encoding gzip;
    proxy_set_header   Host \$host;
    proxy_read_timeout 86400;
}

location /${USERNAME}/gui/ {
${AUTH_BLOCK}
    proxy_pass         http://127.0.0.1:${XPRA_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection upgrade;
    proxy_set_header   Host \$host;
    proxy_read_timeout 86400;
}
NGINX_EOF

nginx -t && systemctl reload nginx
ok "nginx 設定追加完了 → /etc/nginx/conf.d/devbox-users/${USERNAME}.conf"

# ─── 6. Authentik ユーザー登録（任意） ────────────────────────────────────────
if [[ -n "${AUTHENTIK_TOKEN:-}" && -n "${AUTHENTIK_URL:-}" ]]; then
  info "Authentik にユーザーを追加中..."

  # ユーザーが存在するか確認
  EXISTING=$(curl -sf \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    "${AUTHENTIK_URL}/api/v3/core/users/?username=${USERNAME}" \
    | grep -o '"count":[0-9]*' | cut -d: -f2 || echo "0")

  if [[ "${EXISTING:-0}" == "0" ]]; then
    RESP=$(curl -sf \
      -X POST \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${USERNAME}\",\"name\":\"${USERNAME}\",\"is_active\":true}" \
      "${AUTHENTIK_URL}/api/v3/core/users/") || { warn "Authentik ユーザー作成に失敗しました"; RESP=""; }

    if [[ -n "$RESP" ]]; then
      ok "Authentik ユーザー作成完了"
    fi
  else
    ok "Authentik にユーザー '${USERNAME}' は既に存在します"
  fi
else
  warn "AUTHENTIK_TOKEN/AUTHENTIK_URL が未設定のため Authentik 登録をスキップ"
  warn "手動で追加: AUTHENTIK_URL=... AUTHENTIK_TOKEN=... bash adduser.sh ${USERNAME}"
fi

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ユーザー '${USERNAME}' の追加が完了しました！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  ポータル : http://${DEVBOX_DOMAIN}/${USERNAME}/"
echo "  VS Code  : http://${DEVBOX_DOMAIN}/${USERNAME}/vscode/"
echo "  GUI      : http://${DEVBOX_DOMAIN}/${USERNAME}/gui/"
echo ""
echo "サービス状態:"
echo "  systemctl status devbox@${USERNAME}.target"
echo "  journalctl -u vscode@${USERNAME}.service -f"
echo "  journalctl -u xpra@${USERNAME}.service -f"
echo ""
