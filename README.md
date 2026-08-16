# DevBox Platform

RHEL 9 系（AlmaLinux 9 / Rocky Linux 9）で VS Code + Linux デスクトップ環境を
ユーザーごとに提供するプラットフォームです。

## アクセス構成

```
http://devbox.example.com
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

## ファイル構成

```
devbox-platform/
├── portal/
│   └── index.html              # ユーザーポータル（静的 HTML）
├── systemd/
│   ├── devbox@.target          # DevBox 管理ターゲット（テンプレート）
│   ├── vscode@.service         # VS Code serve-web
│   └── xpra@.service           # Xpra HTML5 デスクトップ
└── scripts/
    ├── install.sh              # 初回セットアップ（LLDAP / LemonLDAP::NG を含む）
    └── adduser.sh              # ユーザー追加
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
| EPEL + 基本パッケージ | epel-release, curl, wget, git, python3, openssl |
| VS Code | Microsoft rpm リポジトリから `code` をインストール |
| Xpra + xpra-html5 | EPEL + ソースビルド |
| XFCE | デスクトップ環境 |
| nginx | リバースプロキシ |
| SELinux | `httpd_can_network_connect` を有効化 |
| firewalld | HTTP / HTTPS を開放（LLDAP・LemonLDAP::NG は localhost のみで待受） |
| **LLDAP** | dnf（OBS リポジトリの RPM）でネイティブインストール |
| **LemonLDAP::NG** | dnf（EPEL 公式パッケージ）でネイティブインストール |
| ポータル HTML | `/opt/devbox/portal/` へコピー |
| systemd ユニット | テンプレートユニットを `/etc/systemd/system/` へインストール |
| nginx 設定 | LemonLDAP::NG によるログイン画面 + Forward Auth 付きで生成 |

LLDAP 認証情報は `/etc/devbox/lldap.env`（権限 600）に保存されます。

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
