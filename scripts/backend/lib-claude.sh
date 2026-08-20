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
#   - Headroom（front 側の LLMプロキシ）経由で Claude を使わせるため、
#     ANTHROPIC_BASE_URL・ANTHROPIC_AUTH_TOKEN・ANTHROPIC_CUSTOM_HEADERS を
#     ~/.claude/settings.json の env ブロックと、VS Code拡張機能の
#     claudeCode.environmentVariables の両方に設定する（Claude Code公式ドキュ
#     メント: 拡張機能は claudeCode.environmentVariables を起動前に独自に
#     チェックするため、settings.json の env だけでは拡張機能側のログイン
#     判定に反映されないことがある）。ANTHROPIC_AUTH_TOKEN には Headroom の
#     共有トークンをそのまま流用する（Claude Code はこの変数が無いと
#     ANTHROPIC_BASE_URL を設定していてもログイン画面を出してしまうための
#     ダミー資格情報。Headroom 自体は X-Headroom-Proxy-Token ヘッダで別途
#     検証する）。x-user-id にはユーザーのメールアドレスを入れ、Headroom が
#     x-headroom-* 以外のヘッダを上流 Anthropic まで転送する仕組みを使って
#     Anthropic 側にも届くようにする。

# ユーザーの VS Code User settings に claudeCode.claudeProcessWrapper と
# （Headroom設定があれば）claudeCode.environmentVariables を設定する
# 引数: $1 = ユーザー名  $2 = メールアドレス
#       $3 = Headroom base URL（例 http://10.0.1.5:8787、空なら未設定扱い）
#       $4 = Headroom共有トークン（空なら未設定扱い）
claude_configure_vscode_extension() {
  local username="$1"
  local email="${2:-}"
  local headroom_base_url="${3:-}"
  local headroom_token="${4:-}"
  local claude_bin="${CLAUDE_BIN:-$(command -v claude || echo /usr/bin/claude)}"
  local home_dir; home_dir="$(devbox_user_home "$username")"
  local settings_dir="${home_dir}/.vscode/server-data/data/User"
  local settings_file="${settings_dir}/settings.json"

  mkdir -p "$settings_dir"

  python3 - "$settings_file" "$claude_bin" "$headroom_base_url" "$headroom_token" "$email" << 'PYEOF'
import json
import os
import sys

settings_file, claude_bin, headroom_base_url, headroom_token, email = sys.argv[1:6]

data = {}
if os.path.exists(settings_file):
    with open(settings_file, encoding="utf-8") as f:
        content = f.read().strip()
        if content:
            data = json.loads(content)

data["claudeCode.claudeProcessWrapper"] = claude_bin

if headroom_base_url and headroom_token:
    custom_headers = f"X-Headroom-Proxy-Token: {headroom_token}\nx-user-id: {email}"
    desired = {
        "ANTHROPIC_BASE_URL": headroom_base_url,
        "ANTHROPIC_AUTH_TOKEN": headroom_token,
        "ANTHROPIC_CUSTOM_HEADERS": custom_headers,
    }

    existing = data.get("claudeCode.environmentVariables", [])
    if not isinstance(existing, list):
        existing = []
    by_name = {
        item["name"]: item
        for item in existing
        if isinstance(item, dict) and "name" in item
    }
    order = list(by_name.keys())
    for name, value in desired.items():
        by_name[name] = {"name": name, "value": value}
        if name not in order:
            order.append(name)

    data["claudeCode.environmentVariables"] = [by_name[n] for n in order]
    data["claudeCode.disableLoginPrompt"] = True

with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

  chown -R "${username}:${username}" "${home_dir}/.vscode/server-data/data"
}

# $HOME/.claude/settings.json を用意し、（Headroom設定があれば）env ブロックに
# Headroom 経由で Claude を使うための環境変数を設定する
# 引数: $1 = ユーザー名  $2 = メールアドレス
#       $3 = Headroom base URL（空なら未設定扱い）  $4 = Headroom共有トークン
claude_setup_user_settings() {
  local username="$1"
  local email="${2:-}"
  local headroom_base_url="${3:-}"
  local headroom_token="${4:-}"
  local home_dir; home_dir="$(devbox_user_home "$username")"
  local claude_dir="${home_dir}/.claude"
  local settings_file="${claude_dir}/settings.json"

  mkdir -p "$claude_dir"
  [[ -f "$settings_file" ]] || echo '{}' > "$settings_file"

  python3 - "$settings_file" "$headroom_base_url" "$headroom_token" "$email" << 'PYEOF'
import json
import os
import sys

settings_file, headroom_base_url, headroom_token, email = sys.argv[1:5]

data = {}
if os.path.exists(settings_file):
    with open(settings_file, encoding="utf-8") as f:
        content = f.read().strip()
        if content:
            data = json.loads(content)

if headroom_base_url and headroom_token:
    env = data.setdefault("env", {})
    env["ANTHROPIC_BASE_URL"] = headroom_base_url
    env["ANTHROPIC_AUTH_TOKEN"] = headroom_token
    env["ANTHROPIC_CUSTOM_HEADERS"] = f"X-Headroom-Proxy-Token: {headroom_token}\nx-user-id: {email}"

with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

  chown -R "${username}:${username}" "$claude_dir"
}
