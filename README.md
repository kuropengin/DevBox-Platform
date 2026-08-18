# DevBox Platform

RHEL 9 系（AlmaLinux 9 / Rocky Linux 9）で VS Code + Linux デスクトップ環境を
ユーザーごとに提供するプラットフォームです。

## アクセス構成

```
https://devbox.example.com
  /[username]/         → ポータルページ（静的 HTML）
  /[username]/vscode/  → VS Code (code serve-web)
  /[username]/gui/     → Xpra HTML5 デスクトップ
```

認証は **LLDAP（LDAP ディレクトリ）+ LemonLDAP::NG（ログイン画面 + nginx
Forward Auth）** で処理します。LLDAP は dnf（openSUSE Build Service 経由の
RPM）、LemonLDAP::NG は EPEL 公式パッケージでインストールでき、どちらも
ソースからのビルドが一切不要です。コンテナが使えない環境でもアップデートの
たびにビルド環境を整える必要がありません。

セッション Cookie を使った専用ログイン画面（`/_auth/`）を持ち、HTTP Basic
認証のようにリクエスト毎に資格情報を送り続けることはありません。

通信は install.sh が自動生成する**自己署名証明書**で HTTPS 化されており
（HTTP は 443 へ自動リダイレクト）、初回アクセス時にブラウザの警告を
承認する必要があります。VS Code Web の webview（拡張機能の Webview、
Markdown プレビュー等）はブラウザの Web Crypto API を使うため HTTPS
（セキュアコンテキスト）必須で、これが無いと動作しません。

## ファイル構成

```
devbox-platform/
├── portal/
│   └── index.html                    # ユーザーポータル（静的 HTML）
├── systemd/
│   ├── devbox@.target                # DevBox 管理ターゲット（テンプレート）
│   ├── vscode@.service               # VS Code serve-web
│   └── xpra@.service                 # Xpra HTML5 デスクトップ
└── scripts/
    ├── install.sh                    # 初回セットアップ（LLDAP / LemonLDAP::NG を含む）
    ├── adduser.sh                    # ユーザー追加
    ├── update-extensions.sh          # VS Code 拡張機能マスターセットの更新・全ユーザー配布
    ├── lib-vscode-extensions.sh      # 拡張機能マスター管理・配布の共通処理（上記2つが source）
    ├── vscode-extensions.list        # インストールする拡張機能 ID の一覧
    └── lib-claude.sh                 # Claude Code CLI 連携の共通処理（adduser.sh が source）
```

## 動作環境

- AlmaLinux 9 / Rocky Linux 9 / RHEL 9
- SELinux: Enforcing のまま動作（自動設定。ただし LemonLDAP::NG 部分は
  Enforcing 環境での動作を未検証、[LemonLDAP::NG / LLDAP 構成](#lemonldapng--lldap-構成) 参照）
- コンテナ / VM 不使用（すべてネイティブインストール）

## セットアップ

### 1. インストール

```bash
# ドメインまたは IP アドレスを指定
export DEVBOX_DOMAIN="192.168.11.64"

# 管理者パスワードを指定（省略時は自動生成）
export LLDAP_ADMIN_PASSWORD="yourpassword"

sudo -E bash scripts/install.sh
```

install.sh が行うこと:

| ステップ | 内容 |
|---------|------|
| EPEL + 基本パッケージ | epel-release, curl, wget, git, python3, openssl, rsync |
| VS Code | Microsoft rpm リポジトリから `code` をインストール |
| Java | Adoptium rpm リポジトリから `temurin-25-jdk`（Java 25）をインストール |
| **Claude Code CLI** | Anthropic rpm リポジトリから `claude-code` をインストール（詳細は[後述](#claude-code-cli)） |
| **VS Code 拡張機能** | `scripts/vscode-extensions.list` に基づきマスターセットを構築し、既存の全ユーザーへ配布（詳細は[後述](#vs-code-拡張機能)） |
| Xpra + xpra-html5 | EPEL + ソースビルド |
| XFCE | デスクトップ環境 |
| nginx | リバースプロキシ |
| **TLS 証明書** | 自己署名証明書を生成（`/etc/devbox/tls/`）。HTTP は 443 へリダイレクト |
| SELinux | `httpd_can_network_connect` を有効化 |
| firewalld | HTTP / HTTPS を開放（LLDAP・LemonLDAP::NG は localhost のみで待受） |
| **LLDAP** | dnf（OBS リポジトリの RPM）でネイティブインストール |
| **LemonLDAP::NG** | dnf（EPEL 公式パッケージ）でネイティブインストール |
| ポータル HTML | `/opt/devbox/portal/` へコピー |
| systemd ユニット | テンプレートユニットを `/etc/systemd/system/` へインストール |
| nginx 設定 | HTTPS + LemonLDAP::NG によるログイン画面 + Forward Auth 付きで生成 |

LLDAP 認証情報は `/etc/devbox/lldap.env`（権限 600）に保存されます。
TLS の秘密鍵は `/etc/devbox/tls/devbox.key`（権限 600）に保存されます。

`DEVBOX_DOMAIN` に IP アドレスを指定した場合、LemonLDAP::NG の Cookie
ドメイン制約（数字だけのラベルは不可）のため、install.sh が自動的に
`192-168-11-64.sslip.io` のような [sslip.io](https://sslip.io/) 経由の
ホスト名に変換します（インターネット経由の DNS 解決が必要です。閉域網の
場合は別途ホスト名を用意してください）。

#### LLDAP / LemonLDAP::NG をスキップしたい場合

```bash
SKIP_LLDAP=yes DEVBOX_DOMAIN=192.168.11.64 sudo -E bash scripts/install.sh
```

### 2. ユーザー追加

```bash
sudo bash scripts/adduser.sh yamada
sudo bash scripts/adduser.sh tanaka --cpu 400% --mem 8G
```

adduser.sh が行うこと:

| 処理 | 内容 |
|------|------|
| Linux ユーザー作成 | `useradd` でホームディレクトリ付き作成 |
| ポート割り当て | UID オフセットで自動計算・競合チェック |
| **VS Code 拡張機能配布** | マスターセットの独立コピーを `~/.vscode/server-data/extensions` へ配布（詳細は[後述](#vs-code-拡張機能)） |
| **Claude Code CLI 連携** | VS Code の Claude 拡張機能がシステムの `claude` を起動するよう設定し、`~/.claude/settings.json` を用意（詳細は[後述](#claude-code-cli)） |
| systemd | `vscode@` / `xpra@` を enable → `devbox@` ターゲットを起動 |
| nginx | `/etc/nginx/conf.d/devbox-users/[username].conf` を生成・リロード |
| LLDAP | `LLDAP_ADMIN_PASSWORD` がある場合のみ GraphQL API + `lldap_set_password` でユーザー登録 |

ユーザー名には `_auth` / `static` / `api` / `auth` / `lldap` / `lmauth` は
使用できません（nginx のトップレベルパスとして予約済みのため）。

## systemd 構成

```
devbox@{username}.target
├── vscode@{username}.service   code serve-web  port: 10000 + (UID-1000)
└── xpra@{username}.service     Xpra HTML5      port: 14500 + (UID-1000)
```

リソース制限（CPU / Memory）はドロップインで管理:
```
/etc/systemd/system/vscode@{username}.service.d/resources.conf
/etc/systemd/system/xpra@{username}.service.d/resources.conf
```

## サービス操作

```bash
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

# LLDAP / LemonLDAP::NG サービス確認
systemctl status lldap llng-fastcgi-server
```

## ポート割り当て

| UID  | VS Code ポート | Xpra ポート | Xpra ディスプレイ |
|------|---------------|------------|------------------|
| 1000 | 10000         | 14500      | :100             |
| 1001 | 10001         | 14501      | :101             |
| 1002 | 10002         | 14502      | :102             |

## VS Code 拡張機能

拡張機能は **root がマスターセットを一元管理し、各ユーザーには読み取り専用の
独立したコピーを配布する** 方式です。

```
scripts/vscode-extensions.list        インストールする拡張機能 ID の一覧（編集して追加/削除）
        ↓ install.sh / update-extensions.sh が code --install-extension で構築
/opt/devbox/vscode-extensions/        マスターセット（root 所有）
        ↓ adduser.sh（新規ユーザー時）/ update-extensions.sh（既存ユーザー更新時）が rsync で複製
/home/{username}/.vscode/server-data/extensions/   ユーザーごとの独立コピー（所有者 root、本人は読み取り専用）
```

| 要件 | 実現方法 |
|---|---|
| ユーザー間で干渉しない | 各ユーザーは共有ディレクトリではなく独立したコピーを持つ（`rsync -a --delete` で複製）。あるユーザーの VS Code プロセスが `extensions.json` 等へ書き込んでも他ユーザーには影響しない |
| root によるアップデートが全ユーザーに反映される | `sudo bash scripts/update-extensions.sh` を実行すると、マスターセットを最新化した上で登録済みの全ユーザーへ再配布し、起動中の `vscode@{username}.service` を再起動して反映する |
| ユーザー本人による追加インストールを禁止 | 配布後の拡張機能ディレクトリは `chown root:{username}` + `chmod 750`（本人は読み取り・実行のみ）にする。拡張機能に同梱されたネイティブバイナリの実行ビットは維持されるため動作に影響しない。VS Code の拡張機能ビューから「インストール」を実行してもファイル書き込みに失敗し、追加できない |

拡張機能を追加・削除・更新したい場合:

```bash
# scripts/vscode-extensions.list を編集後
sudo bash scripts/update-extensions.sh

# 起動中のセッションを止めずに配布だけ行いたい場合（反映は次回接続/再起動時）
sudo bash scripts/update-extensions.sh --no-restart
```

## Claude Code CLI

`claude` 本体は **システムに1つだけ**（`/usr/bin/claude`）インストールし、
VS Code の Claude 拡張機能（`anthropic.claude-code`）はユーザーごとの設定で
その共有バイナリを起動するようにします。CLI 自体の設定・会話履歴・認証情報は
実行ユーザーの `$HOME/.claude/` に保存される仕組みのため、バイナリを共有して
いてもユーザー間のデータは混ざりません。

install.sh が行うこと:

| ステップ | 内容 |
|---|---|
| リポジトリ登録 | `/etc/yum.repos.d/claude-code.repo`（`downloads.claude.ai` の公式 rpm リポジトリ） |
| インストール | `dnf install -y claude-code` |
| パス記録 | 検出した `claude` の絶対パスを `/etc/devbox/platform.conf` の `CLAUDE_BIN` に保存（adduser.sh が参照） |

adduser.sh が行うこと（ユーザーごと）:

| 処理 | 内容 |
|---|---|
| VS Code 拡張機能の連携 | `~/.vscode/server-data/data/User/settings.json` に `"claudeCode.claudeProcessWrapper": "<CLAUDE_BIN>"` を設定（既存の設定は保持したままマージ）。以後、拡張機能から起動される Claude はシステムの `claude` を使う |
| CLI 設定ファイルの用意 | `~/.claude/settings.json` が無ければ `{}` で作成（既存ファイルは上書きしない） |

いずれもユーザー本人が所有する通常のファイルとして作成されるため、VS Code
拡張機能側の他の設定や `~/.claude/settings.json` の内容は、これまで通り
本人が自由に編集できます（拡張機能自体のインストール制限とは別の話です。
拡張機能のインストール制限については[VS Code 拡張機能](#vs-code-拡張機能)を参照）。

## LemonLDAP::NG / LLDAP 構成

install.sh が自動でセットアップします。LLDAP は RPM パッケージ、
LemonLDAP::NG は EPEL 公式パッケージなので、どちらもビルドは発生しません。

| コンポーネント | 場所 |
|---|---|
| LLDAP | `dnf install lldap`（[openSUSE Build Service](https://software.opensuse.org//download.html?project=home%3AMasgalor%3ALLDAP&package=lldap) の非公式 RPM、GPG 署名済み） |
| LemonLDAP::NG | `dnf install lemonldap-ng lemonldap-ng-fastcgi-server lemonldap-ng-selinux`（EPEL 公式パッケージ） |
| LLDAP 設定ファイル | `/etc/lldap/lldap_config.toml` |
| LemonLDAP::NG 設定 | `lemonldap-ng-cli`（`/usr/libexec/lemonldap-ng/bin/lemonldap-ng-cli`）で投入。手組み JSON は `restore` ではなく `merge` を使うこと（`restore` は `cfgDate` が欠落し設定全体が読めなくなる） |
| 認証情報 | `/etc/devbox/lldap.env`（権限 600） |

アクセス経路（すべて単一ドメイン上のパスで区別、サブドメイン不要）:

| パス | 内容 |
|---|---|
| `/_auth/` | LemonLDAP::NG ポータル（ログイン画面） |
| `/_auth/static/` | ポータルの静的アセット（`staticPrefix` を変更し LLDAP の `/static/` と衝突しないようにしている） |
| `/lldap/` | LLDAP 管理画面（Web UI）。ポート 17170 は firewalld で開放せず、nginx 経由でのみアクセス可能 |
| `/static/` `/pkg/` `/api/` `/auth/` | LLDAP 管理画面が使う絶対パス（アプリ内部で固定参照されるため、この 4 つはトップレベルで LLDAP 専用に予約） |
| `/{username}/...` | 各ユーザーの devbox。`auth_request /lmauth;` で LemonLDAP::NG のセッションを確認 |

nginx は各ユーザーの location で `auth_request /lmauth;` を発行し、
LemonLDAP::NG の FastCGI ハンドラ（`llng-fastcgi-server`、Unix ソケット
`/run/llng-fastcgi-server/llng-fastcgi.sock`）にセッション Cookie の有無・
妥当性を問い合わせます。未認証の場合は `/_auth/` のログイン画面へ 302
リダイレクトされ、ログイン後はセッション Cookie で以後のアクセスが認可
されます。LLDAP・LemonLDAP::NG の管理系ポート（17170、Unix ソケット）は
いずれも外部に公開せず、nginx のパスルーティング経由でのみ到達可能です。

**アクセス制御（認可）**: 「ログイン済みかどうか」だけでなく「本人の
devbox かどうか」も LemonLDAP::NG の `locationRules` で制御しています。
adduser.sh がユーザー作成時に `^/{username}/(.*)  =>  $uid eq "{username}"`
という認可ルールを追加するため、ログイン済みの別ユーザーが他人の
`/{username}/` にアクセスすると 403 になります。既存ユーザー分の
ルールが入っていない環境（このアクセス制御を導入する前に作成した
ユーザー）では、該当ユーザーに対して adduser.sh を再実行するか、
`lemonldap-ng-cli merge` で個別にルールを追加してください。

**ログイン画面（ポータル）の設定**: 以下を install.sh が自動設定しています。

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
