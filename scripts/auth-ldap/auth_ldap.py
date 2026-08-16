#!/usr/bin/env python3
# DevBox Platform - nginx auth_request 用 LDAP (LLDAP) Basic 認証ブリッジ
# Python 標準ライブラリのみで動作（ビルド・pip 不要）。
# openldap-clients の ldapwhoami で LDAP bind を行い、成否だけを HTTP ステータスで返す。
#
# 環境変数:
#   LDAP_URL       例: ldap://127.0.0.1:3890
#   LDAP_BASE_DN   例: dc=devbox,dc=local
#   LISTEN_HOST    デフォルト: 127.0.0.1
#   LISTEN_PORT    デフォルト: 9091

import base64
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LDAP_URL = os.environ.get("LDAP_URL", "ldap://127.0.0.1:3890")
LDAP_BASE_DN = os.environ.get("LDAP_BASE_DN", "dc=devbox,dc=local")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9091"))

# nginx location の auth_request 経由でのみ呼ばれる想定。DN に埋め込むため、
# ユーザー名は adduser.sh と同じ許可文字集合に限定して LDAP インジェクションを防ぐ。
USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path != "/verify":
            self.send_response(404)
            self.end_headers()
            return

        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic "):
            self._deny()
            return

        try:
            decoded = base64.b64decode(auth[6:]).decode("utf-8")
            username, password = decoded.split(":", 1)
        except Exception:
            self._deny()
            return

        if not USERNAME_RE.match(username) or not password:
            self._deny()
            return

        dn = f"uid={username},ou=people,{LDAP_BASE_DN}"
        try:
            proc = subprocess.run(
                ["ldapwhoami", "-x", "-H", LDAP_URL, "-D", dn, "-y", "/dev/stdin"],
                input=password.encode("utf-8"),
                capture_output=True,
                timeout=5,
            )
        except Exception:
            self._deny()
            return

        if proc.returncode == 0:
            self.send_response(200)
            self.send_header("X-Auth-User", username)
            self.end_headers()
        else:
            self._deny()

    def _deny(self):
        self.send_response(401)
        self.end_headers()


if __name__ == "__main__":
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()
