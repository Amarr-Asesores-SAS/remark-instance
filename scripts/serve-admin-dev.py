#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# serve-admin-dev.py — prueba LOCAL del panel admin/ sin nginx.
#
# Sirve admin/ en http://127.0.0.1:8099/admin/ y hace de reverse proxy de
# todo lo demas (/api/v1/*, /auth/*, avatares...) hacia el contenedor
# Remark42 en 127.0.0.1:9081. Mismo origin => las llamadas del panel funcionan.
#
# NO reproduce el basic-auth de nginx: las llamadas a /api/v1/admin/* van sin
# credencial, asi que el panel pedira ADMIN_PASSWD por prompt en la 1a accion.
#
# Uso:
#   ./scripts/serve-admin-dev.py            # puerto 8099, upstream 9081
#   PORT=9000 UPSTREAM=127.0.0.1:9081 ./scripts/serve-admin-dev.py
# Luego abrir:  http://127.0.0.1:8099/admin/
# ---------------------------------------------------------------------------
import os
import http.server
import http.client
import urllib.parse

PORT = int(os.environ.get("PORT", "8099"))
UPSTREAM = os.environ.get("UPSTREAM", "127.0.0.1:9081")
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ADMIN_DIR = os.path.join(ROOT, "admin")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _serve_static(self, path):
        rel = path[len("/admin/"):] or "index.html"
        rel = urllib.parse.unquote(rel.split("?", 1)[0])
        full = os.path.normpath(os.path.join(ADMIN_DIR, rel))
        if not full.startswith(os.path.abspath(ADMIN_DIR)) or not os.path.isfile(full):
            full = os.path.join(ADMIN_DIR, "index.html")
        with open(full, "rb") as f:
            body = f.read()
        ctype = "text/html; charset=utf-8" if full.endswith(".html") else "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _proxy(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        payload = self.rfile.read(length) if length else None
        conn = http.client.HTTPConnection(UPSTREAM, timeout=60)
        headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}
        conn.request(self.command, self.path, body=payload, headers=headers)
        r = conn.getresponse()
        data = r.read()
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() in ("transfer-encoding", "connection", "content-length"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        conn.close()

    def _route(self):
        if self.path == "/admin" or self.path == "/":
            self.send_response(302)
            self.send_header("Location", "/admin/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path.startswith("/admin/"):
            return self._serve_static(self.path)
        return self._proxy()

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = lambda self: self._route()

    def log_message(self, fmt, *args):
        print("  %s %s" % (self.command, self.path))


if __name__ == "__main__":
    print("panel:    http://127.0.0.1:%d/admin/" % PORT)
    print("upstream: http://%s" % UPSTREAM)
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
