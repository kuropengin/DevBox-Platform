#!/usr/bin/env bash
# DevBox Platform - VS Code 拡張機能の更新スクリプト
# 使い方: sudo bash scripts/update-extensions.sh [--no-restart]
#
# root がマスターセット（scripts/vscode-extensions.list）の拡張機能を
# 最新化し、既存の全ユーザーへ配布する。ユーザー自身は拡張機能ディレクトリ
# への書き込み権限を持たないため、拡張機能のインストール・更新・削除は
# 本スクリプト（root 実行）経由でのみ行える。
#
# オプション:
#   --no-restart   配布後に vscode@<user>.service を再起動しない
#                   （再起動しないと、既に起動中のセッションには反映されない）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-vscode-extensions.sh
source "${SCRIPT_DIR}/lib-vscode-extensions.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash scripts/update-extensions.sh"

RESTART=yes
for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=no ;;
    *) die "不明なオプション: $arg" ;;
  esac
done

info "マスターセットの拡張機能を更新中... (${VSCODE_EXT_LIST_FILE})"
info "既存ユーザーへ配布中..."
vscode_ext_update_all "$RESTART"

echo ""
ok "拡張機能の更新が完了しました"
[[ "$RESTART" == "no" ]] && warn "--no-restart 指定のため、各ユーザーの VS Code は手動再起動（または再接続）が必要です"
