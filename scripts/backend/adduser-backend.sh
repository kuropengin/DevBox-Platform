#!/usr/bin/env bash
# DevBox Platform - backend ユーザー追加スクリプト（backend サーバー上で実行）
# 使い方: sudo bash adduser-backend.sh <username> <email> [オプション]
#
# オプション:
#   --cpu    CPU上限（systemd CPUQuota、例: 200%）  デフォルト: 200%
#   --mem    メモリ上限（MemoryMax、例: 4G）         デフォルト: 4G
#
# email は Headroom（front側LLMプロキシ）経由で Claude を使う際の
# x-user-id ヘッダに使われる（詳細は lib-claude.sh・README の
# 「Headroom」セクション参照）。
#
# このスクリプトは Linux ユーザー・systemd サービス・backend ローカルの
# nginx 設定のみを作成する（認証は front 側の役割のため、ここでは行わない）。
# 完了後、front サーバーで register-user.sh を実行してユーザーを登録すること。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVBOX_BACKEND_PORT=80

# shellcheck source=../lib-common.sh
source "${SCRIPT_DIR}/../lib-common.sh"
# shellcheck source=lib-vscode-extensions.sh
source "${SCRIPT_DIR}/lib-vscode-extensions.sh"
# shellcheck source=lib-claude.sh
source "${SCRIPT_DIR}/lib-claude.sh"

# backend-platform.conf が存在すれば設定を読み込む（install-backend.sh が生成、
# HEADROOM_BASE_URL / DEVBOX_HEADROOM_TOKEN / USER_HOME_BASE）
[[ -f /etc/devbox/backend-platform.conf ]] && source /etc/devbox/backend-platform.conf

VSCODE_PORT_BASE=10000
XPRA_PORT_BASE=14500
TOMCAT_PORT_BASE=18080
USER_HOME_BASE="${USER_HOME_BASE:-/home}"
USER_HOME_BASE="${USER_HOME_BASE%/}"

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash adduser-backend.sh <username> <email>"
[[ $# -lt 2 ]]    && die "使い方: bash adduser-backend.sh <username> <email> [--cpu 200%] [--mem 4G]"

USERNAME="$1"; shift
EMAIL="$1"; shift

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
devbox_validate_username "$USERNAME"
devbox_validate_email "$EMAIL"
id "$USERNAME" &>/dev/null && die "ユーザー '$USERNAME' はすでに存在します"
if [[ -z "${HEADROOM_BASE_URL:-}" || -z "${DEVBOX_HEADROOM_TOKEN:-}" ]]; then
  warn "HEADROOM_BASE_URL/DEVBOX_HEADROOM_TOKEN が未設定です。${USERNAME} は Claude Code を使えません"
fi

echo ""
info "ユーザー '$USERNAME' を追加します (email: ${EMAIL}, CPU: ${CPU_QUOTA}, Memory: ${MEMORY_MAX})"
echo ""

# ─── 1. Linux ユーザー作成 ─────────────────────────────────────────────────────
info "Linux ユーザーを作成中... (ホーム: ${USER_HOME_BASE}/${USERNAME})"
mkdir -p "$USER_HOME_BASE"
useradd --create-home --shell /bin/bash --comment "DevBox User" --base-dir "$USER_HOME_BASE" "$USERNAME"
USER_UID=$(id -u "$USERNAME")
USER_HOME="$(devbox_user_home "$USERNAME")"
ok "ユーザー作成完了 (UID: ${USER_UID}, ホーム: ${USER_HOME})"

# 作業用フォルダ（VS Code初回アクセス時にポータルが自動で開く）
mkdir -p "${USER_HOME}/workspace"
chown "${USERNAME}:${USERNAME}" "${USER_HOME}/workspace"
ok "作業フォルダ作成完了 (${USER_HOME}/workspace)"

# ─── 2. ポート計算 ─────────────────────────────────────────────────────────────
# UID オフセットでポートを決定（UID 1000 → 10000 / 14500 / 18080）。
# backend ごとにローカルで完結するため、他の backend との調整は不要。
UID_OFFSET=$((USER_UID - 1000))
VSCODE_PORT=$((VSCODE_PORT_BASE + UID_OFFSET))
XPRA_PORT=$((XPRA_PORT_BASE + UID_OFFSET))
XPRA_DISPLAY=$((100 + UID_OFFSET))
TOMCAT_PORT=$((TOMCAT_PORT_BASE + UID_OFFSET))

# ポート競合チェック
for port in $VSCODE_PORT $XPRA_PORT $TOMCAT_PORT; do
  ss -tlnp | grep -q ":${port} " && die "ポート ${port} はすでに使用中です"
done

ok "ポート割り当て: VS Code=${VSCODE_PORT}, Xpra=${XPRA_PORT}, Display=:${XPRA_DISPLAY}, Tomcat/webapp=${TOMCAT_PORT}"

# ─── 3. ユーザー設定ファイル ───────────────────────────────────────────────────
info "設定ファイルを作成中..."
mkdir -p /etc/devbox/users
cat > "/etc/devbox/users/${USERNAME}.conf" << EOF
# DevBox user config - adduser-backend.sh が生成
USERNAME=${USERNAME}
VSCODE_PORT=${VSCODE_PORT}
XPRA_PORT=${XPRA_PORT}
XPRA_DISPLAY=${XPRA_DISPLAY}
TOMCAT_PORT=${TOMCAT_PORT}
CPU_QUOTA=${CPU_QUOTA}
MEMORY_MAX=${MEMORY_MAX}
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
ok "設定ファイル → /etc/devbox/users/${USERNAME}.conf"

# ─── 4. VS Code 拡張機能を配布 ─────────────────────────────────────────────────
# マスターセット（root 管理、install-backend.sh / update-extensions.sh が更新）
# から独立したコピーを配布する。本人には読み取り専用の権限しか与えないため、
# 追加インストール・アンインストールはできない。
info "VS Code 拡張機能を配布中..."
vscode_ext_sync_to_user "$USERNAME"
ok "VS Code 拡張機能を配布完了（${USERNAME} は読み取り専用）"

# ─── 4.5. VS Code 既定設定 ─────────────────────────────────────────────────────
info "VS Code 既定設定を適用中..."
vscode_set_default_settings "$USERNAME"
ok "VS Code 既定設定を適用完了（security.workspace.trust.startupPrompt: always）"

# ─── 5. Claude Code CLI 連携 ───────────────────────────────────────────────────
# システムにインストール済みの claude CLI を VS Code の Claude 拡張機能から
# 起動するよう設定し、CLI 自身の設定ファイル（$HOME/.claude/settings.json）を
# 用意する。どちらも当該ユーザーのホーム配下に作成されるため他ユーザーとは
# 独立している。HEADROOM_BASE_URL/DEVBOX_HEADROOM_TOKEN が設定されていれば、
# Headroom（front側LLMプロキシ）経由で Claude を使うよう合わせて設定する。
info "Claude Code CLI を設定中..."
claude_configure_vscode_extension "$USERNAME" "$EMAIL" "${HEADROOM_BASE_URL:-}" "${DEVBOX_HEADROOM_TOKEN:-}"
claude_setup_user_settings "$USERNAME" "$EMAIL" "${HEADROOM_BASE_URL:-}" "${DEVBOX_HEADROOM_TOKEN:-}"
ok "Claude Code CLI 設定完了（claude: $(command -v claude || echo 未検出)）"

# ─── 6. systemd ユニット有効化 ─────────────────────────────────────────────────
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

# ─── 7. nginx 設定追加（backend ローカル、認証なし） ──────────────────────────
# 認証は front 側で完結済みの前提のため auth_request は含めない。
# ポータル HTML も front のみが配信するため、ここでは vscode/gui の
# プロキシ設定だけを追加する。X-Devbox-Token（front→backend間の共有
# シークレット）はここで確実に消し、vscode@/xpra@ プロセスには渡さない
# （ユーザー本人がその値を知る手段を残さないため）。
info "nginx 設定を追加中..."
mkdir -p /etc/nginx/conf.d/devbox-backend-users

cat > "/etc/nginx/conf.d/devbox-backend-users/${USERNAME}.conf" << NGINX_EOF
# DevBox backend nginx config for ${USERNAME}

location /${USERNAME}/vscode/ {
    proxy_pass         http://127.0.0.1:${VSCODE_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection upgrade;
    proxy_set_header   Accept-Encoding gzip;
    proxy_set_header   Host \$host;
    proxy_set_header   X-Devbox-Token "";
    proxy_read_timeout 86400;
}

location /${USERNAME}/gui/ {
    proxy_pass         http://127.0.0.1:${XPRA_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection upgrade;
    proxy_set_header   Host \$host;
    proxy_set_header   X-Devbox-Token "";
    proxy_read_timeout 86400;
}

# ${USERNAME} 本人が TOMCAT_PORT（環境変数）で起動したWebアプリを公開する
# 経路。認証は front 側で意図的に行わない（誰でもアクセス可能）。
location /${USERNAME}/webapp/ {
    proxy_pass         http://127.0.0.1:${TOMCAT_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection upgrade;
    proxy_set_header   Host \$host;
    proxy_set_header   X-Devbox-Token "";
    proxy_read_timeout 86400;
}
NGINX_EOF

nginx -t && systemctl reload nginx
ok "nginx 設定追加完了 → /etc/nginx/conf.d/devbox-backend-users/${USERNAME}.conf"

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ユーザー '${USERNAME}' の backend 側作成が完了しました！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "続けて front サーバーで以下を実行し、ユーザーを登録してください:"
echo ""
echo "  sudo bash scripts/front/register-user.sh ${USERNAME} --backend <このサーバーのIP>:${DEVBOX_BACKEND_PORT}"
echo ""
echo "Webアプリ公開（Tomcat等、${USERNAME} 本人が設定・起動）:"
echo "  割り当てポート: ${TOMCAT_PORT}（127.0.0.1:${TOMCAT_PORT} にバインドしてください）"
echo "  公開URL       : /${USERNAME}/webapp/（認証なしでアクセス可能）"
echo "  VS Code内では環境変数 \$TOMCAT_PORT で参照できます"
echo ""
echo "サービス状態:"
echo "  systemctl status devbox@${USERNAME}.target"
echo "  journalctl -u vscode@${USERNAME}.service -f"
echo "  journalctl -u xpra@${USERNAME}.service -f"
echo ""
