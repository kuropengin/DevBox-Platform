#!/usr/bin/env bash
# DevBox Platform - ユーザー登録解除スクリプト（front サーバー上で実行）
# 使い方: sudo bash deregister-user.sh <username>
#
# register-user.sh の逆操作。front 側の認証・ルーティングを削除する:
#   - front nginx のユーザー location を削除
#   - LLDAP からユーザーを削除（ログイン自体ができなくなる）
#   - 登録情報（/etc/devbox/registrations/<username>.conf）を削除
#
# ユーザー削除は front 側を先に行うこと（本人のログイン・アクセスを即座に
# 遮断してから、backend 側の実体を deluser-backend.sh で片付ける流れ）。
#
# 必要な環境変数（任意。/etc/devbox/platform.conf があれば自動で読み込む）:
#   LLDAP_URL             例: http://127.0.0.1:17170
#   LLDAP_ADMIN_USER      LLDAP 管理者ユーザー名
#   LLDAP_ADMIN_PASSWORD  LLDAP 管理者パスワード

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib-common.sh
source "${SCRIPT_DIR}/../lib-common.sh"

# platform.conf が存在すれば設定を読み込む（install-front.sh が生成）
[[ -f /etc/devbox/platform.conf ]] && source /etc/devbox/platform.conf

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash deregister-user.sh <username>"
[[ $# -lt 1 ]]    && die "使い方: bash deregister-user.sh <username>"

USERNAME="$1"

echo ""
info "ユーザー '$USERNAME' の登録を解除します"
echo ""

# ─── 1. front nginx 設定を削除 ─────────────────────────────────────────────────
FRONT_CONF="/etc/nginx/conf.d/devbox-front-users/${USERNAME}.conf"
if [[ -f "$FRONT_CONF" ]]; then
  rm -f "$FRONT_CONF"
  nginx -t && systemctl reload nginx
  ok "front nginx 設定を削除 → ${FRONT_CONF}"
else
  warn "front nginx 設定が見つかりません（${FRONT_CONF}）。スキップします"
fi

# ─── 2. 登録情報を削除 ─────────────────────────────────────────────────────────
REG_CONF="/etc/devbox/registrations/${USERNAME}.conf"
if [[ -f "$REG_CONF" ]]; then
  rm -f "$REG_CONF"
  ok "登録情報を削除 → ${REG_CONF}"
else
  warn "登録情報が見つかりません（${REG_CONF}）。スキップします"
fi

# ─── 3. LLDAP からユーザーを削除（任意） ───────────────────────────────────────
if [[ -n "${LLDAP_ADMIN_PASSWORD:-}" && -n "${LLDAP_URL:-}" ]]; then
  info "LLDAP からユーザーを削除中..."

  TOKEN=$(curl -sf -X POST "${LLDAP_URL}/auth/simple/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${LLDAP_ADMIN_USER:-admin}\",\"password\":\"${LLDAP_ADMIN_PASSWORD}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

  if [[ -n "$TOKEN" ]]; then
    if curl -sf -X POST "${LLDAP_URL}/api/graphql" \
      -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
      -d "{\"query\":\"mutation{deleteUser(userId:\\\"${USERNAME}\\\")}\"}" \
      -o /dev/null; then
      ok "LLDAP からユーザーを削除完了（以後 ${USERNAME} はログインできません）"
    else
      warn "LLDAP からのユーザー削除に失敗しました（すでに存在しない可能性があります）"
    fi
  else
    warn "LLDAP 管理者トークンの取得に失敗しました"
  fi
else
  warn "LLDAP_ADMIN_PASSWORD/LLDAP_URL が未設定のため LLDAP 削除をスキップ"
  warn "手動で削除: LLDAP 管理画面（/lldap/）からユーザーを削除してください"
fi

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ユーザー '${USERNAME}' の登録解除が完了しました${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  ※ LemonLDAP::NG の認可ルール（^/${USERNAME}/(.*) => \$uid eq"
echo "    \"${USERNAME}\"）は削除していません。LLDAP アカウントが無くなった"
echo "    ため事実上無効化されていますが、完全に消したい場合は"
echo "    lemonldap-ng-cli で個別に削除してください。"
echo ""
echo "続けて、当該ユーザーが配置されている backend サーバーで"
echo "以下を実行し、実体（Linuxアカウント・systemdサービス）を削除してください:"
echo ""
echo "  sudo bash scripts/backend/deluser-backend.sh ${USERNAME}"
echo ""
