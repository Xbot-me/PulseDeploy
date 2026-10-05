"""Tiny HTTP server for the crm.sh smoke-test checks (tests/run.sh). Host header picks the app."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

NAME = sys.argv[2] if len(sys.argv) > 2 else "Acme"
MODE = sys.argv[3] if len(sys.argv) > 3 else "ok"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        host = self.headers.get("Host", "")
        if self.path == "/up":
            return self.send(200, "up", "text/plain")
        if self.path == "/api/v1/storefront/web-info":
            if MODE == "dbdown":
                return self.send(500, '{"message":"SQLSTATE[HY000] [2002]"}')
            return self.send(200, json.dumps({"success": True, "data": {"name": NAME}}))
        if host.startswith("shop."):
            return self.send(200, "<html>" + NAME + "</html>", "text/html")
        return self.send(200, "<html>login</html>", "text/html")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        ok = MODE != "badlogin" and body.get("password") == "pw"
        self.send(200 if ok else 401, "{}")


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
