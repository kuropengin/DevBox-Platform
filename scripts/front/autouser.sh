#!/usr/bin/env bash
# DevBox Platform - front ユーザー自動反映スクリプト（front サーバー上で実行）
# 使い方: sudo bash autouser.sh
#
# リポジトリ直下の user/<IP> ファイル（書式は user/README.md 参照）全て
# （backend側と違い自ホストIPでの絞り込みはしない。front は全backendの
# ユーザーを把握する必要があるため）を desired state（username -> backend
# のIP）として、front 上の登録状況との差分を検出し
#   - desired にあって未登録、または別backendに登録済み
#     → register-user.sh --backend <IP> で登録（移行も兼ねる）
#   - 登録済みだが desired から消えた → deregister-user.sh で登録解除
# を自動で行う（非対話・確認プロンプト無し）。
#
# 事前に該当する backend で scripts/backend/autouser.sh
# （またはadduser-backend.sh）を実行しユーザーの実体を作成しておくこと。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
USER_DIR="${REPO_DIR}/user"

# shellcheck source=../lib-common.sh
source "${SCRIPT_DIR}/../lib-common.sh"

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash autouser.sh"

# ─── 1. user/ 配下の IPv4 ファイル全てから desired state を構築 ────────────────
# 書式: username:email[:cpu[:mem[:password]]]（cpu/mem はbackend側の値なので
# front側では読み捨てる。password は新規登録時のみ使う。詳細は
# user/README.md 参照）
IP_RE='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
declare -A DESIRED_BACKEND
declare -A DESIRED_PASSWORD

if [[ -d "$USER_DIR" ]]; then
  for f in "$USER_DIR"/*; do
    [[ -f "$f" ]] || continue
    fname="$(basename "$f")"
    [[ "$fname" =~ $IP_RE ]] || continue
    backend_ip="$fname"

    while IFS= read -r raw_line; do
      raw_line="${raw_line%%#*}"
      raw_line="$(echo -n "$raw_line" | xargs)"
      [[ -z "$raw_line" ]] && continue

      IFS=: read -r username email _cpu _mem password <<< "$raw_line"
      username="$(echo -n "$username" | xargs)"
      email="$(echo -n "$email" | xargs)"
      if [[ -z "$username" || -z "$email" ]]; then
        warn "不正な行をスキップ（${f}）: ${raw_line}"
        continue
      fi

      if [[ -n "${DESIRED_BACKEND[$username]:-}" && "${DESIRED_BACKEND[$username]}" != "$backend_ip" ]]; then
        warn "ユーザー '${username}' が複数の user/<IP> ファイルに重複しています。先に見つかった ${DESIRED_BACKEND[$username]} を優先します（${backend_ip} は無視）"
        continue
      fi
      DESIRED_BACKEND["$username"]="$backend_ip"
      DESIRED_PASSWORD["$username"]="$password"
    done < "$f"
  done
fi

info "desired ユーザー数: ${#DESIRED_BACKEND[@]}"

# ─── 2. 現状の登録済みユーザーとその backend を列挙 ────────────────────────────
declare -A CURRENT_BACKEND
shopt -s nullglob
for f in /etc/devbox/registrations/*.conf; do
  username="$(basename "$f" .conf)"
  backend_addr="$(grep '^BACKEND_ADDR=' "$f" | cut -d= -f2 || echo "")"
  # BACKEND_ADDR は "IP:port" 形式。user/<IP> ファイルはポート無しのIPのみ
  # なので、比較のためIP部分だけ取り出す。
  CURRENT_BACKEND["$username"]="${backend_addr%%:*}"
done
shopt -u nullglob

# ─── 3. 差分を反映 ─────────────────────────────────────────────────────────────
REGISTERED=0
DEREGISTERED=0
FAILED=0

for username in "${!DESIRED_BACKEND[@]}"; do
  desired_ip="${DESIRED_BACKEND[$username]}"
  current_ip="${CURRENT_BACKEND[$username]:-}"
  if [[ "$current_ip" != "$desired_ip" ]]; then
    if [[ -n "$current_ip" ]]; then
      info "移行: ${username} (${current_ip} → ${desired_ip})"
    else
      info "登録: ${username} (backend: ${desired_ip})"
    fi
    register_args=()
    [[ -n "${DESIRED_PASSWORD[$username]:-}" ]] && register_args+=(--password "${DESIRED_PASSWORD[$username]}")
    if bash "${SCRIPT_DIR}/register-user.sh" "$username" --backend "$desired_ip" "${register_args[@]}"; then
      REGISTERED=$((REGISTERED + 1))
    else
      warn "登録に失敗しました: ${username}"
      FAILED=$((FAILED + 1))
    fi
  fi
done

for username in "${!CURRENT_BACKEND[@]}"; do
  if [[ -z "${DESIRED_BACKEND[$username]:-}" ]]; then
    info "登録解除: ${username}（user/<IP>ファイルから記載が消えたため）"
    if bash "${SCRIPT_DIR}/deregister-user.sh" "$username"; then
      DEREGISTERED=$((DEREGISTERED + 1))
    else
      warn "登録解除に失敗しました: ${username}"
      FAILED=$((FAILED + 1))
    fi
  fi
done

echo ""
ok "front 自動反映完了（登録: ${REGISTERED}, 登録解除: ${DEREGISTERED}, 失敗: ${FAILED}）"
[[ "$FAILED" -gt 0 ]] && exit 1
exit 0
