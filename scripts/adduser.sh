#!/usr/bin/env bash
# DevBox Platform - ユーザー追加スクリプト
# 使い方: sudo bash adduser.sh <username> [オプション]
#
# オプション:
#   --cpu    CPU上限（systemd CPUQuota、例: 200%）  デフォルト: 200%
#   --mem    メモリ上限（MemoryMax、例: 4G）         デフォルト: 4G
#
# 必要な環境変数（任意）:
#   LLDAP_URL             例: http://127.0.0.1:17170
#   LLDAP_BASE_DN         例: dc=devbox,dc=local
#   LLDAP_ADMIN_USER      LLDAP 管理者ユーザー名
#   LLDAP_ADMIN_PASSWORD  LLDAP 管理者パスワード
#   DEVBOX_DOMAIN         例: devbox.example.com

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

# nginx のトップレベルパスとして予約済み（LemonLDAP::NG ポータル / LLDAP 管理画面）
RESERVED_USERNAMES=(_auth static api auth lldap lmauth)
for reserved in "${RESERVED_USERNAMES[@]}"; do
  [[ "$USERNAME" == "$reserved" ]] && die "'${USERNAME}' は予約語のため使用できません"
done

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
loginctl enable-linger "$USERNAME"
# 子サービスを個別に enable してから target を起動する
systemctl enable --now \
  "vscode@${USERNAME}.service" \
  "xpra@${USERNAME}.service" \
  "devbox@${USERNAME}.target"
ok "systemd: devbox@${USERNAME}.target 有効化完了 (vscode@${USERNAME} / xpra@${USERNAME})"

# ─── 5. nginx 設定追加 ─────────────────────────────────────────────────────────
info "nginx 設定を追加中..."
mkdir -p /etc/nginx/conf.d/devbox-users

# LLDAP 有効時は auth_request ブロックを含める（LemonLDAP::NG Forward Auth）
if [[ "${LLDAP_ENABLED:-no}" == "yes" ]]; then
  AUTH_BLOCK='    set               $original_uri $uri$is_args$args;
    auth_request      /lmauth;
    auth_request_set  $lmremote_user $upstream_http_lm_remote_user;
    auth_request_set  $lmlocation $upstream_http_location;
    error_page 401    $lmerror_location;'
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

# ─── 6. LLDAP ユーザー登録（任意） ──────────────────────────────────────────────
USER_LDAP_PASS=""
if [[ -n "${LLDAP_ADMIN_PASSWORD:-}" && -n "${LLDAP_URL:-}" ]]; then
  info "LLDAP にユーザーを追加中..."

  TOKEN=$(curl -sf -X POST "${LLDAP_URL}/auth/simple/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${LLDAP_ADMIN_USER:-admin}\",\"password\":\"${LLDAP_ADMIN_PASSWORD}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

  if [[ -n "$TOKEN" ]]; then
    # ユーザーが存在するか確認
    EXISTING=$(curl -sf -X POST "${LLDAP_URL}/api/graphql" \
      -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
      -d "{\"query\":\"query{user(userId:\\\"${USERNAME}\\\"){id}}\"}" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(1 if d.get('data',{}).get('user') else 0)" 2>/dev/null || echo "0")

    if [[ "${EXISTING:-0}" == "0" ]]; then
      if curl -sf -X POST "${LLDAP_URL}/api/graphql" \
        -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
        -d "{\"query\":\"mutation{createUser(user:{id:\\\"${USERNAME}\\\",email:\\\"${USERNAME}@${DEVBOX_DOMAIN}\\\"}){id}}\"}" \
        -o /dev/null; then
        USER_LDAP_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
        if lldap_set_password \
          --base-url "${LLDAP_URL}" \
          --admin-username "${LLDAP_ADMIN_USER:-admin}" \
          --admin-password "${LLDAP_ADMIN_PASSWORD}" \
          --username "${USERNAME}" \
          --password "${USER_LDAP_PASS}" &>/dev/null; then
          ok "LLDAP ユーザー作成・パスワード設定完了"
        else
          warn "LLDAP パスワード設定に失敗しました"
          USER_LDAP_PASS=""
        fi
      else
        warn "LLDAP ユーザー作成に失敗しました"
      fi
    else
      ok "LLDAP にユーザー '${USERNAME}' は既に存在します"
    fi
  else
    warn "LLDAP 管理者トークンの取得に失敗しました"
  fi
else
  warn "LLDAP_ADMIN_PASSWORD/LLDAP_URL が未設定のため LLDAP 登録をスキップ"
  warn "手動で追加: LLDAP_URL=... LLDAP_ADMIN_PASSWORD=... bash adduser.sh ${USERNAME}"
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
if [[ -n "$USER_LDAP_PASS" ]]; then
  echo "  ログインID    : ${USERNAME}"
  echo "  初期パスワード: ${USER_LDAP_PASS}"
  echo ""
fi
echo "サービス状態:"
echo "  systemctl status devbox@${USERNAME}.target"
echo "  journalctl -u vscode@${USERNAME}.service -f"
echo "  journalctl -u xpra@${USERNAME}.service -f"
echo ""
