# DevBox Platform

Ubuntu Server で VS Code + Linux デスクトップ環境を手軽に提供するプラットフォームです。

## 構成

```
devbox.example.com
  /[username]/         → ポータルページ（静的 HTML）
  /[username]/vscode/  → code-server（VS Code）
  /[username]/gui/     → Xpra HTML5 デスクトップ
```

認証は **Authentik Forward Auth** で nginx レベルで処理します。

## ファイル構成

```
devbox-platform/
├── portal/
│   └── index.html          # ユーザーポータル（静的 HTML）
├── systemd/
│   ├── devbox@.target      # DevBox 管理ターゲット（テンプレート）
│   ├── vscode@.service     # code serve-web
│   └── xpra@.service
└── scripts/
    ├── install.sh          # 初回セットアップ
    └── adduser.sh          # ユーザー追加
```

## セットアップ

### 動作環境

- AlmaLinux 9 / Rocky Linux 9 / RHEL 9
- SELinux: Enforcing のまま動作（自動設定）

### 1. インストール

```bash
# Authentik 認証情報を設定（任意）
export AUTHENTIK_URL="https://auth.example.com"
export AUTHENTIK_TOKEN="your-api-token"
export DEVBOX_DOMAIN="devbox.example.com"

sudo -E bash scripts/install.sh
```

install.sh が行うこと:
- EPEL リポジトリ追加・CRB 有効化
- nginx / VS Code（Microsoft rpm リポジトリ）/ Xpra / xpra-html5 / XFCE のインストール
- SELinux: `httpd_can_network_connect` を有効化
- firewalld: HTTP/HTTPS を開放
- `/opt/devbox/portal/` へポータル HTML をコピー
- systemd テンプレートユニットをインストール
- nginx メイン設定（Authentik Forward Auth）を生成

### 2. ユーザー追加

```bash
sudo bash scripts/adduser.sh yamada
sudo bash scripts/adduser.sh tanaka --cpu 400% --mem 8G
```

adduser.sh が行うこと:
- Linux ユーザー作成
- UID からポートを自動割り当て（VS Code: 10000+、Xpra: 14500+）
- `/etc/devbox/users/[username].conf` にポート設定を書き込み
- `devbox@[username].target` を有効化・起動
- nginx ロケーション設定を `/etc/nginx/conf.d/devbox-users/[username].conf` に追加

## systemd 構成

```
devbox@{username}.target
├── vscode@{username}.service   (VS Code serve-web、ポート: 10000 + UID offset)
└── xpra@{username}.service    (ポート: 14500 + UID offset)
```

リソース制限は `/etc/systemd/system/[service].d/resources.conf` のドロップインで管理。

### サービス操作

```bash
# 起動・停止・再起動
systemctl start   devbox@yamada.target
systemctl stop    devbox@yamada.target
systemctl restart vscode@yamada.service

# 状態確認
systemctl status  devbox@yamada.target

# ログ確認
journalctl -u vscode@yamada.service -f
journalctl -u xpra@yamada.service -f
```

## ポート割り当てルール

| UID  | VS Code ポート | Xpra ポート | Xpra ディスプレイ |
|------|---------------|------------|------------------|
| 1000 | 10000         | 14500      | :100             |
| 1001 | 10001         | 14501      | :101             |
| 1002 | 10002         | 14502      | :102             |

## Authentik 設定

1. Authentik 管理画面 → **Providers** → 新規 Proxy Provider  
   - Mode: `Forward auth (single application)`  
   - External Host: `http://devbox.example.com`

2. **Applications** で作成したプロバイダーにアプリを紐付け

3. **Outpost** に Embedded Outpost を割り当て

詳細: https://docs.goauthentik.io/docs/providers/proxy/forward_auth
