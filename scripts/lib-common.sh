#!/usr/bin/env bash
# DevBox Platform - 全スクリプト共通のログ関数・ユーザー名検証
# front/backend いずれのスクリプトからも source して使う。

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# nginx のトップレベルパスとして front 側で予約済み
# （LemonLDAP::NG ポータル / LLDAP 管理画面）。backend 単体では衝突しないが、
# front/backend どちらで実行しても同じ制約になるよう共通化しておく。
DEVBOX_RESERVED_USERNAMES=(_auth static pkg api auth lldap lmauth)

# ユーザー名の形式・予約語をチェックする。不正なら die する。
# 引数: $1 = ユーザー名
devbox_validate_username() {
  local username="$1"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "無効なユーザー名: $username"

  local reserved
  for reserved in "${DEVBOX_RESERVED_USERNAMES[@]}"; do
    [[ "$username" == "$reserved" ]] && die "'${username}' は予約語のため使用できません"
  done

  # ループの最後の比較が false（= 予約語ではない、正常系）で終わると、
  # 関数の戻り値がそのまま非ゼロになり、呼び出し元で `set -e` により
  # 何もエラーを出さずスクリプトが停止してしまう。それを防ぐため明示的に
  # 成功を返す。
  return 0
}

# メールアドレスの簡易形式チェック。不正なら die する。
# 引数: $1 = メールアドレス
devbox_validate_email() {
  local email="$1"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "無効なメールアドレス: $email"
  return 0
}

# 指定した Linux ユーザーの実際のホームディレクトリを返す（/etc/passwd の
# 6番目のフィールド）。USER_HOME_BASE（マウント場所の変更等）でホーム
# ディレクトリの置き場所を変えても、常に実際の値を参照できるようにする
# ための共通ヘルパー。ユーザーが存在しない場合は空文字を返す。
# 引数: $1 = ユーザー名
devbox_user_home() {
  getent passwd "$1" | cut -d: -f6
}
