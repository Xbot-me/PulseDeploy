"""Tests for builder.py (scenario generation) and init.py, plus one real run of a generated scenario.

    python3 -m unittest loadtest/tests/test_builder.py
The end-to-end class is skipped when Locust is not installed.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOADTEST = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(LOADTEST))
import builder  # noqa: E402
import humanlib as hl  # noqa: E402
import init as init_cli  # noqa: E402

HAVE_LOCUST = importlib.util.find_spec("locust") is not None

URLS = """\
# comment
# journey: browse the shop
/
/products?page=2

POST /api/cart weight=3
https://staging.example.com/api/health
"""


def har_entry(method, url, status=200, mime="text/html", at="2026-01-01T10:00:00.000Z", body=None, response=None, headers=()):
    entry = {
        "startedDateTime": at,
        "request": {"method": method, "url": url, "headers": [{"name": h, "value": "x"} for h in headers]},
        "response": {"status": status, "content": {"mimeType": mime}},
    }
    if body is not None:
        entry["request"]["postData"] = {"mimeType": "application/json", "text": json.dumps(body)}
    if response is not None:
        entry["response"]["content"]["text"] = json.dumps(response)
    return entry


class FromUrls(unittest.TestCase):
    def test_groups_weights_methods_and_origin(self):
        base, groups = builder.parse_urls(URLS)
        self.assertEqual(base, "https://staging.example.com")
        self.assertEqual([g["name"] for g in groups], ["browse the shop", None])
        self.assertEqual(groups[0]["steps"], [("GET", "/"), ("GET", "/products?page=2")])
        self.assertEqual(groups[1]["weight"], 3.0)
        self.assertEqual(groups[1]["steps"][1], ("GET", "/api/health"))

    def test_scenario_is_valid_and_marks_writes(self):
        scn, notes = builder.from_urls(URLS, "My Shop")
        self.assertEqual(hl.validate_scenario(scn), [])
        self.assertEqual(scn["name"], "my-shop")
        self.assertEqual(scn["target"]["url"], "https://staging.example.com")
        steps = scn["journeys"][1]["steps"]
        self.assertTrue(steps[0]["writes"])
        self.assertEqual(steps[0]["method"], "POST")
        self.assertNotIn("html", steps[1])  # /api/... is not a page
        self.assertTrue(scn["journeys"][0]["steps"][0]["html"])
        self.assertTrue(any("writes" in n for n in notes))

    def test_bad_lines_are_reported(self):
        with self.assertRaises(ValueError) as ctx:
            builder.parse_urls("products\nhttps://a.test/x\nhttps://b.test/y")
        self.assertIn("line 1", str(ctx.exception))
        self.assertIn("different site", str(ctx.exception))
        with self.assertRaises(ValueError):
            builder.parse_urls("# only a comment")

    def test_login_with_token_adds_setup_and_header(self):
        auth = {"type": "login", "path": "/api/login", "user_field": "user", "pass_field": "pw", "token_path": "data.token"}
        scn, _ = builder.from_urls("/api/me", "api", "https://api.example.com", auth, "api")
        self.assertEqual(hl.validate_scenario(scn), [])
        login = scn["setup"][0]
        self.assertEqual(login["json"], {"user": "{username}", "pw": "{password}"})
        self.assertEqual(login["extract"], {"token": "data.token"})
        self.assertEqual(scn["headers"]["app"]["Authorization"], "Bearer {token?}")


class FromHar(unittest.TestCase):
    def har(self):
        site = "https://shop.example.com"
        return {"log": {"entries": [
            har_entry("GET", f"{site}/", at="2026-01-01T10:00:00.000Z"),
            har_entry("GET", f"{site}/app.js", mime="application/javascript", at="2026-01-01T10:00:00.100Z"),
            har_entry("GET", f"{site}/logo.png", mime="image/png", at="2026-01-01T10:00:00.200Z"),
            har_entry("GET", "https://cdn.other.test/lib.js", mime="application/javascript", at="2026-01-01T10:00:00.300Z"),
            har_entry("POST", f"{site}/api/login", mime="application/json", at="2026-01-01T10:00:01.000Z",
                      body={"email": "me@x.test", "password": "hunter2"}, response={"data": {"token": "abc"}}, headers=("Cookie",)),
            har_entry("GET", f"{site}/api/items?limit=5", mime="application/json", at="2026-01-01T10:00:05.000Z", headers=("Authorization",)),
            har_entry("GET", f"{site}/api/gone", status=404, mime="application/json", at="2026-01-01T10:00:06.000Z"),
            har_entry("POST", f"{site}/api/orders", status=201, mime="application/json", at="2026-01-01T10:00:08.000Z",
                      body={"item": 3, "card_number": "4242"}),
            har_entry("GET", f"{site}/orders", at="2026-01-01T10:05:00.000Z"),
        ]}}

    def test_drops_noise_scrubs_credentials_and_splits_visits(self):
        scn, notes = builder.from_har(self.har(), "recorded")
        self.assertEqual(hl.validate_scenario(scn), [])
        self.assertEqual(scn["target"]["url"], "https://shop.example.com")
        text = json.dumps(scn)
        self.assertNotIn("hunter2", text)
        self.assertNotIn("4242", text)
        self.assertNotIn("me@x.test", text)
        paths = [s["path"] for j in scn["journeys"] for s in j["steps"]]
        self.assertEqual(paths, ["/", "/api/items?limit=5", "/api/orders", "/orders"])  # no js, png, other site, login, 404
        self.assertEqual(len(scn["journeys"]), 2)  # a 5 minute pause starts a new visit
        login = scn["setup"][0]
        self.assertEqual(login["json"], {"email": "{username}", "password": "{password}"})
        self.assertEqual(login["extract"], {"token": "data.token"})
        order = scn["journeys"][0]["steps"][2]
        self.assertTrue(order["writes"])
        self.assertEqual(order["expect"], [201])
        self.assertEqual(order["json"], {"item": 3})
        joined = " ".join(notes)
        self.assertIn("other sites", joined)
        self.assertIn("--password-file", joined)
        self.assertIn("card_number", joined)

    def test_recorded_gaps_become_think_times(self):
        scn, _ = builder.from_har(self.har(), "recorded")
        first = scn["journeys"][0]["steps"][0]
        self.assertAlmostEqual(first["think"]["median"], 5.0, delta=0.1)  # "/" at :00, next kept request at :05 (the login is not a step)

    def test_empty_recording(self):
        with self.assertRaises(ValueError):
            builder.from_har({"log": {"entries": []}}, "x")


class InitCli(unittest.TestCase):
    def run_main(self, *args):
        cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as tmp:
            os.chdir(tmp)
            try:
                code = init_cli.main(list(args))
                out = {p.name: p.read_text() for p in Path(tmp).glob("*.json")}
            finally:
                os.chdir(cwd)
        return code, out

    def test_from_urls_file_writes_a_valid_scenario(self):
        with tempfile.TemporaryDirectory() as tmp:
            urls = Path(tmp) / "shop.txt"
            urls.write_text("/\n/pricing\n")
            code, out = self.run_main("--from-urls", str(urls), "--url", "https://x.example.com")
        self.assertEqual(code, 0)
        self.assertIn("shop.json", out)
        self.assertEqual(hl.validate_scenario(json.loads(out["shop.json"])), [])

    def test_wizard_answers(self):
        answers = iter(["https://app.example.com", "", "w", "f", "/login", "", "", "data.token", "/", "/pricing", "", "/account", "."])
        text, name, url, kind, auth = init_cli.wizard(lambda prompt: next(answers))
        self.assertEqual((name, url, kind), ("app-example-com", "https://app.example.com", "w"))
        self.assertEqual(auth, {"type": "login", "path": "/login", "user_field": "email", "pass_field": "password", "token_path": "data.token"})
        scn, _ = builder.from_urls(text, name, url, auth, "web")
        self.assertEqual(hl.validate_scenario(scn), [])
        self.assertEqual([len(j["steps"]) for j in scn["journeys"]], [2, 1])

    def test_refuses_to_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            urls = Path(tmp) / "a.txt"
            urls.write_text("/\n")
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                self.assertEqual(init_cli.main(["--from-urls", str(urls)]), 0)
                self.assertEqual(init_cli.main(["--from-urls", str(urls)]), 1)
                self.assertEqual(init_cli.main(["--from-urls", str(urls), "--force"]), 0)
            finally:
                os.chdir(cwd)


class Site(BaseHTTPRequestHandler):
    """A tiny site: token login, an API that needs the token, and a page."""
    seen = {"total": 0, "unauthorised": 0, "login": 0}

    def log_message(self, *args):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/login":
            Site.seen["login"] += 1
            if body.get("user") == "tester" and body.get("pw") == "s3cret":
                return self.send(200, json.dumps({"data": {"token": "tok-1"}}))
            return self.send(401, "{}")
        self.send(404, "{}")

    def do_GET(self):
        Site.seen["total"] += 1
        if self.path == "/":
            return self.send(200, '<html><link href="/static/a.css" rel="stylesheet"></html>', "text/html")
        if self.path == "/static/a.css":
            return self.send(200, "body{}", "text/css")
        if self.path.startswith("/api/items"):
            if self.headers.get("Authorization") != "Bearer tok-1":
                Site.seen["unauthorised"] += 1
                return self.send(401, "{}")
            return self.send(200, json.dumps({"items": [{"id": 1}, {"id": 2}]}))
        self.send(404, "{}")


@unittest.skipUnless(HAVE_LOCUST, "locust is not installed (pip install -r loadtest/requirements.txt)")
class GeneratedScenarioRuns(unittest.TestCase):
    def test_login_token_and_generic_headers(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Site)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_address[1]
        try:
            auth = {"type": "login", "path": "/api/login", "user_field": "user", "pass_field": "pw", "token_path": "data.token"}
            scn, _ = builder.from_urls("/\n/api/items?limit=2\n", "site", f"http://127.0.0.1:{port}", auth)
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "site.json"
                path.write_text(json.dumps(scn))
                env = dict(os.environ)
                env.update({
                    "LT_SCENARIO": str(path), "LT_PROFILE": "smoke", "LT_SMOKE_SECONDS": "10", "LT_TIME_SCALE": "0.02",
                    "LT_OUT": tmp, "LT_SEED": "t", "LT_PROGRESS": "0", "LT_BASE_APP": f"http://127.0.0.1:{port}",
                    "LT_VAR_USERNAME": "tester", "LT_VAR_PASSWORD": "s3cret", "LT_HEADERS": "X-Env: staging\n",
                })
                proc = subprocess.run([sys.executable, "-m", "locust", "-f", str(LOADTEST / "locustfile.py"), "--headless", "--only-summary"],
                                      env=env, cwd=LOADTEST, capture_output=True, text=True, timeout=120)
                summary = json.loads((Path(tmp) / "summary.json").read_text())
        finally:
            server.shutdown()
        self.assertEqual(proc.returncode, 0, proc.stdout[-1500:] + proc.stderr[-1500:])
        self.assertEqual(summary["problems"], [])
        self.assertGreater(summary["total"], 10)
        self.assertEqual(Site.seen["unauthorised"], 0, "every API call must carry the token from the login")
        self.assertLess(Site.seen["login"], 6, "people share one login")
        self.assertIn("What this means", summary["text"])
        self.assertIn("RESULT: PASS", summary["text"])


if __name__ == "__main__":
    unittest.main()
