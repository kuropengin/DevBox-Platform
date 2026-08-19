#!/usr/bin/env bash
# DevBox Platform - backend サーバー インストールスクリプト (RHEL 9 系)
# 対応: AlmaLinux 9 / Rocky Linux 9 / RHEL 9
# 使い方: FRONT_ALLOWED_SOURCE=<frontのIP/CIDR> sudo -E bash install-backend.sh
#
# backend サーバーの役割: ユーザーごとの実体（vscode@/xpra@ systemd サービス）
# と、それが使う開発ツール一式（Java/Tomcat/VS Code拡張機能/Claude Code CLI）。
# 認証・ポータル配信は行わない（front サーバー / install-front.sh の役割）。
# ローカル nginx はポート 80 で待ち受け、front からのプロキシのみを
# 受け付ける（firewalld で送信元 IP を制限する）。
#
# backend は何台でも増設できる。1台構成にしたい場合は、このスクリプトと
# install-front.sh を同一ホストで実行すればよい（FRONT_ALLOWED_SOURCE=127.0.0.1）。
#
# 環境変数:
#   FRONT_ALLOWED_SOURCE   必須。front サーバーの IP または CIDR
#                          （例: 10.0.1.5 / 10.0.1.0/24 / 127.0.0.1）。
#                          未設定の場合、backend の 80 番ポートは
#                          firewalld で一切開放されない（安全側デフォルト）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
DEVBOX_BACKEND_PORT=80

# shellcheck source=../lib-common.sh
source "${SCRIPT_DIR}/../lib-common.sh"
# shellcheck source=lib-vscode-extensions.sh
source "${SCRIPT_DIR}/lib-vscode-extensions.sh"
# shellcheck source=lib-tomcat.sh
source "${SCRIPT_DIR}/lib-tomcat.sh"

# .env ファイルが存在すれば読み込む（環境変数を上書き）
for env_path in "${REPO_DIR}/install-backend.env" "${SCRIPT_DIR}/install-backend.env" "/etc/devbox/install-backend.env"; do
  if [[ -f "$env_path" ]]; then
    info ".env を読み込み中: ${env_path}"
    set -a
    # shellcheck disable=SC1090
    source "$env_path"
    set +a
    break
  fi
done

# ──────────────────────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && die "rootで実行してください: sudo -E bash install-backend.sh"

if ! grep -qiE 'rhel|almalinux|rocky' /etc/os-release 2>/dev/null; then
  warn "RHEL 9 系以外の環境です。続行しますが動作を保証しません"
fi
MAJOR_VER=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
[[ "$MAJOR_VER" -lt 9 ]] && die "RHEL 9 以上が必要です (検出: ${MAJOR_VER})"

echo ""
echo "╔══════════════════════════════════╗"
echo "║   DevBox Platform - backend      ║"
echo "║   RHEL 9 系                      ║"
echo "╚══════════════════════════════════╝"
echo ""

# ─── 1. EPEL + 基本パッケージ ─────────────────────────────────────────────────
info "EPEL リポジトリと基本パッケージをインストール中..."
dnf install -y epel-release
dnf install -y curl git python3 rsync tar

dnf config-manager --set-enabled crb 2>/dev/null || \
  dnf config-manager --set-enabled powertools 2>/dev/null || \
  warn "CRB/PowerTools の有効化に失敗しました（続行します）"
ok "基本パッケージ完了"

# ─── 2. VS Code（code serve-web） ─────────────────────────────────────────────
if ! command -v code &>/dev/null; then
  info "VS Code をインストール中..."
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  cat > /etc/yum.repos.d/vscode.repo << 'REPO_EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO_EOF
  dnf install -y code
  ok "VS Code インストール完了: $(code --version 2>&1 | head -1)"
else
  ok "VS Code は導入済み: $(code --version 2>&1 | head -1)"
fi

# ─── 3. Java（Eclipse Temurin） ───────────────────────────────────────────────
# 8（レガシーアプリ向け）と 25（最新 LTS）を並行してインストールする。
# パッケージ名がバージョンごとに分かれている（temurin-N-jdk）ため、
# update-alternatives 経由で共存でき、通常の dnf update で追随できる。
if [[ ! -f /etc/yum.repos.d/adoptium.repo ]]; then
  rpm --import https://packages.adoptium.net/artifactory/api/gpg/key/public

  # Adoptium は AlmaLinux/Rocky 向けの専用リポジトリを提供していないため、
  # RHEL 系はすべて "rhel" のリポジトリパスを利用する。
  cat > /etc/yum.repos.d/adoptium.repo << 'REPO_EOF'
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/rhel/$releasever/$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
REPO_EOF
fi

for jdk_version in 8 25; do
  if rpm -q "temurin-${jdk_version}-jdk" &>/dev/null; then
    ok "Java ${jdk_version}（Temurin）は導入済み"
  else
    info "Java ${jdk_version}（Temurin）をインストール中..."
    dnf install -y "temurin-${jdk_version}-jdk"
    ok "Java ${jdk_version} インストール完了"
  fi
done

# ─── 4. Apache Tomcat（9 / 11） ────────────────────────────────────────────────
# Tomcat は公式の dnf/yum リポジトリが無い（EPEL の "tomcat" は9系1つのみで
# 複数メジャーバージョンを並存させられない）ため、archive.apache.org の
# 公式 tarball を取得して /opt/devbox/tomcat/tomcat{9,11} に展開する。
# 詳細は scripts/backend/lib-tomcat.sh を参照。
info "Apache Tomcat（9 / 11）をインストール中..."
if tomcat_install_all 9 11; then
  ok "Apache Tomcat インストール完了 → ${TOMCAT_BASE_DIR}"
else
  warn "Apache Tomcat の一部バージョンのインストールに失敗しました（続行します）"
fi

# ─── 5. Claude Code CLI ────────────────────────────────────────────────────────
# システム全体に一度だけインストールする（dnf パッケージ、ユーザーごとの
# 個別インストールは不要）。VS Code の Claude 拡張機能はこの CLI を起動する
# ように adduser-backend.sh がユーザーごとに設定する
# （claudeCode.claudeProcessWrapper）。CLI 自体の設定・セッション状態は
# $HOME/.claude/ に保存されるため、バイナリを共有していてもユーザー間で
# 干渉しない。
if ! command -v claude &>/dev/null; then
  info "Claude Code CLI をインストール中..."
  cat > /etc/yum.repos.d/claude-code.repo << 'REPO_EOF'
[claude-code]
name=Claude Code
baseurl=https://downloads.claude.ai/claude-code/rpm/stable
enabled=1
gpgcheck=1
gpgkey=https://downloads.claude.ai/keys/claude-code.asc
REPO_EOF
  dnf install -y claude-code
  ok "Claude Code CLI インストール完了: $(claude --version 2>&1 | head -1)"
else
  ok "Claude Code CLI は導入済み: $(claude --version 2>&1 | head -1)"
fi

# ─── 6. VS Code 拡張機能（マスターセットを root が管理） ─────────────────────
# ここでは root 専用のマスターディレクトリに拡張機能をインストールするだけで、
# 実際の配布は adduser-backend.sh（新規ユーザー作成時）と
# update-extensions.sh（既存ユーザーへの更新反映）が行う。各ユーザーには
# 独立したコピーを配布し、本人には読み取り専用の権限しか与えないため、
#   - ユーザー間で拡張機能ディレクトリを共有しない（同時書き込みによる
#     extensions.json 破損などの干渉が起きない）
#   - 追加インストール・アンインストールは root（本スクリプト経由）以外
#     には行えない
# という2点を両立する。
info "VS Code 拡張機能（マスターセット）を準備中..."
vscode_ext_build_master
vscode_ext_sync_to_all_users
ok "VS Code 拡張機能マスターセット準備完了 → ${VSCODE_EXT_MASTER_DIR}"

# ─── 7. Xpra + xpra-html5 ─────────────────────────────────────────────────────
if ! command -v xpra &>/dev/null; then
  info "Xpra をインストール中..."
  dnf install -y xpra xorg-x11-server-Xvfb xauth xorg-x11-utils \
    dejavu-sans-fonts dbus-x11 xterm

  info "xpra-html5 をソースからインストール中..."
  git clone --depth=1 https://github.com/Xpra-org/xpra-html5 /tmp/xpra-html5
  cd /tmp/xpra-html5 && python3 ./setup.py install
  cd / && rm -rf /tmp/xpra-html5
  ok "Xpra インストール完了: $(xpra --version 2>&1 | head -1)"
else
  ok "Xpra は導入済み: $(xpra --version 2>&1 | head -1)"
fi

# ─── 8. XFCE デスクトップ ─────────────────────────────────────────────────────
if ! command -v xfce4-session &>/dev/null; then
  info "XFCE をインストール中..."
  dnf install -y xfce4-session xfce4-terminal xfwm4 xfdesktop xfce4-panel Thunar
  ok "XFCE インストール完了"
else
  ok "XFCE は導入済み"
fi

# ─── 9. nginx（ローカル用途、TLSなし） ────────────────────────────────────────
if ! command -v nginx &>/dev/null; then
  info "nginx をインストール中..."
  dnf install -y nginx
fi
systemctl enable nginx
ok "nginx 準備完了: $(nginx -v 2>&1)"

# ─── 10. SELinux — nginx のプロキシ通信を許可 ─────────────────────────────────
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
  info "SELinux ポリシーを設定中..."
  setsebool -P httpd_can_network_connect 1 || warn "setsebool に失敗しました（続行します）"
  ok "SELinux: httpd_can_network_connect 有効"
fi

# ─── 11. firewalld — front からのみ内部ポートを開放 ───────────────────────────
# backend の nginx はそれ自体では認証を行わない（front で認証済みの通信のみを
# 受け付ける前提）ため、この内部ポートを front 以外に公開しないことが安全上
# 必須。firewalld が動いていない/検出できない環境では、この防御が丸ごと
# 機能しなくなるため、その場合は明確に警告して管理者に代替手段
# （セキュリティグループ等）の設定を促す。
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if [[ -n "${FRONT_ALLOWED_SOURCE:-}" ]]; then
    info "firewalld で ${DEVBOX_BACKEND_PORT} 番を ${FRONT_ALLOWED_SOURCE} のみへ開放中..."
    firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"${FRONT_ALLOWED_SOURCE}\" port protocol=\"tcp\" port=\"${DEVBOX_BACKEND_PORT}\" accept"
    firewall-cmd --reload
    ok "firewalld 設定完了（許可元: ${FRONT_ALLOWED_SOURCE}）"
  else
    warn "FRONT_ALLOWED_SOURCE が未設定のため、${DEVBOX_BACKEND_PORT} 番ポートは firewalld で開放しません"
    warn "  front サーバーからの接続を許可するには、後で以下を実行してください:"
    warn "  firewall-cmd --permanent --zone=public --add-rich-rule='rule family=\"ipv4\" source address=\"<frontのIP>\" port protocol=\"tcp\" port=\"${DEVBOX_BACKEND_PORT}\" accept'"
    warn "  firewall-cmd --reload"
  fi
else
  warn "★★★ firewalld が有効になっていません ★★★"
  warn "  ${DEVBOX_BACKEND_PORT} 番ポートへのアクセス元をこのホストのファイア"
  warn "  ウォールで制限できていません。DEVBOX_INTERNAL_TOKEN による認証は"
  warn "  引き続き有効ですが、front 以外からの到達を防ぐネットワーク制御"
  warn "  （クラウドのセキュリティグループ等）を必ず別途設定してください。"
fi

# ─── 12. ディレクトリ作成 ──────────────────────────────────────────────────────
info "ディレクトリを作成中..."
mkdir -p /etc/devbox/users /etc/nginx/conf.d/devbox-backend-users
ok "ディレクトリ作成完了"

# ─── 13. systemd テンプレートユニット ────────────────────────────────────────
info "systemd ユニットをインストール中..."
for unit in devbox@.target vscode@.service xpra@.service; do
  cp "${REPO_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload
ok "systemd ユニットインストール完了"

# ─── 14. backend プラットフォーム設定を保存（adduser-backend.sh が参照） ─────
# front の platform.conf に相当する、backend 側の永続設定。Headroom
# （front側のLLMプロキシ）関連の値をここに保存し、adduser-backend.sh が
# ユーザー作成のたびに読み込む。値が空でも install-backend.sh 自体は
# 失敗させない（Headroom未設定のままユーザー作成しようとした場合は
# adduser-backend.sh 側で warn するに留める）。
cat > /etc/devbox/backend-platform.conf << BACKEND_PLATFORM_EOF
HEADROOM_BASE_URL=${HEADROOM_BASE_URL:-}
DEVBOX_HEADROOM_TOKEN=${DEVBOX_HEADROOM_TOKEN:-}
BACKEND_PLATFORM_EOF
chmod 600 /etc/devbox/backend-platform.conf
if [[ -z "${HEADROOM_BASE_URL:-}" || -z "${DEVBOX_HEADROOM_TOKEN:-}" ]]; then
  warn "HEADROOM_BASE_URL/DEVBOX_HEADROOM_TOKEN が未設定です。設定するまで"
  warn "  このbackendで作成したユーザーは Claude Code を使えません"
fi

# ─── 15. nginx メイン設定（ローカル用途、平文 HTTP、共有シークレットで認証） ──
# backend の 80 番ポートは firewalld による送信元 IP 制限だけに頼らず、
# front が付与する共有シークレット（X-Devbox-Token ヘッダ）も必須にする。
# firewalld が無効/誤設定の環境でも、このヘッダが無い・一致しない直接
# アクセスは 403 で拒否される（多層防御）。DEVBOX_INTERNAL_TOKEN は
# install-front.sh が生成し、管理者が install-backend.env 経由で
# 各 backend に配布する。
[[ -z "${DEVBOX_INTERNAL_TOKEN:-}" ]] && die "DEVBOX_INTERNAL_TOKEN が未設定です。front の /etc/devbox/platform.conf に記録された値を install-backend.env の DEVBOX_INTERNAL_TOKEN に設定してください"

info "nginx を設定中..."
cat > /etc/nginx/conf.d/devbox-backend.conf << NGINX_EOF
# DevBox Platform - backend ローカル設定（install-backend.sh が生成）
# front サーバーからのプロキシのみを受け付ける（firewalld で送信元 IP を
# 制限した上、X-Devbox-Token 共有シークレットも必須にする多層防御）。
# 認証（ログイン）自体は front 側で完結済みのため、ここでは行わない。
# このファイルはシークレットを平文で含むため root のみ読み取り可能にする
# （install-backend.sh が chmod 640 root:root を設定する）。
server {
    listen ${DEVBOX_BACKEND_PORT};
    server_name _;

    if (\$http_x_devbox_token != "${DEVBOX_INTERNAL_TOKEN}") {
        return 403;
    }

    location = / {
        return 200 "DevBox Backend\n";
        add_header Content-Type text/plain;
    }

    include /etc/nginx/conf.d/devbox-backend-users/*.conf;
}
NGINX_EOF
chown root:root /etc/nginx/conf.d/devbox-backend.conf
chmod 640 /etc/nginx/conf.d/devbox-backend.conf

nginx -t && systemctl start nginx && ok "nginx 設定完了" || die "nginx 設定に失敗しました"

# ─── 完了 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  backend インストール完了！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "次のステップ:"
echo "  1. このサーバーでユーザーを作成:"
echo "     sudo bash scripts/backend/adduser-backend.sh <username> <email>"
echo "  2. front サーバーで登録:"
echo "     sudo bash scripts/front/register-user.sh <username> --backend <このサーバーのIP>"
echo ""
echo "  内部ポート: ${DEVBOX_BACKEND_PORT}（front サーバーからのみ到達可能にすること）"
echo ""
