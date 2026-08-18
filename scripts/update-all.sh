#!/usr/bin/env bash
# DevBox Platform - 一括アップデートスクリプト
# 使い方: sudo bash scripts/update-all.sh [--no-restart]
#
# 以下をまとめて実行する:
#   1. dnf update -y            OS パッケージ全体（VS Code / Java / Claude Code CLI 等の
#                                dnf 管理パッケージもここで更新される）
#   2. VS Code 拡張機能         マスターセットを最新化し、既存の全ユーザーへ配布
#   3. Tomcat 9 / 11            archive.apache.org から最新パッチを取得して切り替え
#
# オプション:
#   --no-restart   VS Code 拡張機能の更新後に vscode@<user>.service を再起動しない

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-vscode-extensions.sh
source "${SCRIPT_DIR}/lib-vscode-extensions.sh"
# shellcheck source=lib-tomcat.sh
source "${SCRIPT_DIR}/lib-tomcat.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash scripts/update-all.sh"

RESTART=yes
for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=no ;;
    *) die "不明なオプション: $arg" ;;
  esac
done

echo ""
info "1/3: dnf update を実行中..."
dnf update -y
ok "dnf update 完了"

echo ""
info "2/3: VS Code 拡張機能を更新中..."
vscode_ext_update_all "$RESTART"
ok "VS Code 拡張機能の更新完了"

echo ""
info "3/3: Tomcat を更新中..."
TOMCAT_FAILED=0
for major in 9 11; do
  tomcat_install_or_update "$major" || TOMCAT_FAILED=1
done
if [[ "$TOMCAT_FAILED" -eq 0 ]]; then
  ok "Tomcat の更新完了"
else
  warn "Tomcat の一部バージョンの更新に失敗しました"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$TOMCAT_FAILED" -eq 0 ]]; then
  echo -e "${GREEN}  一括アップデートが完了しました${NC}"
else
  echo -e "${YELLOW}  一括アップデートが一部失敗しました（Tomcat）${NC}"
fi
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
[[ "$RESTART" == "no" ]] && warn "--no-restart 指定のため、各ユーザーの VS Code は手動再起動（または再接続）が必要です"
