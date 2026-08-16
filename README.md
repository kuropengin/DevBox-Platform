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

認証は **LLDAP（LDAP ディレクトリ）+ auth-ldap（自作の nginx auth_request ブリッジ）**
で nginx レベルの Basic 認証として処理します。LLDAP は dnf（openSUSE Build
Service 経由の RPM）でインストールでき、auth-ldap は Python 標準ライブラリのみ
で書かれた小さなスクリプトです。どちらもソースからのビルドが一切不要なため、
コンテナが使えない環境でもアップデートのたびにビルド環境を整える必要が
ありません。

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
    ├── install.sh              # 初回セットアップ（LLDAP / auth-ldap を含む）
    ├── adduser.sh              # ユーザー追加
    └── auth-ldap/
        └── auth_ldap.py        # nginx auth_request → LDAP bind ブリッジ
```

## 動作環境

- AlmaLinux 9 / Rocky Linux 9 / RHEL 9
- SELinux: Enforcing のまま動作（自動設定）
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
| firewalld | HTTP / HTTPS / 17170(LLDAP 管理画面) を開放 |
| **LLDAP** | dnf（OBS リポジトリの RPM）でネイティブインストール |
| **auth-ldap** | nginx auth_request 用の LDAP bind ブリッジ（Python 標準ライブラリのみ） |
| ポータル HTML | `/opt/devbox/portal/` へコピー |
| systemd ユニット | テンプレートユニットを `/etc/systemd/system/` へインストール |
| nginx 設定 | LDAP Basic 認証（auth-ldap 経由）付きで生成 |

LLDAP 認証情報は `/etc/devbox/lldap.env`（権限 600）に保存されます。

#### LLDAP をスキップしたい場合

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

# LLDAP / auth-ldap サービス確認
systemctl status lldap auth-ldap
```

## ポート割り当て

| UID  | VS Code ポート | Xpra ポート | Xpra ディスプレイ |
|------|---------------|------------|------------------|
| 1000 | 10000         | 14500      | :100             |
| 1001 | 10001         | 14501      | :101             |
| 1002 | 10002         | 14502      | :102             |

## LLDAP / auth-ldap 構成

install.sh が自動でセットアップします。LLDAP は RPM パッケージ、auth-ldap は
リポジトリに含まれる Python 標準ライブラリのみのスクリプトなので、どちらも
ビルドは一切発生しません。

| コンポーネント | 場所 |
|---|---|
| LLDAP | `dnf install lldap`([openSUSE Build Service](https://software.opensuse.org//download.html?project=home%3AMasgalor%3ALLDAP&package=lldap) の非公式 RPM、GPG 署名済み) |
| openldap-clients | `dnf install openldap-clients`（RHEL 公式パッケージ、`ldapwhoami` を使用） |
| auth-ldap | `/opt/devbox/auth-ldap/auth_ldap.py`（本リポジトリ同梱） |
| LLDAP 設定ファイル | `/etc/lldap/lldap_config.toml` |
| 認証情報 | `/etc/devbox/lldap.env`（権限 600） |

管理画面（Web UI）: `http://{DEVBOX_DOMAIN}:17170`（Base DN: `dc=devbox,dc=local`）

nginx は各ユーザーの location で `auth_request /auth-ldap;` を発行し、
`auth-ldap`（127.0.0.1:9091）が Basic 認証のユーザー名/パスワードを
LLDAP（127.0.0.1:3890）に対して LDAP bind することで認証します。auth-ldap
自体は localhost のみで待ち受け、外部に公開されません。LLDAP の LDAP
プロトコル（3890番ポート）も firewalld で開放しないため外部到達不可ですが、
管理 Web UI（17170番ポート）は管理者の利便性のため意図的に公開しています。

> **注意**: LLDAP の RPM は LLDAP プロジェクト公式ではなく、openSUSE Build
> Service 上の個人メンテナ（@Masgalor）によるビルドです。LLDAP 本体の
> リリースそのものは公式リポジトリのものです。

詳細:
- https://github.com/lldap/lldap
- https://github.com/lldap/lldap/blob/main/docs/install.md#from-a-package-repository
- https://nginx.org/en/docs/http/ngx_http_auth_request_module.html
