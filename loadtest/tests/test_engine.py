"""End-to-end tests: real Locust against the mock CRM (skipped when Locust is not installed).

    python3 -m unittest loadtest/tests/test_engine.py            (two quick runs)
    LT_SLOW_TESTS=1 python3 -m unittest loadtest/tests/test_engine.py   (adds writes, breakpoint, rate limits)

Human pauses are shortened 50x (LT_TIME_SCALE) so a few seconds behave like minutes.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOADTEST = HERE.parent
sys.path.insert(0, str(HERE))
HAVE_LOCUST = importlib.util.find_spec("locust") is not None
SLOW = os.environ.get("LT_SLOW_TESTS") == "1"

if HAVE_LOCUST:
    import mock_server

    SERVER = mock_server.serve(0)
    PORT = SERVER.server_address[1]


def run_engine(scenario, profile_env, mock_env=None, expect_exit=None):
    """Run locustfile.py headless; returns (exit code, summary dict or None, mock stats)."""
    mock_server.STATS.clear()
    mock_server.UAS.clear()
    mock_server.LOGINS.clear()
    saved = {k: os.environ.get(k) for k in (mock_env or {})}
    os.environ.update(mock_env or {})
    out = tempfile.mkdtemp(prefix="lt-test-")
    env = dict(os.environ)
    env.update({
        "LT_SCENARIO": scenario, "LT_TIME_SCALE": "0.02", "LT_OUT": out, "LT_SEED": "test",
        "LT_BASE_ADMIN": f"http://127.0.0.1:{PORT}", "LT_HOSTHDR_ADMIN": "admin.crm.test",
        "LT_BASE_API": f"http://127.0.0.1:{PORT}", "LT_HOSTHDR_API": "api.crm.test",
        "LT_VAR_STORE": "main", "LT_VAR_EMAIL": "admin@crm.test", "LT_VAR_PASSWORD": "secret", "LT_PROGRESS": "0",
    })
    env.update(profile_env)
    try:
        proc = subprocess.run([sys.executable, "-m", "locust", "-f", str(LOADTEST / "locustfile.py"), "--headless", "--only-summary"],
                              env=env, cwd=LOADTEST, capture_output=True, text=True, timeout=180)
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    summary_file = Path(out) / "summary.json"
    summary = json.loads(summary_file.read_text()) if summary_file.exists() else None
    return proc, summary, dict(mock_server.STATS)


SMOKE = {"LT_PROFILE": "smoke", "LT_SMOKE_SECONDS": "12"}


@unittest.skipUnless(HAVE_LOCUST, "locust is not installed (pip install -r loadtest/requirements.txt)")
class Engine(unittest.TestCase):
    def test_admin_visit_behaves_like_browsers_and_passes(self):
        proc, summary, seen = run_engine("aventech-admin", SMOKE)
        self.assertEqual(proc.returncode, 0, proc.stdout[-1500:] + proc.stderr[-1500:])
        self.assertEqual(summary["problems"], [])
        self.assertGreater(summary["total"], 80)
        self.assertEqual(summary["failed"], 0)
        # cookies from the login reach every page and API call
        self.assertEqual(seen.get("page without cookie", 0), 0)
        self.assertEqual(seen.get("proxy without cookie or tenant", 0), 0)
        # scripts and styles are fetched on a first visit only, not on every page
        pages = sum(v for k, v in seen.items() if k in ("GET /dashboard", "GET /orders", "GET /products", "GET /brands", "GET /login"))
        self.assertGreater(seen["static"], 0)
        self.assertLess(seen["static"], pages * 3 * 0.8)
        # requests are marked, and come from several browser identities
        self.assertGreaterEqual(seen["marked"], seen["total"] - 2)
        self.assertGreaterEqual(len(mock_server.UAS), 2)
        # the report contains the human-readable verdict last
        self.assertIn("RESULT: PASS", proc.stdout)
        self.assertTrue(proc.stdout.rstrip().endswith("RESULT: PASS"))

    def test_a_failing_server_fails_the_run_with_exit_code_1(self):
        proc, summary, _ = run_engine("aventech-admin", SMOKE, {"MOCK_FAIL_RATE": "0.4"})
        self.assertEqual(proc.returncode, 1)
        self.assertTrue(any("failed" in p for p in summary["problems"]), summary["problems"])
        self.assertIn("RESULT: FAIL", proc.stdout)

    def test_a_missing_base_url_stops_before_any_traffic(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("LT_")}
        env["LT_SCENARIO"] = "aventech-admin"
        proc = subprocess.run([sys.executable, "-m", "locust", "-f", str(LOADTEST / "locustfile.py"), "--headless"],
                              env=env, cwd=LOADTEST, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("give its address with --base admin=URL", proc.stdout + proc.stderr)


@unittest.skipUnless(HAVE_LOCUST and SLOW, "slow engine tests: set LT_SLOW_TESTS=1")
class EngineSlow(unittest.TestCase):
    STORE = {"LT_PROFILE": "smoke", "LT_SMOKE_SECONDS": "12"}

    def test_writes_are_off_by_default_and_on_when_asked(self):
        _, summary, seen = run_engine("aventech-storefront", self.STORE)
        self.assertEqual(seen.get("cart writes", 0), 0)
        self.assertFalse(any(e["name"].startswith("cart:") for e in summary["endpoints"]))
        _, summary, seen = run_engine("aventech-storefront", dict(self.STORE, LT_WRITES="1"))
        self.assertGreater(seen.get("cart writes", 0), 0)
        self.assertEqual(summary["problems"], [])

    def test_rate_limited_logins_are_retried_and_do_not_fail_the_run(self):
        proc, summary, seen = run_engine("aventech-admin", {"LT_PROFILE": "smoke", "LT_SMOKE_SECONDS": "15"}, {"MOCK_LOGIN_LIMIT": "2"})
        self.assertGreater(seen.get("login 429", 0), 0)
        self.assertEqual(proc.returncode, 0, proc.stdout[-800:])
        self.assertEqual(summary["problems"], [])

    def test_breakpoint_profile_stops_where_the_server_breaks(self):
        proc, summary, _ = run_engine(
            "aventech-admin",
            {"LT_PROFILE": "breakpoint", "LT_USERS": "2", "LT_STEP_USERS": "4", "LT_STEP_SECONDS": "10",
             "LT_MAX_USERS": "60", "LT_SPAWN": "2", "LT_TIME_SCALE": "0.01"},
            {"MOCK_MAX_INFLIGHT": "6"})
        self.assertIsNotNone(summary["breakpoint_users"], proc.stdout[-1500:])
        self.assertIn("BREAKPOINT", proc.stdout)


if __name__ == "__main__":
    unittest.main()
