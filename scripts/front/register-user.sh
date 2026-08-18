#!/usr/bin/env bash
# DevBox Platform - ユーザー登録スクリプト（front サーバー上で実行）
# 使い方: sudo bash register-user.sh <username> --backend <host>[:<port>]
#
# 事前に対象の backend サーバーで scripts/backend/adduser-backend.sh <username> を
# 実行しておくこと。このスクリプトは front 側のみを設定する:
#   - front nginx にユーザーの location（ポータル + 認証付き backend プロキシ）を追加
#   - LLDAP にユーザーを登録
#   - LemonLDAP::NG に「本人のみ /<username>/ にアクセス可」の認可ルールを追加
#
# --backend の port を省略した場合は 80（backend の内部ポート既定値）を使う。
# 既存ユーザーに対して別の --backend を指定して再実行すると、そのユーザーの
# ルーティング先を別の backend へ移行できる。
#
# 必要な環境変数（任意。/etc/devbox/platform.conf があれば自動で読み込む）:
#   LLDAP_URL             例: http://127.0.0.1:17170
#   LLDAP_BASE_DN         例: dc=devbox,dc=local
#   LLDAP_ADMIN_USER      LLDAP 管理者ユーザー名
#   LLDAP_ADMIN_PASSWORD  LLDAP 管理者パスワード
#   DEVBOX_DOMAIN         例: devbox.example.com

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVBOX_DIR="/opt/devbox"
DEVBOX_BACKEND_PORT_DEFAULT=80
DEVBOX_DOMAIN="${DEVBOX_DOMAIN:-devbox.example.com}"

# shellcheck source=../lib-common.sh
source "${SCRIPT_DIR}/../lib-common.sh"

# platform.conf が存在すれば設定を読み込む（install-front.sh が生成）
[[ -f /etc/devbox/platform.conf ]] && source /etc/devbox/platform.conf

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash register-user.sh <username> --backend <host>[:<port>]"
[[ $# -lt 1 ]]    && die "使い方: bash register-user.sh <username> --backend <host>[:<port>]"

USERNAME="$1"; shift

# ─── 引数パース ───────────────────────────────────────────────────────────────
BACKEND_ARG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --backend) BACKEND_ARG="$2"; shift 2 ;;
    *) die "不明なオプション: $1" ;;
  esac
done
[[ -z "$BACKEND_ARG" ]] && die "--backend <host>[:<port>] を指定してください"

if [[ "$BACKEND_ARG" == *:* ]]; then
  BACKEND_ADDR="$BACKEND_ARG"
else
  BACKEND_ADDR="${BACKEND_ARG}:${DEVBOX_BACKEND_PORT_DEFAULT}"
fi

# ─── バリデーション ────────────────────────────────────────────────────────────
devbox_validate_username "$USERNAME"
[[ -z "${DEVBOX_INTERNAL_TOKEN:-}" ]] && warn "DEVBOX_INTERNAL_TOKEN が未設定です（/etc/devbox/platform.conf を確認してください）。backend 側が拒否し 403 になります"

echo ""
info "ユーザー '$USERNAME' を登録します (backend: ${BACKEND_ADDR})"
echo ""

# ─── 1. backend への疎通確認（任意・失敗しても続行） ──────────────────────────
info "backend への疎通を確認中..."
if curl -sf -m 3 -o /dev/null -H "X-Devbox-Token: ${DEVBOX_INTERNAL_TOKEN:-}" "http://${BACKEND_ADDR}/${USERNAME}/vscode/"; then
  ok "backend 疎通確認 OK"
else
  warn "backend (${BACKEND_ADDR}) への疎通確認に失敗しました"
  warn "  backend で 'scripts/backend/adduser-backend.sh ${USERNAME}' を先に実行したか確認してください"
  warn "  （疎通確認は必須ではないため、このまま登録を続行します）"
fi

# ─── 2. front 側ユーザーレコード ───────────────────────────────────────────────
info "登録情報を保存中..."
mkdir -p /etc/devbox/registrations
cat > "/etc/devbox/registrations/${USERNAME}.conf" << EOF
# DevBox front registration - register-user.sh が生成
USERNAME=${USERNAME}
BACKEND_ADDR=${BACKEND_ADDR}
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
ok "登録情報 → /etc/devbox/registrations/${USERNAME}.conf"

# ─── 3. front nginx 設定追加 ───────────────────────────────────────────────────
info "front nginx 設定を追加中..."
mkdir -p /etc/nginx/conf.d/devbox-front-users

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

cat > "/etc/nginx/conf.d/devbox-front-users/${USERNAME}.conf" << NGINX_EOF
# DevBox front nginx config for ${USERNAME} (backend: ${BACKEND_ADDR})

location /${USERNAME}/ {
${AUTH_BLOCK}
    alias   ${DEVBOX_DIR}/portal/;
    index   index.html;
}

location /${USERNAME}/vscode/ {
${AUTH_BLOCK}
    proxy_pass         http://${BACKEND_ADDR}/${USERNAME}/vscode/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection upgrade;
    proxy_set_header   Accept-Encoding gzip;
    proxy_set_header   Host \$host;
    proxy_set_header   X-Devbox-Token "${DEVBOX_INTERNAL_TOKEN:-}";
    proxy_read_timeout 86400;
}

location /${USERNAME}/gui/ {
${AUTH_BLOCK}
    proxy_pass         http://${BACKEND_ADDR}/${USERNAME}/gui/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection upgrade;
    proxy_set_header   Host \$host;
    proxy_set_header   X-Devbox-Token "${DEVBOX_INTERNAL_TOKEN:-}";
    proxy_read_timeout 86400;
}
NGINX_EOF
# X-Devbox-Token（front→backend間の共有シークレット）を平文で含むため
# root のみ読み取り可能にする。
chown root:root "/etc/nginx/conf.d/devbox-front-users/${USERNAME}.conf"
chmod 640 "/etc/nginx/conf.d/devbox-front-users/${USERNAME}.conf"

nginx -t && systemctl reload nginx
ok "front nginx 設定追加完了 → /etc/nginx/conf.d/devbox-front-users/${USERNAME}.conf"

# ─── 4. LLDAP ユーザー登録（任意） ──────────────────────────────────────────────
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
  warn "手動で追加: LLDAP_URL=... LLDAP_ADMIN_PASSWORD=... bash register-user.sh ${USERNAME} --backend ${BACKEND_ADDR}"
fi

# ─── 5. LemonLDAP::NG 認可ルール追加（本人以外は /${USERNAME}/ にアクセス不可に） ──
if [[ "${LLDAP_ENABLED:-no}" == "yes" ]]; then
  info "LemonLDAP::NG に認可ルールを追加中..."

  LLNG_CLI="/usr/libexec/lemonldap-ng/bin/lemonldap-ng-cli"
  RULE_FILE="$(mktemp)"
  # lemonldap-ng-cli は内部で apache ユーザーに権限を落として設定ファイルを
  # 読むため、root:root 600（mktemp のデフォルト）のままだと権限エラーになる。
  chmod 644 "$RULE_FILE"
  cat > "$RULE_FILE" << EOF
{
  "locationRules": {
    "${DEVBOX_DOMAIN}": {
      "^/${USERNAME}/(.*)": "\$uid eq \"${USERNAME}\""
    }
  }
}
EOF

  if "$LLNG_CLI" -yes 1 merge "$RULE_FILE" &>/dev/null; then
    ok "認可ルール追加完了（/${USERNAME}/ には ${USERNAME} 本人のみアクセス可）"
  else
    warn "LemonLDAP::NG 認可ルールの追加に失敗しました"
    warn "  ログイン済みの他ユーザーが /${USERNAME}/ にアクセスできる状態です"
  fi
  rm -f "$RULE_FILE"
fi

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ユーザー '${USERNAME}' の登録が完了しました！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  ポータル : https://${DEVBOX_DOMAIN}/${USERNAME}/"
echo "  VS Code  : https://${DEVBOX_DOMAIN}/${USERNAME}/vscode/"
echo "  GUI      : https://${DEVBOX_DOMAIN}/${USERNAME}/gui/"
echo "  backend  : ${BACKEND_ADDR}"
echo ""
if [[ -n "$USER_LDAP_PASS" ]]; then
  echo "  ログインID    : ${USERNAME}"
  echo "  初期パスワード: ${USER_LDAP_PASS}"
  echo ""
fi
