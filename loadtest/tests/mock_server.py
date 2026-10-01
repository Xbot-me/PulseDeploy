"""A small stand-in for the CRM, for testing the load-test engine without a real server.

It answers like the admin app (pages, login cookie, /api/proxy/...) and the CRM's
API (admin login, products, storefront) and counts what it sees, so tests can check
that virtual users behave like browsers: cookies kept, scripts cached, writes only
when allowed. Host headers choose the app: a host containing "admin" is the admin
app, anything else is the API.

  MOCK_FAIL_RATE     fraction of API calls answered with HTTP 500
  MOCK_MAX_INFLIGHT  answer 500 when more requests than this are in flight (to find a "breakpoint")
  MOCK_LOGIN_LIMIT   logins allowed per rolling minute before HTTP 429
  MOCK_LOGIN_PER_EMAIL  like the CRM's throttle:login: logins allowed per minute for one email
"""
import json
import os
import random
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATS = Counter()
UAS = set()
LOCK = threading.Lock()
LOGINS = []
LOGINS_BY_EMAIL = {}
INFLIGHT = [0]
PAGE = ('<html><head><link rel="stylesheet" href="/_next/static/css/app.css"></head>'
        '<body><script src="/_next/static/chunks/main.js"></script>'
        '<script src="/_next/static/chunks/page.js"></script></body></html>')


def paginated(items, page=1, per=20):
    return {"success": True, "message": "OK", "data": {"current_page": page, "data": items, "per_page": per, "total": len(items), "last_page": 1}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, body, headers=None, ctype="application/json"):
        raw = body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def handle_any(self, method):
        host = self.headers.get("Host", "")
        url = urlparse(self.path)
        path = url.path
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        with LOCK:
            INFLIGHT[0] += 1
            inflight = INFLIGHT[0]
            STATS["total"] += 1
            STATS[f"{method} {path.split('?')[0] if not path.startswith('/api/proxy/orders/') and not path.startswith('/api/proxy/product/') else path.rsplit('/', 1)[0]}"] += 1
            if self.headers.get("X-Load-Test"):
                STATS["marked"] += 1
            UAS.add(self.headers.get("User-Agent", ""))
        try:
            time.sleep(random.uniform(0.003, 0.02))
            if path == "/__stats":
                return self.reply(200, {"stats": dict(STATS), "user_agents": len(UAS)})
            if path.startswith("/_next/static/"):
                with LOCK:
                    STATS["static"] += 1
                return self.reply(200, "x" * 200, ctype="application/javascript")
            fail = float(os.environ.get("MOCK_FAIL_RATE", "0"))
            limit = int(os.environ.get("MOCK_MAX_INFLIGHT", "0"))
            if (fail and random.random() < fail) or (limit and inflight > limit):
                return self.reply(500, {"success": False, "message": "boom"})
            if "admin" in host:
                return self.admin(method, path, url, body)
            return self.api(method, path, url, body)
        finally:
            with LOCK:
                INFLIGHT[0] -= 1

    def authed_cookie(self):
        return "auth_token=" in self.headers.get("Cookie", "")

    def admin(self, method, path, url, body):
        if path == "/api/auth/login" and method == "POST":
            now = time.time()
            with LOCK:
                LOGINS[:] = [t for t in LOGINS if now - t < 60]
                if len(LOGINS) >= int(os.environ.get("MOCK_LOGIN_LIMIT", "30")):
                    STATS["login 429"] += 1
                    return self.reply(429, {"success": False, "message": "slow down"})
                LOGINS.append(now)
            per_email = int(os.environ.get("MOCK_LOGIN_PER_EMAIL", "0"))
            if per_email:
                key = str(body.get("email", "")).lower()
                with LOCK:
                    recent = [t for t in LOGINS_BY_EMAIL.get(key, []) if now - t < 60]
                    if len(recent) >= per_email:
                        LOGINS_BY_EMAIL[key] = recent
                        STATS["login 429 per email"] += 1
                        return self.reply(429, {"success": False, "message": "Too many attempts."})
                    LOGINS_BY_EMAIL[key] = recent + [now]
            if body.get("password") != "secret" or not self.headers.get("X-Store-Subdomain"):
                return self.reply(401, {"success": False, "message": "Invalid credentials."})
            return self.reply(200, {"success": True, "data": {"token": "tok"}}, {"Set-Cookie": "auth_token=tok; Path=/; HttpOnly"})
        if path in ("/login",):
            return self.reply(200, PAGE, ctype="text/html")
        if path in ("/dashboard", "/orders", "/products", "/brands"):
            if not self.authed_cookie():
                STATS["page without cookie"] += 1
                return self.reply(401, "login required", ctype="text/plain")
            return self.reply(200, PAGE, ctype="text/html")
        if path.startswith("/api/proxy/"):
            if not self.authed_cookie() or not self.headers.get("X-Store-Subdomain"):
                STATS["proxy without cookie or tenant"] += 1
                return self.reply(401, {"success": False})
            rest = path[len("/api/proxy/"):]
            if rest == "dashboard":
                return self.reply(200, {"success": True, "data": {"orders": 5}})
            if rest == "orders":
                return self.reply(200, paginated([{"id": i} for i in range(1, 21)]))
            if rest.startswith("orders/"):
                return self.reply(200, {"success": True, "data": {"id": int(rest.split("/")[1])}})
            if rest == "products":
                return self.reply(200, paginated([{"id": i} for i in range(1, 51)]))
            if rest.startswith("product/"):
                return self.reply(200, {"success": True, "data": {"id": int(rest.split("/")[1])}})
            if rest in ("categories", "brands"):
                return self.reply(200, {"success": True, "data": [{"id": 1}]})
        return self.reply(404, {"success": False})

    def api(self, method, path, url, body):
        if not self.headers.get("X-Store-Subdomain"):
            return self.reply(404, {"success": False, "message": "Unknown store."})
        if path == "/api/v1/admin/login" and method == "POST":
            if body.get("password") != "secret":
                return self.reply(401, {"success": False})
            return self.reply(200, {"success": True, "data": {"token": "tok"}})
        if path == "/api/v1/admin/products":
            if self.headers.get("Authorization") != "Bearer tok":
                return self.reply(401, {"success": False})
            return self.reply(200, paginated([{"id": i} for i in range(1, 51)]))
        if path.startswith("/api/v1/storefront/cart"):
            if method == "POST":
                STATS["cart writes"] += 1
                return self.reply(200, {"success": True})
            headers = {} if self.headers.get("X-Cart-Session") else {"X-Cart-Session": "sess-%d" % random.randint(1, 10**9)}
            return self.reply(200, {"success": True, "data": {"items": []}}, headers)
        if path.startswith("/api/v1/storefront/"):
            return self.reply(200, {"success": True, "data": []})
        return self.reply(404, {"success": False})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


def serve(port=0):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


if __name__ == "__main__":
    s = serve(int(os.environ.get("PORT", "8099")))
    print("mock CRM on", s.server_address, flush=True)
    threading.Event().wait()
