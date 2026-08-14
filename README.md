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

認証は **Authentik Forward Auth** で nginx レベルで処理します。

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
    ├── install.sh              # 初回セットアップ（Authentik を含む）
    └── adduser.sh              # ユーザー追加
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
export AUTHENTIK_ADMIN_PASSWORD="yourpassword"

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
| firewalld | HTTP / HTTPS / 9000(Authentik) を開放 |
| **Authentik** | PostgreSQL + Redis + Python 3.12 venv でネイティブインストール |
| ポータル HTML | `/opt/devbox/portal/` へコピー |
| systemd ユニット | テンプレートユニットを `/etc/systemd/system/` へインストール |
| nginx 設定 | Authentik Forward Auth 付きで生成 |

Authentik 認証情報は `/etc/devbox/authentik.env`（権限 600）に保存されます。

#### Authentik をスキップしたい場合

```bash
SKIP_AUTHENTIK=yes DEVBOX_DOMAIN=192.168.11.64 sudo -E bash scripts/install.sh
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
| Authentik | `AUTHENTIK_TOKEN` がある場合のみ API でユーザー登録 |

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

# Authentik サービス確認
systemctl status authentik-server authentik-worker
```

## ポート割り当て

| UID  | VS Code ポート | Xpra ポート | Xpra ディスプレイ |
|------|---------------|------------|------------------|
| 1000 | 10000         | 14500      | :100             |
| 1001 | 10001         | 14501      | :101             |
| 1002 | 10002         | 14502      | :102             |

## Authentik 構成

install.sh が自動でセットアップします:

| コンポーネント | 場所 |
|---|---|
| PostgreSQL | `dnf install postgresql-server` |
| Redis | `dnf install redis` |
| Python 3.12 | `dnf install python3.12` |
| Authentik | `/opt/authentik/venv/` (pip install) |
| 設定ファイル | `/opt/authentik/.env` |
| 認証情報 | `/etc/devbox/authentik.env` |

管理画面: `http://{DEVBOX_DOMAIN}:9000`

詳細: https://docs.goauthentik.io/docs/providers/proxy/forward_auth
