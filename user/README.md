# user/ ディレクトリ

`scripts/backend/autouser.sh` / `scripts/front/autouser.sh` が読む、
ユーザーの desired state（あるべき状態）を宣言するディレクトリです。
GitOps的に、このディレクトリを編集して `git pull` した後に
`autouser.sh` を実行すると、実際のユーザー環境が自動的に差分反映されます。

## ファイル配置

- ファイル名 = 対象 **backend サーバーの IP アドレス**（例: `10.0.2.11`）
- 1ファイル = そのbackendに存在すべきユーザーの一覧

```
user/
├── 10.0.2.11    # backend1 (10.0.2.11) のユーザー一覧
└── 10.0.2.12    # backend2 (10.0.2.12) のユーザー一覧
```

## ファイル書式

1行1ユーザー、`username:email[:cpu[:mem[:password]]]` 形式。`#` 以降
（行頭・行中どちらでも）はコメントとして無視され、空行も無視されます。

- `cpu` … CPU上限（systemd `CPUQuota`、例: `200%`）。省略時は
  `adduser-backend.sh` のデフォルト（`200%`）
- `mem` … メモリ上限（`MemoryMax`、例: `4G`）。省略時はデフォルト（`4G`）
- `password` … LLDAP に**新規**ユーザーを作成する際の初期パスワード。
  省略時は自動生成。**既存ユーザーには使われません**
  （再実行してもパスワードは変わりません）

`cpu`/`mem`/`password` はどれも省略可能で、末尾から順に省略できます。
`password` だけ指定して `cpu`/`mem` は省略したい場合は、間のフィールドを
空のまま `:` で埋めてください（例: `user:user@example.com:::mypassword`）。

```
# 10.0.2.11 に置くユーザー
yamada:yamada@example.com
tanaka:tanaka@example.com:100%:2G
suzuki:suzuki@example.com:150%:3G:S3cr3tPass
```

> **セキュリティ上の注意**: `password` を指定すると初期パスワードが
> このリポジトリに平文で残ります。`user/` を git 管理する場合
> （推奨構成）、リポジトリへのアクセス権を持つ全員がその平文パスワードを
> 読めることになります。運用上問題がなければ `password` は省略し、
> 自動生成されたパスワードを `register-user.sh` の実行結果（標準出力）
> から個別に伝える運用を推奨します。

## 動作

- **backend で `scripts/backend/autouser.sh` を実行**すると、そのホスト
  自身の IP アドレスと一致するファイルだけを desired state として扱い、
  実際の Linux ユーザーとの差分を検出して
  `adduser-backend.sh`（追加）/ `deluser-backend.sh`（削除、
  ホームディレクトリは残します）を自動実行します。
- **front で `scripts/front/autouser.sh` を実行**すると、`user/` 配下の
  ファイル全てを読み、`register-user.sh --backend <ファイル名のIP>`
  （登録・別backendへの移行）/ `deregister-user.sh`（登録解除）を
  自動実行します。

## 運用の流れ

1. `user/<backendのIP>` を編集してユーザーを追加/削除
2. 対象の backend サーバーで: `git pull && sudo bash scripts/backend/autouser.sh`
3. front サーバーで: `git pull && sudo bash scripts/front/autouser.sh`

削除はデフォルトでホームディレクトリを残します（誤ってファイルから
1行消してしまった場合のデータ消失を防ぐため）。完全に削除したい場合は
`scripts/backend/deluser-backend.sh <username> --purge` を手動で実行して
ください。
