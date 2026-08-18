#!/usr/bin/env bash
# DevBox Platform - Claude Code CLI 関連の共通処理
# adduser-backend.sh から source して使う。
#
# 設計:
#   - Claude Code CLI 本体（/usr/bin/claude）は install-backend.sh が backend
#     サーバーごとに一度だけインストールする。CLI 自体の設定・セッション状態は
#     $HOME/.claude/ に保存される仕組みのため、バイナリを共有していても
#     ユーザー間で干渉しない。
#   - VS Code の Claude 拡張機能（anthropic.claude-code）はデフォルトでは
#     拡張機能に同梱の CLI を使おうとするため、ユーザーごとの VS Code User
#     settings（$HOME/.vscode/server-data/data/User/settings.json）に
#     claudeCode.claudeProcessWrapper を設定し、システムにインストール済みの
#     CLI を起動するようにする。この設定ファイルはユーザー本人が所有し、
#     他ユーザーの設定とは独立している。

# ユーザーの VS Code User settings に claudeCode.claudeProcessWrapper を設定する
# 引数: $1 = ユーザー名
claude_configure_vscode_extension() {
  local username="$1"
  local claude_bin="${CLAUDE_BIN:-$(command -v claude || echo /usr/bin/claude)}"
  local settings_dir="/home/${username}/.vscode/server-data/data/User"
  local settings_file="${settings_dir}/settings.json"

  mkdir -p "$settings_dir"

  python3 - "$settings_file" "$claude_bin" << 'PYEOF'
import json
import os
import sys

settings_file, claude_bin = sys.argv[1], sys.argv[2]

data = {}
if os.path.exists(settings_file):
    with open(settings_file, encoding="utf-8") as f:
        content = f.read().strip()
        if content:
            data = json.loads(content)

data["claudeCode.claudeProcessWrapper"] = claude_bin

with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

  chown -R "${username}:${username}" "/home/${username}/.vscode/server-data/data"
}

# $HOME/.claude/settings.json を用意する（既存ファイルは上書きしない）
# 引数: $1 = ユーザー名
claude_setup_user_settings() {
  local username="$1"
  local claude_dir="/home/${username}/.claude"
  local settings_file="${claude_dir}/settings.json"

  mkdir -p "$claude_dir"
  [[ -f "$settings_file" ]] || echo '{}' > "$settings_file"

  chown -R "${username}:${username}" "$claude_dir"
}
