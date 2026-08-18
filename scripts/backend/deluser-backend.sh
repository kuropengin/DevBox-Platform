#!/usr/bin/env bash
# DevBox Platform - backend ユーザー削除スクリプト（backend サーバー上で実行）
# 使い方: sudo bash deluser-backend.sh <username> [--purge]
#
# adduser-backend.sh の逆操作。systemd サービス・nginx 設定・Linux アカウント
# を削除する。事前に front サーバーで deregister-user.sh を実行し、本人の
# ログイン・アクセスを遮断しておくこと（順序を守らないと、削除処理中も
# ログイン済みセッションからアクセスされ得る）。
#
# オプション:
#   --purge   ホームディレクトリ（コード・データ含む）も完全に削除する。
#             省略時はホームディレクトリを残す（Linux アカウントのみ削除、
#             データは /home/<username> に残ったまま。誤削除からの復旧や
#             監査のため、デフォルトでは残す）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib-common.sh
source "${SCRIPT_DIR}/../lib-common.sh"

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash deluser-backend.sh <username> [--purge]"
[[ $# -lt 1 ]]    && die "使い方: bash deluser-backend.sh <username> [--purge]"

USERNAME="$1"; shift

PURGE=no
while [[ $# -gt 0 ]]; do
  case $1 in
    --purge) PURGE=yes; shift ;;
    *) die "不明なオプション: $1" ;;
  esac
done

id "$USERNAME" &>/dev/null || die "ユーザー '$USERNAME' は存在しません"

echo ""
info "ユーザー '$USERNAME' を削除します（ホームディレクトリ: $([[ "$PURGE" == "yes" ]] && echo "完全削除" || echo "保持")）"
echo ""

# ─── 1. systemd サービスを停止・無効化 ────────────────────────────────────────
info "systemd サービスを停止中..."
systemctl disable --now \
  "devbox@${USERNAME}.target" \
  "vscode@${USERNAME}.service" \
  "xpra@${USERNAME}.service" 2>/dev/null || true

rm -rf \
  "/etc/systemd/system/vscode@${USERNAME}.service.d" \
  "/etc/systemd/system/xpra@${USERNAME}.service.d"

systemctl daemon-reload
loginctl disable-linger "$USERNAME" 2>/dev/null || true
ok "systemd サービス停止・無効化完了"

# ─── 2. nginx 設定を削除 ───────────────────────────────────────────────────────
BACKEND_CONF="/etc/nginx/conf.d/devbox-backend-users/${USERNAME}.conf"
if [[ -f "$BACKEND_CONF" ]]; then
  rm -f "$BACKEND_CONF"
  nginx -t && systemctl reload nginx
  ok "nginx 設定を削除 → ${BACKEND_CONF}"
else
  warn "nginx 設定が見つかりません（${BACKEND_CONF}）。スキップします"
fi

# ─── 3. ユーザー設定ファイルを削除 ─────────────────────────────────────────────
rm -f "/etc/devbox/users/${USERNAME}.conf"

# ─── 4. Linux ユーザーを削除 ───────────────────────────────────────────────────
info "Linux ユーザーを削除中..."
if [[ "$PURGE" == "yes" ]]; then
  userdel -r "$USERNAME"
  ok "ユーザー削除完了（ホームディレクトリも削除しました）"
else
  userdel "$USERNAME"
  ok "ユーザー削除完了（ホームディレクトリは /home/${USERNAME} に残しています）"
fi

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ユーザー '${USERNAME}' の backend 側削除が完了しました${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if [[ "$PURGE" == "no" ]]; then
  echo "  ホームディレクトリ /home/${USERNAME} は残っています。"
  echo "  完全に削除する場合: sudo rm -rf /home/${USERNAME}"
  echo ""
fi
echo "  front 側の登録解除がまだであれば、front サーバーで"
echo "  scripts/front/deregister-user.sh ${USERNAME} を実行してください。"
echo ""
