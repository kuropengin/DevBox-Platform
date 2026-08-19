#!/usr/bin/env bash
# DevBox Platform - backend ユーザー自動反映スクリプト（backend サーバー上で実行）
# 使い方: sudo bash autouser.sh
#
# リポジトリ直下の user/<IP> ファイル（書式は user/README.md 参照）のうち、
# ファイル名がこのホスト自身の IP アドレスと一致するものを desired state
# として、backend 上の実ユーザーとの差分を検出し
#   - desired にあって未作成 → adduser-backend.sh で作成
#   - 作成済みだが desired から消えた → deluser-backend.sh で削除
#     （--purge は付けない。ホームディレクトリは残す）
# を自動で行う。GitOps的に user/ を編集して git pull した後、cron 等から
# 定期実行する運用を想定している（非対話・確認プロンプト無し）。
#
# 該当する user/<IP> ファイルが無いホストでは何もせず正常終了する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
USER_DIR="${REPO_DIR}/user"

# shellcheck source=../lib-common.sh
source "${SCRIPT_DIR}/../lib-common.sh"

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo bash autouser.sh"

# ─── 1. 自ホストの IP アドレスを列挙 ───────────────────────────────────────────
mapfile -t MY_IPS < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
if [[ ${#MY_IPS[@]} -eq 0 ]]; then
  die "このホストの IPv4 アドレスを取得できませんでした（ip コマンドを確認してください）"
fi

# ─── 2. 自ホストのIPと一致する user/<IP> ファイルを検出 ────────────────────────
IP_RE='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
MATCHED_FILES=()
if [[ -d "$USER_DIR" ]]; then
  for f in "$USER_DIR"/*; do
    [[ -f "$f" ]] || continue
    fname="$(basename "$f")"
    [[ "$fname" =~ $IP_RE ]] || continue
    for ip in "${MY_IPS[@]}"; do
      if [[ "$ip" == "$fname" ]]; then
        MATCHED_FILES+=("$f")
        break
      fi
    done
  done
fi

if [[ ${#MATCHED_FILES[@]} -eq 0 ]]; then
  info "このホスト（IP: ${MY_IPS[*]}）に対応する user/<IP> ファイルが見つかりません。何もしません"
  exit 0
fi

info "対象ファイル: ${MATCHED_FILES[*]}"

# ─── 3. desired state（username -> email/cpu/mem）を構築 ─────────────────────
# 書式: username:email[:cpu[:mem[:password]]]（password はbackend側では
# 使わないので読み捨てる。詳細は user/README.md 参照）
declare -A DESIRED
declare -A DESIRED_CPU
declare -A DESIRED_MEM
for f in "${MATCHED_FILES[@]}"; do
  while IFS= read -r raw_line; do
    raw_line="${raw_line%%#*}"
    raw_line="$(echo -n "$raw_line" | xargs)"
    [[ -z "$raw_line" ]] && continue

    IFS=: read -r username email cpu mem _password <<< "$raw_line"
    username="$(echo -n "$username" | xargs)"
    email="$(echo -n "$email" | xargs)"
    cpu="$(echo -n "$cpu" | xargs)"
    mem="$(echo -n "$mem" | xargs)"
    if [[ -z "$username" || -z "$email" ]]; then
      warn "不正な行をスキップ（${f}）: ${raw_line}"
      continue
    fi

    DESIRED["$username"]="$email"
    DESIRED_CPU["$username"]="$cpu"
    DESIRED_MEM["$username"]="$mem"
  done < "$f"
done

info "desired ユーザー数: ${#DESIRED[@]}"

# ─── 4. 現状の backend 管理下ユーザーを列挙 ────────────────────────────────────
declare -A CURRENT
shopt -s nullglob
for f in /etc/devbox/users/*.conf; do
  username="$(basename "$f" .conf)"
  CURRENT["$username"]=1
done
shopt -u nullglob

# ─── 5. 差分を反映 ─────────────────────────────────────────────────────────────
ADDED=0
REMOVED=0
FAILED=0

for username in "${!DESIRED[@]}"; do
  if [[ -z "${CURRENT[$username]:-}" ]]; then
    info "追加: ${username} (${DESIRED[$username]})"
    extra_args=()
    [[ -n "${DESIRED_CPU[$username]}" ]] && extra_args+=(--cpu "${DESIRED_CPU[$username]}")
    [[ -n "${DESIRED_MEM[$username]}" ]] && extra_args+=(--mem "${DESIRED_MEM[$username]}")
    if bash "${SCRIPT_DIR}/adduser-backend.sh" "$username" "${DESIRED[$username]}" "${extra_args[@]}"; then
      ADDED=$((ADDED + 1))
    else
      warn "追加に失敗しました: ${username}"
      FAILED=$((FAILED + 1))
    fi
  fi
done

for username in "${!CURRENT[@]}"; do
  if [[ -z "${DESIRED[$username]:-}" ]]; then
    info "削除: ${username}（user/<IP>ファイルから記載が消えたため。ホームディレクトリは残します）"
    if bash "${SCRIPT_DIR}/deluser-backend.sh" "$username"; then
      REMOVED=$((REMOVED + 1))
    else
      warn "削除に失敗しました: ${username}"
      FAILED=$((FAILED + 1))
    fi
  fi
done

echo ""
ok "backend 自動反映完了（追加: ${ADDED}, 削除: ${REMOVED}, 失敗: ${FAILED}）"
[[ "$FAILED" -gt 0 ]] && exit 1
exit 0
