# DevBox Platform

RHEL 9 系（AlmaLinux 9 / Rocky Linux 9）で VS Code + Linux デスクトップ環境を
ユーザーごとに提供するプラットフォームです。**front（認証 + ポータル配信）**
と **backend（ユーザーごとの実体・複数台に水平分割可能）** の2層構成で、
ユーザー数の増加に応じて backend を増設できます。1台構成にもできます
（[1台構成にする場合](#1台構成にする場合)を参照）。

## アーキテクチャ

```
インターネット
   │ HTTPS(443)
   ▼
┌────────────────────────────────┐
│ front（1台）                      │
│  - nginx（TLS終端・公開、443のみ）    │
│  - LLDAP + LemonLDAP::NG           │  ← 認証はここに一元化
│  - ポータル HTML（静的）             │
│  - /{user}/vscode|gui/ を           │
│    認証後に該当 backend の            │
│    80番へ proxy_pass                │
└──────────────────┬───────────────┘
                   │ HTTP(80) 平文・プライベートネットワーク限定
                   │ （firewalldでfrontの送信元IPのみ許可）
      ┌────────────┼────────────┐
      ▼            ▼            ▼
┌───────────┐┌───────────┐┌───────────┐
│ backend1    ││ backend2    ││ backend N   │  ← 何台でも追加可
│ nginx(local)  ││              ││              │
│ vscode@       ││ vscode@      ││ vscode@      │
│ xpra@         ││ xpra@        ││ xpra@        │
│ Java/Tomcat/  ││   同左         ││   同左         │
│ 拡張機能/Claude ││              ││              │
└───────────┘└───────────┘└───────────┘
```

- **front**: 外部公開する唯一の窓口。TLS終端（443のみ、80は使わない）、
  LLDAP + LemonLDAP::NG による認証、静的ポータルHTMLの配信、認証後の
  backend へのリバースプロキシを行う。ユーザーの実体（Linuxアカウントや
  systemd サービス）は持たない。
- **backend**: ユーザーの実体（Linux アカウント、`vscode@`/`xpra@`
  systemd サービス、Java/Tomcat/VS Code拡張機能/Claude Code CLI 等の
  開発ツール一式）を持つ。認証は行わず、front からのプロキシのみを
  ローカルの nginx（**80番のみ**、平文HTTP）で受け付ける。何台でも追加
  できる。backend で開放できるポートが80番に限られる環境を想定し、
  front は逆に80番を使わない（下記参照）ことで、front/backendを
  同一ホストに同居させても衝突しないようにしている。
- front と backend 間の通信は平文HTTPだが、backend 側の firewalld で
  front の送信元IPのみに制限することで保護する（front↔backend間は
  プライベートネットワークであることが前提）。
- front は 80 番を一切使わない（HTTP→HTTPS の自動リダイレクトは提供
  しない。ユーザーは常に `https://` を直接指定してアクセスする）。
  これにより front と backend が同一ホストに同居しても、80番は
  backend専用・443番はfront専用として衝突なく共存できる。
- URL パス構造（`/{username}/`, `/{username}/vscode/`, `/{username}/gui/`）は
  front から見ても backend から見ても同じで、front は認証後そのパスの
  ままプロキシするだけ。backend 側のローカル nginx がユーザーごとの
  ローカルポート（vscode@/xpra@）へ最終的に振り分ける。

### backend の 80 番に直接アクセスされた場合の保護

backend の nginx はそれ自体ではログイン認証を行わない（front で認証済みの
通信だけが来る前提）ため、**この内部ポートへの直接アクセスを防ぐこと自体
が認証の一部**です。単一の対策に依存しないよう、二重に防御しています。

| 層 | 内容 | 破られると… |
|---|---|---|
| ネットワーク（firewalld） | backend の80番は `FRONT_ALLOWED_SOURCE` で指定した送信元IPからしか受け付けない | 同一ネットワーク上の別ホストなど、許可された送信元になりすませる/そこから到達できる相手からは通る |
| アプリケーション（共有シークレット） | front は `install-front.sh` が生成した `DEVBOX_INTERNAL_TOKEN` を `X-Devbox-Token` ヘッダとして全リクエストに付与し、backend の nginx が一致しなければ **403** で拒否する（`X-Devbox-Token` が無い/違う直接アクセスは、firewalld を通過できたとしてもここで止まる） | トークンそのものが漏えいした場合（下記参照） |

つまり、firewalld が無効・誤設定であっても、`DEVBOX_INTERNAL_TOKEN` を
知らない相手が backend:80 に直接アクセスしても 403 で弾かれます。逆に、
`DEVBOX_INTERNAL_TOKEN` は front→backend間だけで完結させ、以下のように
漏えいを防いでいます:

- backend の `devbox-backend.conf`（トークンを平文で含む）は `chmod 640
  root:root` にし、devbox の一般ユーザー（VS Code のターミナル経由でも）
  からは読めないようにしている
- front の `devbox-front-users/{username}.conf`（同上）も同様に `chmod 640
  root:root`
- backend が `vscode@`/`xpra@` へ最終的にプロキシする際は `X-Devbox-Token`
  ヘッダを明示的に消しており（`proxy_set_header X-Devbox-Token "";`）、
  ユーザー本人のプロセスにも渡らない

このトークンは `/etc/devbox/platform.conf`（front、権限600）に保存されて
おり、`install-backend.sh` はこの値が `DEVBOX_INTERNAL_TOKEN` として
渡されていないと**エラーで停止**します（設定忘れで無防備な backend が
できてしまうことを防ぐため）。

## アクセス構成

```
https://devbox.example.com
  /[username]/         → ポータルページ（静的 HTML、front配信）
  /[username]/vscode/  → VS Code (code serve-web、backend上で実行)
  /[username]/gui/     → Xpra HTML5 デスクトップ（backend上で実行）
  /[username]/webapp/  → ユーザーが公開したWebアプリ（backend上で実行、認証なし）
  /_auth/               → LemonLDAP::NG純正ポータル（ログイン・ログアウト・パスワード変更）
```

`/[username]/vscode/`・`/[username]/gui/` は本人以外アクセスできませんが、
`/[username]/webapp/` は認証を行わないため誰でもアクセスできます
（詳細は[Webアプリの公開（webapp）](#webアプリの公開webapp)）。

ポータル画面には VS Code / GUI デスクトップ / 公開Webアプリ / パスワード
変更（LemonLDAP::NG純正ポータルへのリンク）へのボタンがあります。VS Code
は**初回アクセス時のみ** `~/workspace`（adduser-backend.sh が自動作成）を
自動で開きます（2回目以降は直前に開いていたフォルダ・ワークスペースを
維持します）。

認証は **LLDAP（LDAP ディレクトリ）+ LemonLDAP::NG（ログイン画面 + nginx
Forward Auth）** で処理します（front サーバーのみ）。LLDAP は dnf（openSUSE
Build Service 経由の RPM）、LemonLDAP::NG は EPEL 公式パッケージでインストール
でき、どちらもソースからのビルドが一切不要です。

セッション Cookie を使った専用ログイン画面（`/_auth/`）を持ち、HTTP Basic
認証のようにリクエスト毎に資格情報を送り続けることはありません。

通信は install-front.sh が自動生成する**自己署名証明書**で HTTPS 化されて
おり、初回アクセス時にブラウザの警告を承認する必要があります。VS Code Web
の webview（拡張機能の Webview、Markdown プレビュー等）はブラウザの
Web Crypto API を使うため HTTPS（セキュアコンテキスト）必須で、これが無い
と動作しません。front は 80 番ポートを使わない（backend が 80 番のみ
開放できる環境を想定しているため）ので、**HTTP→HTTPS の自動リダイレクトは
提供されません**。必ず `https://` を明示してアクセスしてください。
front↔backend間は平文HTTPですが、これは外部非公開のプライベートネット
ワーク上の通信です。

## ファイル構成

```
devbox-platform/
├── portal/
│   └── index.html                    # ユーザーポータル（静的 HTML、front配信）
├── user/
│   ├── README.md                     # user/<IP> ファイルの書式説明
│   └── <IPアドレス>                   # backendごとのユーザー一覧（autouser.sh が参照）
├── systemd/
│   ├── devbox@.target                # DevBox 管理ターゲット（backendに配置）
│   ├── vscode@.service               # VS Code serve-web（backendに配置）
│   ├── xpra@.service                 # Xpra HTML5 デスクトップ（backendに配置）
│   └── headroom.service              # Headroom LLMプロキシ（frontに配置）
└── scripts/
    ├── lib-common.sh                 # 全スクリプト共通のログ関数・ユーザー名検証（front/backend共通）
    ├── front/
    │   ├── install-front.sh          # front セットアップ（LLDAP / LemonLDAP::NG / Headroom を含む）
    │   ├── register-user.sh          # front でユーザーを登録（認証・ルーティング）
    │   ├── deregister-user.sh        # front でユーザーの登録を解除
    │   └── autouser.sh               # user/ 配下との差分をfrontに自動反映
    └── backend/
        ├── install-backend.sh        # backend セットアップ（開発ツール一式）
        ├── adduser-backend.sh        # backend でユーザーの実体を作成
        ├── deluser-backend.sh        # backend でユーザーの実体を削除
        ├── autouser.sh               # user/ 配下との差分をbackendに自動反映
        ├── update-extensions.sh      # VS Code 拡張機能マスターセットの更新・全ユーザー配布
        ├── update-tomcat.sh          # Tomcat 9 / 11 の更新
        ├── update-all.sh             # dnf update + 拡張機能更新 + Tomcat 更新を一括実行
        ├── lib-vscode-extensions.sh  # 拡張機能マスター管理・配布の共通処理
        ├── vscode-extensions.list    # インストールする拡張機能 ID の一覧
        ├── lib-tomcat.sh             # Tomcat tarball 導入・更新の共通処理
        └── lib-claude.sh             # Claude Code CLI 連携（Headroom設定含む）の共通処理
```

## 動作環境

- AlmaLinux 9 / Rocky Linux 9 / RHEL 9（front・backend とも）
- SELinux: Enforcing のまま動作（自動設定。ただし LemonLDAP::NG 部分は
  Enforcing 環境での動作を未検証、[LemonLDAP::NG / LLDAP 構成](#lemonldapng--lldap-構成) 参照）
- コンテナ / VM 不使用（すべてネイティブインストール）
- front と backend の間はプライベートネットワークで到達可能であること
  （同一ホストでもよい。[1台構成にする場合](#1台構成にする場合)を参照）

## セットアップ

### 1. front サーバーのインストール

```bash
# ドメインまたは IP アドレスを指定
export DEVBOX_DOMAIN="192.168.11.64"

# 管理者パスワードを指定（省略時は自動生成）
export LLDAP_ADMIN_PASSWORD="yourpassword"

# Headroom（LLMプロキシ）が使う実 Anthropic APIキー（必須）
export ANTHROPIC_API_KEY="sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx"

sudo -E bash scripts/front/install-front.sh
```

install-front.sh が行うこと:

| ステップ | 内容 |
|---------|------|
| EPEL + 基本パッケージ | epel-release, curl, python3, openssl |
| nginx | リバースプロキシ・TLS終端 |
| **TLS 証明書** | 自己署名証明書を生成（`/etc/devbox/tls/`）。443 のみで待受（80は使わない） |
| SELinux | `httpd_can_network_connect` を有効化 |
| firewalld | HTTPS のみ全世界に開放（80は開放しない。LLDAP・LemonLDAP::NG は localhost のみで待受） |
| **LLDAP** | dnf（OBS リポジトリの RPM）でネイティブインストール |
| **LemonLDAP::NG** | dnf（EPEL 公式パッケージ）でネイティブインストール |
| ポータル HTML | `/opt/devbox/portal/` へコピー |
| **Headroom（LLMプロキシ）** | pip でインストールし systemd サービス化（詳細は[後述](#headroomllmプロキシ)） |
| nginx 設定 | `/etc/nginx/conf.d/devbox-front.conf` を HTTPS + LemonLDAP::NG Forward Auth 付きで生成 |

LLDAP 認証情報は `/etc/devbox/lldap.env`（権限 600）に保存されます。
TLS の秘密鍵は `/etc/devbox/tls/devbox.key`（権限 600）に保存されます。

`DEVBOX_DOMAIN` に IP アドレスを指定した場合、LemonLDAP::NG の Cookie
ドメイン制約（数字だけのラベルは不可）のため、install-front.sh が自動的に
`192-168-11-64.sslip.io` のような [sslip.io](https://sslip.io/) 経由の
ホスト名に変換します（インターネット経由の DNS 解決が必要です。閉域網の
場合は別途ホスト名を用意してください）。

#### LLDAP / LemonLDAP::NG をスキップしたい場合

```bash
SKIP_LLDAP=yes DEVBOX_DOMAIN=192.168.11.64 sudo -E bash scripts/front/install-front.sh
```

### 2. backend サーバーのインストール（backendごとに実行）

```bash
# front サーバーの IP または CIDR を指定
# （backend の内部ポート80はこの送信元からのみ firewalld で許可される）
export FRONT_ALLOWED_SOURCE="10.0.1.5"

# front で install-front.sh 実行後に表示された値をそのまま指定
export DEVBOX_INTERNAL_TOKEN="<front の完了メッセージに表示された値>"
export DEVBOX_HEADROOM_TOKEN="<同じく front の完了メッセージに表示された値>"
export HEADROOM_BASE_URL="http://10.0.1.5:8787"

sudo -E bash scripts/backend/install-backend.sh
```

backend は何台でも追加できます。追加のたびに、そのホストで
`install-backend.sh` を実行するだけです（front 側の再インストールは
不要）。`DEVBOX_INTERNAL_TOKEN`・`DEVBOX_HEADROOM_TOKEN` は front と
backend 全台で共通の値を使ってください（front の
`/etc/devbox/platform.conf` に保存されています）。
`HEADROOM_BASE_URL`/`DEVBOX_HEADROOM_TOKEN` が無くても install-backend.sh
自体は失敗しませんが、未設定のままユーザーを作成すると Claude Code が
使えません（詳細は[後述](#headroomllmプロキシ)）。

install-backend.sh が行うこと:

| ステップ | 内容 |
|---------|------|
| EPEL + 基本パッケージ | epel-release, curl, git, python3, rsync, tar |
| VS Code | Microsoft rpm リポジトリから `code`（serve-web）をインストール |
| Java | Adoptium rpm リポジトリから `temurin-8-jdk` / `temurin-25-jdk`（Java 8・25）を並行インストール |
| **Apache Tomcat** | archive.apache.org の公式 tarball から 9 系・11 系を並行インストール（詳細は[後述](#apache-tomcat)） |
| **Claude Code CLI** | Anthropic rpm リポジトリから `claude-code` をインストール（詳細は[後述](#claude-code-cli)） |
| **VS Code 拡張機能** | `scripts/backend/vscode-extensions.list` に基づきマスターセットを構築し、既存の全ユーザーへ配布（詳細は[後述](#vs-code-拡張機能)） |
| Xpra + xpra-html5 | EPEL + ソースビルド |
| XFCE | デスクトップ環境 |
| nginx | ローカル用途のみ（TLSなし、80番で待受） |
| SELinux | `httpd_can_network_connect` を有効化 |
| **firewalld** | 80番を `FRONT_ALLOWED_SOURCE` からのみ許可（未指定時は一切開放しない。firewalld 自体が無効な場合は強く警告） |
| systemd ユニット | `devbox@.target` / `vscode@.service` / `xpra@.service` を `/etc/systemd/system/` へインストール |
| nginx 設定 | `/etc/nginx/conf.d/devbox-backend.conf` を平文HTTP・`DEVBOX_INTERNAL_TOKEN` 必須で生成（詳細は[backend の 80 番に直接アクセスされた場合の保護](#backend-の-80-番に直接アクセスされた場合の保護)） |

`FRONT_ALLOWED_SOURCE` を指定しないと 80 番ポートは firewalld で
一切開放されません（安全側デフォルト）。後から開放したい場合は
インストール完了メッセージに表示される `firewall-cmd` コマンドを実行して
ください。`DEVBOX_INTERNAL_TOKEN` を指定しない場合、install-backend.sh は
エラーで停止します（無防備な backend が意図せずできることを防ぐため）。

ユーザーディレクトリ（`/home/<username>` 相当）をマウントした別ボリューム
に作りたい場合は `USER_HOME_BASE`（例: `/mnt/userdata`、事前にマウント
済みであること）を指定してください。詳細は
[ユーザーディレクトリの配置先](#ユーザーディレクトリの配置先)を参照して
ください。

### 3. ユーザー追加（backend → front の2段階）

```bash
# ① backend サーバーで実行: ユーザーの実体（Linuxアカウント・systemdサービス）を作成
sudo bash scripts/backend/adduser-backend.sh yamada yamada@example.com
sudo bash scripts/backend/adduser-backend.sh tanaka tanaka@example.com --cpu 400% --mem 8G

# ② front サーバーで実行: 認証・ルーティングを登録
sudo bash scripts/front/register-user.sh yamada --backend 10.0.2.11
sudo bash scripts/front/register-user.sh tanaka --backend 10.0.2.12
```

`--backend` にはユーザーを配置した backend サーバーの IP（または
`host:port`。port省略時は80）を指定します。**どの backend に
配置するかは管理者が明示的に選びます**（自動割り当てはしません）。
`<email>` は Headroom 経由で Claude を使う際の `X-User-Id` ヘッダに
使われます（詳細は[後述](#headroomllmプロキシ)）。

adduser-backend.sh が行うこと（backend 上）:

| 処理 | 内容 |
|------|------|
| Linux ユーザー作成 | `useradd` でホームディレクトリ付き作成 |
| 作業フォルダ作成 | `~/workspace` を作成（ポータルの VS Code リンクが初回アクセス時に自動で開く） |
| ポート割り当て | UID オフセットで自動計算・競合チェック（VS Code / Xpra / Tomcat-webapp用、backend内でローカルに完結） |
| **VS Code 拡張機能配布** | マスターセットの独立コピーを `~/.vscode/server-data/extensions` へ配布（詳細は[後述](#vs-code-拡張機能)） |
| **VS Code 既定設定** | `~/.vscode/server-data/data/User/settings.json` に `security.workspace.trust.startupPrompt: always` をマージ設定 |
| **Claude Code CLI 連携** | VS Code の Claude 拡張機能がシステムの `claude` を起動するよう設定し、`~/.claude/settings.json` を用意。Headroom設定があれば `ANTHROPIC_BASE_URL` 等も設定（詳細は[後述](#claude-code-cli)・[後述](#headroomllmプロキシ)） |
| systemd | `vscode@` / `xpra@` を enable → `devbox@` ターゲットを起動 |
| nginx | `/etc/nginx/conf.d/devbox-backend-users/[username].conf` を生成・リロード（認証なし、ローカルプロキシのみ。`webapp` locationも含む。詳細は[後述](#webアプリの公開webapp)） |

register-user.sh が行うこと（front 上）:

| 処理 | 内容 |
|------|------|
| 疎通確認 | 指定した backend の `/{username}/vscode/` へ疎通確認（失敗しても続行） |
| 登録情報保存 | `/etc/devbox/registrations/[username].conf`（どの backend に配置したかを記録） |
| nginx | `/etc/nginx/conf.d/devbox-front-users/[username].conf` を生成・リロード（`vscode`/`gui`/ポータルは認証付き、`webapp` のみ認証なしでbackendへプロキシ） |
| LLDAP | `LLDAP_ADMIN_PASSWORD` がある場合のみ GraphQL API + `lldap_set_password` でユーザー登録 |
| LemonLDAP::NG | 本人のみ `/{username}/` にアクセスできる認可ルールを追加 |

`--backend` を変えて `register-user.sh` を再実行すると、そのユーザーの
ルーティング先を別の backend へ移行できます（先にそのユーザーを新しい
backend で `adduser-backend.sh` しておくこと）。

ユーザー名には `_auth` / `static` / `api` / `auth` / `lldap` / `lmauth` は
使用できません（front の nginx でトップレベルパスとして予約済みのため）。

### 4. ユーザー削除（front → backend の2段階、追加とは逆順）

```bash
# ① front サーバーで実行: 登録を解除し、ただちにログイン・アクセスを遮断
sudo bash scripts/front/deregister-user.sh yamada

# ② backend サーバーで実行: 実体（Linuxアカウント・systemdサービス）を削除
sudo bash scripts/backend/deluser-backend.sh yamada

# ホームディレクトリ（コード・データ）も完全に削除したい場合
sudo bash scripts/backend/deluser-backend.sh yamada --purge
```

追加とは逆に、**先に front で `deregister-user.sh`** を実行してください
（LLDAP アカウントを削除し即座にログイン不能にしてから、backend 側の実体を
片付ける順序）。

deregister-user.sh が行うこと（front 上）:

| 処理 | 内容 |
|------|------|
| nginx | `/etc/nginx/conf.d/devbox-front-users/[username].conf` を削除・リロード |
| 登録情報削除 | `/etc/devbox/registrations/[username].conf` を削除 |
| LLDAP | GraphQL API でユーザーを削除（以後ログイン不可） |

deluser-backend.sh が行うこと（backend 上）:

| 処理 | 内容 |
|------|------|
| systemd | `vscode@` / `xpra@` / `devbox@` を停止・無効化し、CPU/MEMドロップインを削除 |
| nginx | `/etc/nginx/conf.d/devbox-backend-users/[username].conf` を削除・リロード |
| Linux ユーザー削除 | `userdel`（`--purge` 指定時のみ `-r` でホームディレクトリも削除） |

デフォルトではホームディレクトリ（コード等のデータ）を残します。誤削除
からの復旧や監査のためで、完全に削除したい場合のみ `--purge` を指定して
ください。

LemonLDAP::NG の認可ルール（`^/{username}/(.*) => $uid eq "{username}"`）は
自動削除しません。LLDAP アカウントが無くなるため事実上無効化されますが、
きれいに消したい場合は `lemonldap-ng-cli` で個別に削除してください。

### 1台構成にする場合

front と backend を同一ホストで動かすこともできます。front は443のみ、
backend は80のみとリッスンポートが分かれており、nginx 設定ファイル名も
別（`devbox-front*.conf` / `devbox-backend*.conf`）なため、同居させても
衝突しません。ただし front が80番を使わない設計上、同居構成では
HTTP→HTTPS の自動リダイレクトが効きません（`https://` を明示してください）。

```bash
# 1. front を先にインストール（DEVBOX_INTERNAL_TOKEN・DEVBOX_HEADROOM_TOKEN
#    がここで生成される。ANTHROPIC_API_KEY は必須）
DEVBOX_DOMAIN=192.168.11.64 ANTHROPIC_API_KEY="sk-ant-xxxx" \
  BACKEND_ALLOWED_SOURCES=127.0.0.1 sudo -E bash scripts/front/install-front.sh
# 完了メッセージに表示された DEVBOX_INTERNAL_TOKEN・DEVBOX_HEADROOM_TOKEN を控えておく

# 2. backend をインストール（自分自身を front とみなし 127.0.0.1 を指定）
FRONT_ALLOWED_SOURCE=127.0.0.1 DEVBOX_INTERNAL_TOKEN="<上記の値>" \
  DEVBOX_HEADROOM_TOKEN="<上記の値>" HEADROOM_BASE_URL="http://127.0.0.1:8787" \
  sudo -E bash scripts/backend/install-backend.sh

# 3. ユーザー追加も同一ホストで両方実行
sudo bash scripts/backend/adduser-backend.sh yamada yamada@example.com
sudo bash scripts/front/register-user.sh yamada --backend 127.0.0.1
```

## ユーザーの自動反映（autouser）

`adduser-backend.sh`/`register-user.sh`（追加）・`deluser-backend.sh`/
`deregister-user.sh`（削除）を都度手動実行する代わりに、`user/` ディレクトリ
（書式は [user/README.md](user/README.md)）を desired state として GitOps的に
運用できます。

```
user/
├── 10.0.2.11    # backend1 (10.0.2.11) に置くユーザー一覧
└── 10.0.2.12    # backend2 (10.0.2.12) に置くユーザー一覧
```

各ファイルの中身は `username:email[:cpu[:mem[:password]]]` を
1行1ユーザーで列挙したものです（`cpu`/`mem`/`password` は省略可。
詳細は [user/README.md](user/README.md)）:

```
yamada:yamada@example.com
tanaka:tanaka@example.com:100%:2G
suzuki:suzuki@example.com:150%:3G:S3cr3tPass
```

運用の流れ:

```bash
# 1. user/<backendのIP> を編集（追加/削除）してコミット・push

# 2. 対象の backend サーバーで
git pull && sudo bash scripts/backend/autouser.sh

# 3. front サーバーで
git pull && sudo bash scripts/front/autouser.sh
```

| スクリプト | 動作 |
|---|---|
| `scripts/backend/autouser.sh` | **自ホストの IP と一致する** `user/<IP>` ファイルだけを desired state とし、`/etc/devbox/users/*.conf` との差分から `adduser-backend.sh`（追加。`cpu`/`mem` 指定があれば `--cpu`/`--mem` として渡す）/ `deluser-backend.sh`（削除）を自動実行 |
| `scripts/front/autouser.sh` | `user/` 配下の**全ファイル**を desired state とし（front は全backendのユーザーを把握する必要があるため自IPでの絞り込みはしない）、`/etc/devbox/registrations/*.conf` との差分から `register-user.sh --backend <ファイル名のIP>`（登録・別backendへの移行。`password` 指定があれば `--password` として渡す＝新規LLDAPユーザー作成時のみ有効）/ `deregister-user.sh`（登録解除）を自動実行 |

いずれも非対話（確認プロンプト無し）で、cron 等からの定期実行を想定して
います。削除はデフォルトでホームディレクトリを残します
（`deluser-backend.sh` のデフォルト動作と統一。誤ってファイルから1行
消してしまった場合のデータ消失を防ぐため）。完全に削除したい場合は
`deluser-backend.sh <username> --purge` を手動で実行してください。

`user/` はリポジトリに含まれるため、front・各backendとも同じ内容を
参照できるよう、実行前に必ず `git pull` してください。

## systemd 構成（backend）

```
devbox@{username}.target
├── vscode@{username}.service   code serve-web  port: 10000 + (UID-1000)
└── xpra@{username}.service     Xpra HTML5      port: 14500 + (UID-1000)
```

`TOMCAT_PORT`（18080 + (UID-1000)）は systemd サービスとしては存在せず、
`/etc/devbox/users/{username}.conf` に予約されるだけのポート番号です
（詳細は[Webアプリの公開（webapp）](#webアプリの公開webapp)）。

リソース制限（CPU / Memory）はドロップインで管理:
```
/etc/systemd/system/vscode@{username}.service.d/resources.conf
/etc/systemd/system/xpra@{username}.service.d/resources.conf
```

## サービス操作

```bash
# --- backend 上 ---
# 起動 / 停止 / 再起動
systemctl start   devbox@yamada.target
systemctl stop    devbox@yamada.target
systemctl restart vscode@yamada.service

# 状態確認
systemctl status  devbox@yamada.target
ss -tlnp | grep -E '10000|14500'

# ログ確認
journalctl -u vscode@yamada.service -f
journalctl -u xpra@yamada.service   -f

# --- front 上 ---
# LLDAP / LemonLDAP::NG サービス確認
systemctl status lldap llng-fastcgi-server
```

## アップデート

いずれも **backend ごとに個別に実行**します（`/etc/devbox/users/*.conf`
や拡張機能マスターセット、Tomcat は backend ごとにローカルなため）。

| スクリプト | 内容 |
|---|---|
| `sudo bash scripts/backend/update-extensions.sh [--no-restart]` | VS Code 拡張機能マスターセットを更新し、そのbackend上の全ユーザーへ配布（詳細は[VS Code 拡張機能](#vs-code-拡張機能)） |
| `sudo bash scripts/backend/update-tomcat.sh [9\|11]` | Tomcat を archive.apache.org の最新パッチへ更新（詳細は[Apache Tomcat](#apache-tomcat)） |
| `sudo bash scripts/backend/update-all.sh [--no-restart]` | `dnf update -y`（VS Code / Java / Claude Code CLI 等の dnf 管理パッケージも含む）+ 上記2つを一括実行 |

front 側（nginx / LLDAP / LemonLDAP::NG）は通常の `dnf update -y` で
更新してください。

## ポート割り当て（backend内でローカルに独立）

各 backend は UID オフセットで独立にポートを割り当てるため、backend間の
調整は不要です（backendが違えばホストも別なので同じポート番号でも衝突
しません）。

| UID  | VS Code ポート | Xpra ポート | Xpra ディスプレイ | webapp用ポート |
|------|---------------|------------|------------------|---------------|
| 1000 | 10000         | 14500      | :100             | 18080         |
| 1001 | 10001         | 14501      | :101             | 18081         |
| 1002 | 10002         | 14502      | :102             | 18082         |

front↔backend間の内部通信ポートは固定で **80** です
（`DEVBOX_BACKEND_PORT`）。

## 環境変数（VS Code内で利用可能）

`adduser-backend.sh` はユーザーごとに `/etc/devbox/users/{username}.conf`
を生成します。このファイルは `vscode@.service`/`xpra@.service`
（[systemd/vscode@.service](systemd/vscode@.service)）の
`EnvironmentFile=` として読み込まれるため、ここに書かれた変数は
`code serve-web` プロセス自身と、そこから起動される全ての子プロセス
（VS Code の統合ターミナル等）に環境変数として引き継がれます。
つまりユーザーは VS Code のターミナルで `echo $TOMCAT_PORT` のように
そのまま参照できます。

| 変数 | 内容 |
|---|---|
| `USERNAME` | ユーザー名 |
| `VSCODE_PORT` | `code serve-web` がローカルで待ち受けるポート（`10000 + (UID-1000)`） |
| `XPRA_PORT` | Xpra HTML5 デスクトップがローカルで待ち受けるポート（`14500 + (UID-1000)`） |
| `XPRA_DISPLAY` | Xpra の Xディスプレイ番号（`100 + (UID-1000)`、`:100` 形式ではなく数値のみ） |
| `TOMCAT_PORT` | `/{username}/webapp/` として公開されるポート（`18080 + (UID-1000)`）。詳細は[Webアプリの公開（webapp）](#webアプリの公開webapp) |
| `CPU_QUOTA` | systemd `CPUQuota` に設定した値（例: `200%`。`adduser-backend.sh --cpu` で指定） |
| `MEMORY_MAX` | systemd `MemoryMax` に設定した値（例: `4G`。`adduser-backend.sh --mem` で指定） |
| `CREATED_AT` | ユーザー作成日時（UTC、ISO 8601） |

新しい変数を追加したい場合は `adduser-backend.sh` の
`/etc/devbox/users/${USERNAME}.conf` を生成する箇所に追記するだけで、
上記の仕組みにより自動的に VS Code 側からも参照可能になります
（`vscode@.service`/`xpra@.service` 側の変更は不要）。

## ユーザーディレクトリの配置先

既定ではユーザーディレクトリは通常の Linux ホームディレクトリ
（`/home/<username>`）に作成されますが、`USER_HOME_BASE` を指定すること
でマウントした別ボリューム（例: `/mnt/userdata`）配下に作成できます。

**backend側**（`install-backend.env`）:

```bash
USER_HOME_BASE=/mnt/userdata
```

`useradd --base-dir "$USER_HOME_BASE"` でユーザーを作成するため、実際の
ホームは `${USER_HOME_BASE}/<username>` になります。指定するボリュームは
事前にマウント済みである必要があります（`install-backend.sh`/
`adduser-backend.sh` 自体はマウント処理を行いません）。

`vscode@.service`/`xpra@.service`（[systemd/vscode@.service](systemd/vscode@.service)）
は `WorkingDirectory=`/`Environment=HOME=` 等に実パスを必要とするため、
`install-backend.sh` が systemd ユニットをインストールする際に
`__USER_HOME_BASE__` プレースホルダーを実際の値へ置換します（systemd の
`%h` 指定子は `User=` の設定を反映しない＝常にサービスマネージャ自身の
ホームになってしまうため使えません）。`adduser-backend.sh`・
[lib-vscode-extensions.sh](scripts/backend/lib-vscode-extensions.sh)・
[lib-claude.sh](scripts/backend/lib-claude.sh) 側は
`devbox_user_home()`（[lib-common.sh](scripts/lib-common.sh)、`/etc/passwd`
の実際の値を参照）を使って解決するため、`USER_HOME_BASE` を変更しても
追加のコード変更は不要です。

**front側**（`install-front.env`、任意）:

```bash
USER_HOME_BASE=/mnt/userdata
```

ポータルが VS Code 初回アクセス時に自動で開く `~/workspace`
（[アクセス構成](#アクセス構成)参照）のパスを組み立てるために使います。
front はbackendのファイルシステムを直接参照できないため、**backend側の
`USER_HOME_BASE` と同じ値を front 側にも指定してください**（一致しない
と初回オープンのパスが誤ったものになります。1台構成の場合は前後半で
共通の値を使うので特に注意）。未設定時は従来通り `/home` として扱われ、
これまでと同じ動作になります。

`USER_HOME_BASE` を後から変更した場合は、対象の backend/front で
`install-backend.sh`/`install-front.sh` を再実行してください
（systemd ユニット・ポータル HTML に値が焼き込まれるため、設定ファイルの
更新だけでは反映されません）。既存ユーザーのホームディレクトリは
移動されません。

## VS Code 拡張機能

以下はすべて **backend 側** の話です。拡張機能は **root がマスターセット
を一元管理し、各ユーザーには独立したコピーを配布する** 方式です。

```
scripts/backend/vscode-extensions.list        インストールする拡張機能 ID の一覧（編集して追加/削除）
        ↓ install-backend.sh / update-extensions.sh が code --install-extension で構築
/opt/devbox/vscode-extensions/        マスターセット（root 所有）
        ↓ adduser-backend.sh（新規ユーザー時）/ update-extensions.sh（既存ユーザー更新時）が rsync で複製
/home/{username}/.vscode/server-data/extensions/   ユーザーごとの独立コピー
```

配布後の権限は **2階層**になっています（[lib-vscode-extensions.sh](scripts/backend/lib-vscode-extensions.sh)
の `vscode_ext_sync_to_user()`）:

| 階層 | 権限 | 目的 |
|---|---|---|
| `extensions/` 直下（トップレベル） | `chown root:{username}` + `chmod 750`（本人は読み取り・実行のみ） | 拡張機能の新規追加・アンインストール（＝トップレベルへのディレクトリ作成・削除）を禁止する |
| 各拡張機能フォルダ（`vscjava.vscode-java-debug-x.y.z/` 等）の中身 | `chown -R {username}:{username}`（本人が読み書き可能） | 一部の拡張機能は本来 VS Code が提供する `globalStorage` 等ではなく**自身のインストールディレクトリ内**に実行時ファイルを書き込む実装になっており（拡張機能側の実装上の問題）、そこが読み取り専用だと `activate()` 自体が失敗するため（実例は下記） |

| 要件 | 実現方法 |
|---|---|
| ユーザー間で干渉しない | 各ユーザーは共有ディレクトリではなく独立したコピーを持つ（`rsync -a --delete` で複製）。あるユーザーの VS Code プロセスが拡張機能フォルダへ書き込んでも他ユーザーには影響しない |
| root によるアップデートが同一backend内の全ユーザーに反映される | そのbackendで `sudo bash scripts/backend/update-extensions.sh` を実行すると、マスターセットを最新化した上で登録済みの全ユーザーへ再配布し、起動中の `vscode@{username}.service` を再起動して反映する。本人が拡張機能フォルダの中身を書き換えていても `rsync --delete` で master の内容に上書きされる（master自体はroot専有で保護） |
| ユーザー本人による追加インストール・アンインストールを禁止 | トップレベルが `chmod 750` のため、VS Code の拡張機能ビューから「インストール」を実行してもディレクトリ作成に失敗し、追加できない |

拡張機能を追加・削除・更新したい場合（対象の backend で実行）:

```bash
# scripts/backend/vscode-extensions.list を編集後
sudo bash scripts/backend/update-extensions.sh

# 起動中のセッションを止めずに配布だけ行いたい場合（反映は次回接続/再起動時）
sudo bash scripts/backend/update-extensions.sh --no-restart
```

実例（上記の2階層構成が必要だった理由）: `vscjava.vscode-java-debug`
（Java拡張パックに含まれる）の「設定なしデバッグ」機能は
`<拡張機能のインストールパス>/.noConfigDebugAdapterEndpoints/`
にファイルを書き込もうとします。拡張機能フォルダの中身が読み取り専用だと
これが失敗し、デバッグ実行時に
`Couldn't find a debug adapter descriptor for debug type 'java'`
というエラーになります。既存ユーザーに修正を適用するには、対象の backend
で `sudo bash scripts/backend/update-extensions.sh` を実行してください
（再配布と `vscode@{username}.service` の再起動が行われます）。

## Apache Tomcat

以下はすべて **backend 側** の話です。Apache Tomcat は公式の dnf/yum
リポジトリを提供していません。RHEL 9 系の EPEL にある `tomcat` パッケージ
も 9.0 系が1つあるだけで、複数のメジャーバージョンを dnf で並存させる
ことはできません。そのため **archive.apache.org の公式 tarball** を
取得し、バージョンごとに展開して共存させています。

```
https://archive.apache.org/dist/tomcat/tomcat-{9,11}/   最新パッチバージョンを自動検出
        ↓ tar.gz + .sha512 チェックサム検証の上でダウンロード・展開
/opt/devbox/tomcat/releases/{9,11}/apache-tomcat-<version>/   実体（root 所有、全ユーザー読み取り・実行可、書き込みは root のみ）
        ↓ シンボリックリンク
/opt/devbox/tomcat/tomcat{9,11}                                CATALINA_HOME として使う安定パス
```

公式 tarball は `conf/` が 700、起動スクリプトが 750 など「配布時のまま
では root 以外アクセス不可」な権限になっているため、展開後に
`chmod -R a+rX,go-w` で全ユーザーが読み取り・実行できるように調整して
います（書き込みは引き続き root のみ）。

各ユーザーが自分用のインスタンスを動かす場合は、`CATALINA_HOME` は
共有ディレクトリを指したまま、`CATALINA_BASE` だけ自分のホーム配下に
用意してください（Tomcat 標準の複数インスタンス構成）。ポートは
`$TOMCAT_PORT`（VS Code の統合ターミナルで参照可能。詳細は
[Webアプリの公開（webapp）](#webアプリの公開webapp)）を
`conf/server.xml` の HTTP コネクタに指定してください。

```bash
export CATALINA_HOME=/opt/devbox/tomcat/tomcat9
export CATALINA_BASE=~/tomcat9-instance
mkdir -p "$CATALINA_BASE"/{conf,logs,temp,webapps,work}
cp "$CATALINA_HOME"/conf/* "$CATALINA_BASE"/conf/
sed -i "s/port=\"8080\"/port=\"${TOMCAT_PORT}\"/" "$CATALINA_BASE"/conf/server.xml
"$CATALINA_HOME"/bin/startup.sh
```

更新（対象の backend で実行）:

```bash
sudo bash scripts/backend/update-tomcat.sh        # 9・11 の両方を最新パッチへ
sudo bash scripts/backend/update-tomcat.sh 9      # 9 系のみ
```

## Webアプリの公開（webapp）

各ユーザーには VS Code / Xpra と同様に、Web アプリ公開用のポート
（`$TOMCAT_PORT`、UIDから自動計算）が1つ割り当てられます。**Tomcat等の
起動・設定はユーザー本人が行います**（プラットフォーム側で自動的に
インスタンスを起動することはありません）。

```
ユーザーが 127.0.0.1:$TOMCAT_PORT で何かを起動する
        ↓
https://<front>/{username}/webapp/  でアクセス可能
```

- `$TOMCAT_PORT` は VS Code の統合ターミナルから環境変数として参照でき
  ます（`$VSCODE_PORT`/`$XPRA_PORT`/`$XPRA_DISPLAY` と同じ仕組みで、
  `/etc/devbox/users/{username}.conf` が `vscode@.service` の
  `EnvironmentFile` として読み込まれ、そこから起動される全プロセス
  （統合ターミナル含む）に伝播します）。
- Tomcat に限らず、127.0.0.1:`$TOMCAT_PORT` で Listen する任意のアプリ
  （Node.js、Flask 等）を公開できます。
- **`/{username}/webapp/` は意図的に認証を行いません**（LemonLDAP::NGの
  `auth_request` を通しません）。ポータルの「公開 Web アプリ」ボタンや
  URLを知っていれば誰でもアクセスできるため、機密情報を扱うアプリは
  公開しないでください。
- まだ何も起動していない状態でアクセスすると 502 Bad Gateway になります
  （想定通りの動作です）。

## Claude Code CLI

以下はすべて **backend 側** の話です。`claude` 本体は **backendごとに
1つだけ**（`/usr/bin/claude`）インストールし、VS Code の Claude 拡張機能
（`anthropic.claude-code`）はユーザーごとの設定でその共有バイナリを起動
するようにします。CLI 自体の設定・会話履歴・認証情報は実行ユーザーの
`$HOME/.claude/` に保存される仕組みのため、バイナリを共有していても
ユーザー間のデータは混ざりません。

install-backend.sh が行うこと:

| ステップ | 内容 |
|---|---|
| リポジトリ登録 | `/etc/yum.repos.d/claude-code.repo`（`downloads.claude.ai` の公式 rpm リポジトリ） |
| インストール | `dnf install -y claude-code` |

adduser-backend.sh が行うこと（ユーザーごと）:

| 処理 | 内容 |
|---|---|
| VS Code 拡張機能の連携 | `~/.vscode/server-data/data/User/settings.json` に `"claudeCode.claudeProcessWrapper": "<claudeの絶対パス>"` を設定（既存の設定は保持したままマージ）。以後、拡張機能から起動される Claude はシステムの `claude` を使う |
| CLI 設定ファイルの用意 | `~/.claude/settings.json` が無ければ `{}` で作成（既存ファイルは上書きしない） |
| **Headroom連携** | `HEADROOM_BASE_URL`/`DEVBOX_HEADROOM_TOKEN` が設定されていれば、両方の設定ファイルに Headroom 経由で Claude を使うための環境変数もマージ書き込みする（詳細は[後述](#headroomllmプロキシ)） |

いずれもユーザー本人が所有する通常のファイルとして作成されるため、VS Code
拡張機能側の他の設定や `~/.claude/settings.json` の内容は、これまで通り
本人が自由に編集できます（拡張機能自体のインストール制限とは別の話です。
拡張機能のインストール制限については[VS Code 拡張機能](#vs-code-拡張機能)を参照）。

## Headroom（LLMプロキシ）

各ユーザーが Anthropic の実 API キーを個別に持たずに済むよう、front に
[Headroom](https://github.com/headroomlabs-ai/headroom)（LLMトークン圧縮
プロキシ。`ANTHROPIC_BASE_URL` を向けるだけで Claude Code から使える）を
導入し、実キーは front だけが保持します。backend 上の各ユーザーは Headroom
を経由して Claude を使い、リクエストには `X-User-Id: <メールアドレス>`
ヘッダが付与されます。

```
front                                          backend（ユーザーごと）
┌──────────────────────┐                        ┌──────────────────────┐
│ Headroom（8787番）      │  ← X-Headroom-Proxy-  │ Claude Code CLI        │
│  ANTHROPIC_TARGET_     │    Token で認証         │  ANTHROPIC_BASE_URL   │
│  API_HEADERS で実の      │  ← X-User-Id はそのまま │  → Headroom            │
│  x-api-key を注入して    │    上流Anthropicまで   │  ANTHROPIC_CUSTOM_     │
│  Anthropicへ            │    転送                │  HEADERS で両方付与     │
└──────────────────────┘                        └──────────────────────┘
```

### front 側（install-front.sh）

| ステップ | 内容 |
|---|---|
| Python 3.11 | `dnf install python3.11 python3.11-pip`（headroom-ai は Python 3.10 以上が必須。RHEL 9 系の既定 python3 は 3.9 のため別途インストール） |
| インストール | `python3.11 -m pip install "headroom-ai[proxy]"` |
| **上流認証** | `ANTHROPIC_TARGET_API_HEADERS` に `x-api-key`/`anthropic-version` を注入して起動（実機検証済み: `ANTHROPIC_API_KEY` 環境変数だけでは Headroom は upstream を認証しない） |
| **クライアント認証** | `HEADROOM_PROXY_TOKEN`（`DEVBOX_HEADROOM_TOKEN`）を設定し、`X-Headroom-Proxy-Token` ヘッダの無い/誤った直接アクセスを拒否 |
| systemd | `systemd/headroom.service` を `/etc/systemd/system/` へインストールし `enable --now`（`/etc/devbox/headroom.env` を bash で source してから起動。理由は下記） |
| firewalld | 8787番を `BACKEND_ALLOWED_SOURCES` からのみ許可（未指定時は一切開放しない） |

`ANTHROPIC_API_KEY` を install-front.env に指定しないと install-front.sh は
エラーで停止します。

### backend 側（adduser-backend.sh / lib-claude.sh）

`<email>` 引数と `/etc/devbox/backend-platform.conf`（install-backend.sh が
`HEADROOM_BASE_URL`/`DEVBOX_HEADROOM_TOKEN` から生成）を使い、
`~/.claude/settings.json` の `env` ブロックと VS Code拡張機能の
`claudeCode.environmentVariables` の両方に以下を設定します
（[Claude Code公式ドキュメント](https://code.claude.com/docs/en/llm-gateway-connect)
の LLMゲートウェイ接続手順に準拠。拡張機能は起動前に独自に資格情報を
チェックするため、settings.json の env だけでは不十分）:

| 環境変数 | 値 | 目的 |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `HEADROOM_BASE_URL` | Headroom を Claude のエンドポイントにする |
| `ANTHROPIC_AUTH_TOKEN` | `DEVBOX_HEADROOM_TOKEN` | Claude Code 自体のログイン画面を回避するためのダミー資格情報（Headroom自体はこの値を見ない） |
| `ANTHROPIC_CUSTOM_HEADERS` | `X-Headroom-Proxy-Token: <token>\nX-User-Id: <email>` | 前者はHeadroomクライアント認証用、後者はユーザー識別用。Headroom は `x-headroom-*` 接頭辞のヘッダだけを上流送信前に除去するため、`X-User-Id` は Anthropic まで届く |

`claudeCode.disableLoginPrompt: true` も合わせて設定し、拡張機能側の
ログイン画面が出ないようにします。`HEADROOM_BASE_URL`/
`DEVBOX_HEADROOM_TOKEN` が未設定のまま `adduser-backend.sh` を実行した
場合はこれらの設定を書き込まず、warn を出すだけに留めます（Headroom未導入
のbackendでも壊れないように）。

### 導入後の確認

Anthropic への実際のリクエストが成功するかは、本物の APIキーが無い環境
では机上検証できません。導入後は必ず、ユーザーとして `claude` を起動し
`/status` で `Anthropic base URL` と `Auth token` の行が正しいことを確認し、
実際にプロンプトを送って応答が返ることを確認してください
（[トラブルシューティング](https://code.claude.com/docs/en/llm-gateway-connect#troubleshoot-gateway-errors)）。

## LemonLDAP::NG / LLDAP 構成

以下はすべて **front 側** の話です。install-front.sh が自動でセットアップ
します。LLDAP は RPM パッケージ、LemonLDAP::NG は EPEL 公式パッケージなので、
どちらもビルドは発生しません。

| コンポーネント | 場所 |
|---|---|
| LLDAP | `dnf install lldap`（[openSUSE Build Service](https://software.opensuse.org//download.html?project=home%3AMasgalor%3ALLDAP&package=lldap) の非公式 RPM、GPG 署名済み） |
| LemonLDAP::NG | `dnf install lemonldap-ng lemonldap-ng-fastcgi-server lemonldap-ng-selinux`（EPEL 公式パッケージ） |
| LLDAP 設定ファイル | `/etc/lldap/lldap_config.toml` |
| LemonLDAP::NG 設定 | `lemonldap-ng-cli`（`/usr/libexec/lemonldap-ng/bin/lemonldap-ng-cli`）で投入。手組み JSON は `restore` ではなく `merge` を使うこと（`restore` は `cfgDate` が欠落し設定全体が読めなくなる） |
| 認証情報 | `/etc/devbox/lldap.env`（権限 600） |

アクセス経路（すべて front の単一ドメイン上のパスで区別、サブドメイン不要）:

| パス | 内容 |
|---|---|
| `/_auth/` | LemonLDAP::NG ポータル（ログイン画面） |
| `/_auth/static/` | ポータルの静的アセット（`staticPrefix` を変更し LLDAP の `/static/` と衝突しないようにしている） |
| `/lldap/` | LLDAP 管理画面（Web UI）。ポート 17170 は firewalld で開放せず、nginx 経由でのみアクセス可能 |
| `/static/` `/pkg/` `/api/` `/auth/` | LLDAP 管理画面が使う絶対パス（アプリ内部で固定参照されるため、この 4 つはトップレベルで LLDAP 専用に予約） |
| `/{username}/...` | 各ユーザーの devbox。front が `auth_request /lmauth;` で LemonLDAP::NG のセッションを確認したのち、該当 backend へプロキシ |

front の nginx は各ユーザーの location で `auth_request /lmauth;` を発行し、
LemonLDAP::NG の FastCGI ハンドラ（`llng-fastcgi-server`、Unix ソケット
`/run/llng-fastcgi-server/llng-fastcgi.sock`）にセッション Cookie の有無・
妥当性を問い合わせます。未認証の場合は `/_auth/` のログイン画面へ 302
リダイレクトされ、ログイン後はセッション Cookie で以後のアクセスが認可
されます。LLDAP・LemonLDAP::NG の管理系ポート（17170、Unix ソケット）は
いずれも外部に公開せず、nginx のパスルーティング経由でのみ到達可能です。
認証は front だけで完結し、backend はそれ自体を検証しません（backend の
内部ポートを front 以外へ公開しないことがセキュリティ上必須です）。

**アクセス制御（認可）**: 「ログイン済みかどうか」だけでなく「本人の
devbox かどうか」も LemonLDAP::NG の `locationRules` で制御しています。
register-user.sh がユーザー登録時に `^/{username}/(.*)  =>  $uid eq
"{username}"` という認可ルールを追加するため、ログイン済みの別ユーザーが
他人の `/{username}/` にアクセスすると 403 になります。既存ユーザー分の
ルールが入っていない環境（このアクセス制御を導入する前に作成した
ユーザー）では、該当ユーザーに対して register-user.sh を再実行するか、
`lemonldap-ng-cli merge` で個別にルールを追加してください。

**ログイン画面（ポータル）の設定**: 以下を install-front.sh が自動設定
しています。

| 項目 | 設定 |
|---|---|
| ログアウト | 有効（`/_auth/?logout=1`。devbox ポータル画面下部にリンクあり） |
| パスワード変更 | 有効（`/_auth/index.psgi/changepwd`。LDAP のパスワードが直接更新される） |
| 新規アカウント作成 | 無効（`registerDB=Null` に加え `portalDisplayRegister=0` でボタン自体も非表示） |
| アプリ一覧タブ・ログイン履歴タブ・セッション再確認リンク | 非表示（`portalDisplay*` を無効化。devbox 一台の運用では不要なため） |
| ログイン画面の「前回のログインを確認」チェックボックス | 非表示（`portalCheckLogins=0`） |

> **注意**:
> - LLDAP の RPM は LLDAP プロジェクト公式ではなく、openSUSE Build
>   Service 上の個人メンテナ（@Masgalor）によるビルドです。LLDAP 本体の
>   リリースそのものは公式リポジトリのものです。
> - LemonLDAP::NG 部分は SELinux Enforcing 環境での動作を実機検証できて
>   いません（検証用サンドボックスが Permissive/Disabled のため）。
>   `lemonldap-ng-selinux` パッケージが必要なポリシーを提供する想定です
>   が、Enforcing なホストで導入する際は `journalctl` や `ausearch -m avc`
>   を確認してください。

詳細:
- https://github.com/lldap/lldap
- https://github.com/lldap/lldap/blob/main/docs/install.md#from-a-package-repository
- https://lemonldap-ng.org/documentation/latest/
- https://nginx.org/en/docs/http/ngx_http_auth_request_module.html
- https://sslip.io/
