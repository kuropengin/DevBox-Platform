#!/usr/bin/env bash
# DevBox Platform - Apache Tomcat の更新スクリプト
# 使い方: sudo bash scripts/update-tomcat.sh [メジャーバージョン...]
#         例: sudo bash scripts/update-tomcat.sh          # 9 と 11 の両方
#             sudo bash scripts/update-tomcat.sh 9         # 9 のみ
#
# archive.apache.org から各メジャーバージョン系列の最新パッチを取得し、
# 差分があれば /opt/devbox/tomcat/tomcat<major> の参照先を切り替える。
# 既に最新であれば何もしない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-tomcat.sh
source "${SCRIPT_DIR}/lib-tomcat.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash scripts/update-tomcat.sh [メジャーバージョン...]"

VERSIONS=("$@")
[[ ${#VERSIONS[@]} -eq 0 ]] && VERSIONS=(9 11)

FAILED=0
for major in "${VERSIONS[@]}"; do
  info "Tomcat ${major} を確認中..."
  if tomcat_install_or_update "$major"; then
    ok "Tomcat ${major} 更新確認完了 → ${TOMCAT_BASE_DIR}/tomcat${major}"
  else
    warn "Tomcat ${major} の更新に失敗しました"
    FAILED=1
  fi
done

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  ok "Tomcat の更新が完了しました"
else
  die "一部の Tomcat バージョンの更新に失敗しました（上記ログ参照）"
fi
