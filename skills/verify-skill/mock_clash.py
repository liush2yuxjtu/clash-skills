#!/usr/bin/env python3
"""Tiny mock Clash external-controller API for verify.sh. Logs every request as 'METHOD PATH' to $MOCK_LOG."""
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
SECRET = os.environ.get("MOCK_SECRET", "s3cret")
LOG = os.environ["MOCK_LOG"]
GLOBAL = {"name": "GLOBAL", "type": "Selector", "now": "NodeA",
          "all": ["DIRECT", "REJECT", "NodeA", "NodeB", "剩余流量：10G"]}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj=None):
        b = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode() if obj is not None else b""
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        with open(LOG, "a") as f: f.write("%s %s %s\n" % (self.command, self.path, body))
        if self.headers.get("Authorization") != "Bearer " + SECRET:
            return self._send(401, {"message": "Unauthorized"})
        if self.command == "GET" and self.path == "/proxies/GLOBAL": return self._send(200, GLOBAL)
        if self.command == "GET" and self.path == "/configs": return self._send(200, {"mode": "rule", "mixed-port": 7897})
        if self.command in ("PUT", "PATCH"): return self._send(204)
        self._send(404, {"message": "not found"})
    do_GET = do_PUT = do_PATCH = _handle
srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
