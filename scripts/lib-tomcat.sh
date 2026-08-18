#!/usr/bin/env bash
# DevBox Platform - Apache Tomcat（tarball）の共通処理
# install.sh / update-tomcat.sh / update-all.sh から source して使う。
#
# Apache Tomcat は公式の dnf/yum リポジトリを提供しておらず、RHEL 9 系の
# EPEL にも "tomcat"（9.0系）が1つあるだけでメジャーバージョンを並存
# させる仕組みが無い。そのため archive.apache.org の公式 tarball を
# バージョンごとに取得し、
#
#   /opt/devbox/tomcat/releases/<major>/apache-tomcat-<version>/  実体
#   /opt/devbox/tomcat/tomcat<major>                              現行版へのシンボリックリンク（CATALINA_HOME）
#
# という構成で並存させる。各ユーザーは CATALINA_HOME はこの共有ディレクトリ
# を参照しつつ、自分の CATALINA_BASE（作業ディレクトリ）を自分のホーム配下に
# 用意することで、実行状態（ログ・webapps・work 等）を分離できる
# （Tomcat 標準の複数インスタンス構成: https://tomcat.apache.org/tomcat-9.0-doc/RUNNING.txt）。

: "${TOMCAT_BASE_DIR:=/opt/devbox/tomcat}"

# 指定したメジャーバージョン系列の最新パッチバージョンを archive.apache.org
# のディレクトリ一覧から調べる（例: 9 → "9.0.98"）
_tomcat_latest_version() {
  local major="$1"
  local listing
  listing="$(curl -fsSL "https://archive.apache.org/dist/tomcat/tomcat-${major}/" 2>/dev/null)" || true
  echo "$listing" \
    | grep -oE "v${major}\.[0-9]+\.[0-9]+/" \
    | sed -E 's#^v|/$##g' \
    | sort -V | tail -1
}

# 指定バージョンの tarball をダウンロード・SHA-512 検証して展開し、
# シンボリックリンクを切り替える。既に最新版が導入済みならスキップする。
# 引数: $1 = メジャーバージョン（例: 9, 11）
tomcat_install_or_update() {
  local major="$1"
  local version link_path release_root release_dir

  mkdir -p "$TOMCAT_BASE_DIR"

  version="$(_tomcat_latest_version "$major")"
  if [[ -z "$version" ]]; then
    echo "Tomcat ${major} の最新バージョン取得に失敗しました（archive.apache.org に到達できない可能性があります）" >&2
    return 1
  fi

  link_path="${TOMCAT_BASE_DIR}/tomcat${major}"
  release_root="${TOMCAT_BASE_DIR}/releases/${major}"
  release_dir="${release_root}/apache-tomcat-${version}"

  if [[ -L "$link_path" && "$(readlink -f "$link_path")" == "$release_dir" ]]; then
    echo "Tomcat ${major} は最新（${version}）です"
    return 0
  fi

  echo "Tomcat ${major} を ${version} に更新中..."

  local tmp_dir tarball tar_url sha_url expected actual
  tmp_dir="$(mktemp -d)"
  tarball="${tmp_dir}/apache-tomcat-${version}.tar.gz"
  tar_url="https://archive.apache.org/dist/tomcat/tomcat-${major}/v${version}/bin/apache-tomcat-${version}.tar.gz"
  sha_url="${tar_url}.sha512"

  if ! curl -fsSL -o "$tarball" "$tar_url"; then
    echo "ダウンロードに失敗しました: Tomcat ${major} ${version} (${tar_url})" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  expected="$(curl -fsSL "$sha_url" 2>/dev/null | grep -oE '[A-Fa-f0-9]{128}' | head -1 | tr '[:upper:]' '[:lower:]')" || true
  actual="$(sha512sum "$tarball" | awk '{print $1}')"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "チェックサム検証に失敗しました: Tomcat ${major} ${version}" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  mkdir -p "$release_root"
  tar xzf "$tarball" -C "$release_root"
  rm -rf "$tmp_dir"

  chown -R root:root "$release_dir"
  # 公式 tarball は conf/ が 700、スクリプトが 750 など「他ユーザーは
  # 一切アクセス不可」な権限で固められているため、共有ランタイムとして
  # 全ユーザーが読み取り・実行できるように a+rX で緩め、go-w で
  # 書き込みは root 以外禁止のままにする。
  chmod -R a+rX,go-w "$release_dir"

  local previous_target=""
  [[ -L "$link_path" ]] && previous_target="$(readlink -f "$link_path")"

  ln -sfn "$release_dir" "$link_path"
  echo "Tomcat ${major} → ${version}（${link_path}）"

  # 旧バージョンは容量節約のため削除する。ロールバックしたい場合は
  # 削除前に releases/<major> 配下を退避してから再実行してください。
  if [[ -n "$previous_target" && "$previous_target" != "$release_dir" && -d "$previous_target" ]]; then
    rm -rf "$previous_target"
  fi
}

# 複数のメジャーバージョンをまとめてインストール/更新する
# 引数: 可変長のメジャーバージョン一覧（例: 9 11）。失敗したバージョンが
#       あっても他のバージョンの処理は続行する。
tomcat_install_all() {
  local major failed=0
  for major in "$@"; do
    tomcat_install_or_update "$major" || failed=1
  done
  return "$failed"
}
