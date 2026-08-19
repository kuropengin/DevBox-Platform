#!/usr/bin/env bash
# DevBox Platform - VS Code 拡張機能の共通処理
# install-backend.sh / adduser-backend.sh / update-extensions.sh から source して使う。
#
# 設計:
#   - 拡張機能のインストール/更新は root がマスターディレクトリ
#     （VSCODE_EXT_MASTER_DIR）に対してのみ行う。
#   - 各ユーザーにはマスターの「独立したコピー」を配布する（シンボリックリンク
#     や共有ディレクトリではない）ため、あるユーザーの VS Code プロセスが
#     extensions.json 等へ書き込んでも他ユーザーに影響しない。
#   - 配布後、ユーザー本人はそのコピーに対して読み取り・実行のみ可能
#     （所有者は root）にする。追加インストール・アンインストールは
#     ファイルシステムレベルで禁止され、更新は root が本スクリプト経由で
#     行った場合にのみ全ユーザーへ反映される。

: "${VSCODE_EXT_MASTER_DIR:=/opt/devbox/vscode-extensions}"
: "${VSCODE_EXT_CLI_DATA_DIR:=/opt/devbox/vscode-extensions-cli-data}"

_vscode_ext_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${VSCODE_EXT_LIST_FILE:=${_vscode_ext_lib_dir}/vscode-extensions.list}"

# マスターの拡張機能セットを最新化する（root 実行前提）
vscode_ext_build_master() {
  [[ -f "$VSCODE_EXT_LIST_FILE" ]] || {
    echo "拡張機能一覧が見つかりません: ${VSCODE_EXT_LIST_FILE}" >&2
    return 1
  }

  mkdir -p "$VSCODE_EXT_MASTER_DIR" "$VSCODE_EXT_CLI_DATA_DIR"

  local ext
  while IFS= read -r ext; do
    ext="${ext%%#*}"
    ext="$(echo -n "$ext" | xargs)"
    [[ -z "$ext" ]] && continue
    code \
      --user-data-dir "$VSCODE_EXT_CLI_DATA_DIR" \
      --extensions-dir "$VSCODE_EXT_MASTER_DIR" \
      --install-extension "$ext" \
      --force
  done < "$VSCODE_EXT_LIST_FILE"
}

# マスターの拡張機能を指定ユーザーへ配布する（独立コピー・読み取り専用）
# 引数: $1 = ユーザー名
vscode_ext_sync_to_user() {
  local username="$1"
  local vscode_dir="/home/${username}/.vscode"
  local server_data_dir="${vscode_dir}/server-data"
  local target_dir="${server_data_dir}/extensions"

  [[ -d "$VSCODE_EXT_MASTER_DIR" ]] || return 0

  mkdir -p "$target_dir"

  # mkdir -p は root 実行のため、ここまでで作られた .vscode/server-data も
  # root 所有のまま残ってしまう。この2つは vscode@.service の
  # ExecStartPre（cli-data 作成）や code serve-web 自体の実行時データ
  # 書き込み先として、本人が書き込める必要があるため、先にユーザー本人へ
  # 所有権を戻しておく（ロックダウンするのは extensions ディレクトリだけ）。
  chown "${username}:${username}" "$vscode_dir" "$server_data_dir"

  rsync -a --delete "${VSCODE_EXT_MASTER_DIR}/" "${target_dir}/"

  # root が所有し、対象ユーザーは読み取り・実行のみ可能にする。既存の
  # 実行ビット（拡張機能に同梱されたネイティブバイナリ等）は go-w では
  # 変更されないため、拡張機能自体の動作は妨げない。
  chown -R root:"${username}" "$target_dir"
  chmod -R go-w "$target_dir"
  chmod 750 "$target_dir"
}

# VS Code User settings に、プラットフォーム共通の既定値をマージ設定する
# （既存キーは保持したままマージ書き込みする。Claude Code固有の設定は
# lib-claude.sh 側で扱う）
# 引数: $1 = ユーザー名
vscode_set_default_settings() {
  local username="$1"
  local settings_dir="/home/${username}/.vscode/server-data/data/User"
  local settings_file="${settings_dir}/settings.json"

  mkdir -p "$settings_dir"

  python3 - "$settings_file" << 'PYEOF'
import json
import os
import sys

settings_file = sys.argv[1]

data = {}
if os.path.exists(settings_file):
    with open(settings_file, encoding="utf-8") as f:
        content = f.read().strip()
        if content:
            data = json.loads(content)

data["security.workspace.trust.startupPrompt"] = "always"

with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

  chown -R "${username}:${username}" "/home/${username}/.vscode/server-data/data"
}

# 既存の全ユーザー（/etc/devbox/users/*.conf）へ配布する
vscode_ext_sync_to_all_users() {
  local conf username
  shopt -s nullglob
  for conf in /etc/devbox/users/*.conf; do
    username="$(basename "$conf" .conf)"
    vscode_ext_sync_to_user "$username"
  done
  shopt -u nullglob
}

# マスターセットを最新化し、既存の全ユーザーへ配布する。必要なら起動中の
# vscode@<user>.service を再起動して反映する（update-extensions.sh /
# update-all.sh から呼ばれる）。
# 引数: $1 = yes|no（再起動するか。省略時 yes）
vscode_ext_update_all() {
  local restart="${1:-yes}"
  local conf username had_users=0

  vscode_ext_build_master

  shopt -s nullglob
  for conf in /etc/devbox/users/*.conf; do
    had_users=1
    username="$(basename "$conf" .conf)"
    vscode_ext_sync_to_user "$username"
    echo "  配布完了: ${username}"

    if [[ "$restart" == "yes" ]] && systemctl is-active --quiet "vscode@${username}.service" 2>/dev/null; then
      systemctl restart "vscode@${username}.service"
      echo "  vscode@${username}.service を再起動しました（更新反映のため）"
    fi
  done
  shopt -u nullglob

  [[ "$had_users" -eq 0 ]] && echo "  登録済みユーザーがいません（配布対象なし）"

  # ループの最後の条件が false（= ユーザーがいる、正常系）で終わると
  # 関数の戻り値がそのまま非ゼロになり、呼び出し元で `set -e` により
  # 何もエラーを出さずスクリプトが停止してしまう。それを防ぐため明示的に
  # 成功を返す。
  return 0
}
