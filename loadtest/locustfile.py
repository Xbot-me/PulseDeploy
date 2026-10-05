"""Human-like load for a PulseDeploy server, driven by scenario files.

Do not run this directly; use loadtest/run.sh, which sets the environment this
file reads (LT_*) and asks for confirmation before generating any load.

How a virtual user behaves (see the README, "Load testing and benchmarks"):
  setup      logs in once (a human does not log in on every click)
  a visit    a few "journeys" picked by weight, with human pauses between steps
  drop-off   after a step a person may leave (step "continue_p")
  gap        then the visitor is gone for a while, and a new person arrives
  browser    a new visitor downloads the page's scripts/styles once; returning
             visitors already have them (not fetched again)
"""
import json
import os
import random
import sys
import time
from itertools import count
from pathlib import Path

import gevent
from gevent.lock import Semaphore
from locust import HttpUser, LoadTestShape, constant, events, task

sys.path.insert(0, str(Path(__file__).resolve().parent))
import humanlib as hl  # noqa: E402

HERE = Path(__file__).resolve().parent


def env(name, default=None):
    value = os.environ.get(name)
    return default if value in (None, "") else value


def env_num(name, default):
    try:
        return float(env(name, default))
    except ValueError:
        sys.exit(f"{name} must be a number")


SEED = env("LT_SEED", str(int(time.time())))
WRITES = env("LT_WRITES", "0") == "1"
MARK = env("LT_MARK", "1") == "1"
RUN_ID = env("LT_RUN_ID", time.strftime("%Y%m%d-%H%M%S"))
MAX_FAIL = env_num("LT_MAX_FAIL", 0.01)  # fraction of failed requests allowed
P95_MS = env_num("LT_P95_MS", 1500)  # slowest acceptable p95 of any endpoint
TIME_SCALE = env_num("LT_TIME_SCALE", 1.0)  # <1 shortens every human pause (tests, or a harsher "fast clicker" run)
BASES = {k[8:].lower(): v.rstrip("/") for k, v in os.environ.items() if k.startswith("LT_BASE_") and v}
HOST_HEADERS = {k[11:].lower(): v for k, v in os.environ.items() if k.startswith("LT_HOSTHDR_") and v}
RUN_VARS = {k[7:].lower(): v for k, v in os.environ.items() if k.startswith("LT_VAR_") and v}

SHARE_LOGIN = env("LT_SHARE_LOGIN", "1") == "1"  # people on one account log in once and share the session


def load_accounts():
    path = env("LT_ACCOUNTS_FILE")
    if not path:
        return []
    try:
        return hl.parse_accounts(Path(path).read_text(encoding="utf-8"))
    except (OSError, hl.ScenarioError) as exc:
        sys.exit(f"LT_ACCOUNTS_FILE: {exc}")


ACCOUNTS = load_accounts()  # one account per virtual person (cycled) instead of a shared one
_ACCOUNT_INDEX = count()
_SHARED_LOGIN = {"lock": Semaphore(), "state": {}}

SHARED = {}  # lists discovered once per run, for {any:name}
_DISCOVERY = {"lock": Semaphore(), "done": set()}
_USER_INDEX = count(1)


# ── scenarios ─────────────────────────────────────────────────────────────────
def load_scenarios():
    chosen = []
    for item in env("LT_SCENARIO", "aventech-admin:1").split(","):
        name, _, weight = item.strip().partition(":")
        path = Path(name) if Path(name).exists() else HERE / "scenarios" / f"{name}.json"
        scn = hl.load_scenario(path)
        for host in hl.hosts_used(scn):
            if host not in BASES:
                sys.exit(f"Scenario '{scn['name']}' talks to host '{host}': give its address with --base {host}=URL")
        for listname, values in scn.get("shared", {}).items():
            SHARED.setdefault(listname, list(values))
        chosen.append((scn, float(weight or 1)))
    return chosen


# ── one virtual person ────────────────────────────────────────────────────────
class HumanUser(HttpUser):
    abstract = True
    scenario = None
    host = "http://127.0.0.1"  # every request uses an absolute URL; this only satisfies Locust
    wait_time = constant(0)  # pauses are modelled explicitly below

    def on_start(self):
        self.rng = random.Random(f"{SEED}-{next(_USER_INDEX)}")
        self.vars = dict(RUN_VARS)
        self.ua = self.rng.choice(hl.UA_POOL)
        self.cached = set()
        self.ready = False

    def pause(self, spec):
        return hl.think_time(self.rng, spec) * TIME_SCALE

    # -- a single request ------------------------------------------------------
    def headers_for(self, host, step):
        scn = self.scenario
        headers = {
            "User-Agent": self.ua,
            "Accept": "text/html,application/xhtml+xml,*/*;q=0.8" if step.get("html") else "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
        }
        if MARK:
            headers["X-Load-Test"] = RUN_ID
        if host in HOST_HEADERS:
            headers["Host"] = HOST_HEADERS[host]
        for source in (scn.get("headers", {}).get(host, {}), step.get("headers", {})):
            for key, template in source.items():
                value = hl.render(template, self.vars, SHARED, self.rng)
                if value != "":
                    headers[key] = value
                else:
                    headers.pop(key, None)
        return headers

    def run_step(self, step, label=""):
        """Returns "ok", "failed" or "skipped" (a needed value is missing, or a write is not allowed)."""
        if step.get("writes") and not WRITES:
            return "skipped"
        host = step.get("host", self.scenario["hosts"][0])
        try:
            path = hl.render(step["path"], self.vars, SHARED, self.rng)
            body = hl.render_obj(step["json"], self.vars, SHARED, self.rng) if "json" in step else None
            headers = self.headers_for(host, step)
        except hl.MissingVar:
            return "skipped"
        expect = step.get("expect", [200])
        name = f"{label}{step['name']}"
        with self.client.request(
            step.get("method", "GET").upper(), BASES[host] + path, headers=headers, json=body,
            name=name, catch_response=True, timeout=30,
        ) as response:
            code = response.status_code
            if code in expect:
                response.success()
                outcome = "ok"
            else:
                response.failure("no response" if code == 0 else f"HTTP {code}")
                outcome = "failed"
            if outcome == "ok":
                self.read_response(step, response)
        if outcome == "ok" and step.get("assets"):
            self.fetch_assets(host, headers, response)
        return outcome

    def read_response(self, step, response):
        parsed = None
        for var, source in step.get("extract", {}).items():
            if isinstance(source, dict) and "header" in source:
                value = response.headers.get(source["header"])
            elif isinstance(source, dict) and "path" in source:
                # a person opens one item of a list, not always the first
                if parsed is None:
                    try:
                        parsed = response.json()
                    except ValueError:
                        parsed = {}
                found = hl.extract(parsed, source["path"])
                value = self.rng.choice(found) if isinstance(found, list) and found else None
            else:
                if parsed is None:
                    try:
                        parsed = response.json()
                    except ValueError:
                        parsed = {}
                value = hl.extract(parsed, source)
            if value is not None:
                self.vars[var] = value
        for listname, path in step.get("extract_shared", {}).items():
            if parsed is None:
                try:
                    parsed = response.json()
                except ValueError:
                    parsed = {}
            found = hl.extract(parsed, path)
            if isinstance(found, list) and found:
                SHARED[listname] = found

    def fetch_assets(self, host, headers, page):
        """A browser fetches the page's scripts and styles once, then keeps them."""
        asset_headers = {k: v for k, v in headers.items() if k in ("User-Agent", "Host", "X-Load-Test", "Accept-Language")}
        asset_headers["Accept"] = "*/*"
        for path in hl.asset_paths(page.text):
            if path in self.cached:
                continue
            self.cached.add(path)
            self.client.get(BASES[host] + path, headers=asset_headers, name="[static] scripts and styles (first visit)", timeout=30)
            gevent.sleep(self.rng.uniform(0.01, 0.08))

    # -- setup, discovery, journeys, visits ------------------------------------
    def run_with_retry(self, step, label="[setup] "):
        """A person whose request is refused or fails just tries again a little later."""
        for attempt in range(8):
            outcome = self.run_step(step, label)
            if outcome != "failed":
                return outcome
            gevent.sleep(self.rng.uniform(2, 6) * (attempt + 1) * TIME_SCALE)
        return "failed"

    def shared_login(self, step):
        """Everyone on the same account reuses the first person's session.

        The server does the same work for each request either way; this only avoids
        hammering the login route, which the CRM throttles per account (5 a minute)."""
        key = self.scenario["name"]
        with _SHARED_LOGIN["lock"]:
            state = _SHARED_LOGIN["state"].get(key)
            if state is None:
                outcome = self.run_with_retry(step)
                if outcome == "ok":
                    _SHARED_LOGIN["state"][key] = {
                        "cookies": self.client.cookies.get_dict(),
                        "vars": {k: self.vars[k] for k in step.get("extract", {}) if k in self.vars},
                    }
                return outcome
        self.client.cookies.update(state["cookies"])
        self.vars.update(state["vars"])
        return "ok"

    def setup_login(self):
        if ACCOUNTS:
            self.vars["email"], self.vars["password"] = ACCOUNTS[next(_ACCOUNT_INDEX) % len(ACCOUNTS)]
        for step in self.scenario.get("setup", []):
            if step.get("login") and SHARE_LOGIN and not ACCOUNTS:
                outcome = self.shared_login(step)
            else:
                outcome = self.run_with_retry(step)
            if outcome != "ok":
                return False
        return True

    def discover_once(self):
        scn = self.scenario
        steps = scn.get("discover")
        if not steps or scn["name"] in _DISCOVERY["done"]:
            return
        with _DISCOVERY["lock"]:
            if scn["name"] in _DISCOVERY["done"]:
                return
            saved = dict(self.vars)  # discovery may log in as someone else; keep this visitor's own state
            for step in steps:
                if self.run_step(step, "[setup] ") != "ok":
                    break
            self.vars = saved
            _DISCOVERY["done"].add(scn["name"])
            sizes = {k: len(v) for k, v in SHARED.items()}
            print(f"[loadtest] discovered from the target: {sizes or 'nothing (empty catalogue?)'}", flush=True)

    def run_journey(self, journey):
        steps = journey["steps"]
        for i, step in enumerate(steps):
            outcome = self.run_step(step)
            if outcome != "ok":
                return  # a failed or impossible step ends the journey, as it would for a person
            if i == len(steps) - 1:
                return
            if self.rng.random() > step.get("continue_p", 1.0):
                return  # this person leaves here
            gevent.sleep(self.pause(step.get("think", self.scenario.get("think", {}))))

    @task
    def visit(self):
        scn = self.scenario
        if not self.ready:
            self.ready = self.setup_login()
            if not self.ready:
                gevent.sleep(30 * TIME_SCALE)
                return
            self.discover_once()
        session = scn.get("session", {})
        for _ in range(hl.count_from(self.rng, session.get("journeys", {"median": 3, "sigma": 0.5, "max": 8}))):
            self.run_journey(hl.pick_weighted(self.rng, scn["journeys"]))
            gevent.sleep(self.pause(scn.get("think", {})))
        # the visitor leaves; someone else arrives later, mostly with an empty cart and cold browser cache
        gevent.sleep(self.pause(session.get("gap", {"median": 45, "sigma": 0.8, "min": 5, "max": 600})))
        if self.rng.random() < 0.7:
            for key in list(self.vars):
                if key not in RUN_VARS and key not in scn.get("keep_vars", []):
                    del self.vars[key]
            self.cached.clear()


def build_user_classes():
    classes = []
    for scn, weight in load_scenarios():
        name = "".join(c if c.isalnum() else "_" for c in scn["name"]).title().replace("_", "")
        cls = type(name, (HumanUser,), {"scenario": scn, "weight": weight, "__doc__": scn.get("description", "")})
        globals()[name] = cls  # Locust finds user classes in the module namespace
        classes.append(cls)
    return classes


USER_CLASSES = build_user_classes()


# ── load profiles ─────────────────────────────────────────────────────────────
class ProfileShape(LoadTestShape):
    """How many people are on the site over time.

    smoke       5 users for a minute: does the scenario work at all?
    average     ramp to LT_USERS, hold: an ordinary busy day
    peak        LT_USERS, then 3x, then back: the busiest hour
    spike       LT_USERS, a sudden 4x for two minutes, back: a campaign or a mention
    soak        LT_USERS for hours: slow leaks, disk filling, connection exhaustion
    breakpoint  keep adding users in steps until a threshold breaks, then stop
    """

    def __init__(self):
        super().__init__()
        self.profile = env("LT_PROFILE", "average")
        self.users = int(env_num("LT_USERS", 20))
        self.rate = max(env_num("LT_SPAWN", 0.4), 0.05)  # users/second; also paces logins
        self.hold = int(env_num("LT_HOLD", 600))
        self.step_users = int(env_num("LT_STEP_USERS", max(5, self.users // 5)))
        self.step_seconds = int(env_num("LT_STEP_SECONDS", 90))
        self.max_users = int(env_num("LT_MAX_USERS", 400))
        self.mark = {"requests": 0, "failures": 0, "step": -1}
        self.breakpoint = None
        self.stages = self.build_stages()

    def ramp(self, users):
        return int(users / self.rate) + 1

    def build_stages(self):
        n, hold, ramp = self.users, self.hold, self.ramp(self.users)
        if self.profile == "smoke":
            return [(int(env_num("LT_SMOKE_SECONDS", 60)), 5, max(self.rate, 1))]
        if self.profile == "average":
            return [(ramp + hold, n, self.rate)]
        if self.profile == "soak":
            return [(ramp + max(hold, 7200), n, self.rate)]
        if self.profile == "peak":
            t1 = ramp + hold // 2
            t2 = t1 + self.ramp(2 * n) + hold // 2
            return [(t1, n, self.rate), (t2, 3 * n, self.rate), (t2 + hold // 3, n, self.rate * 3)]
        if self.profile == "spike":
            t1 = ramp + max(hold // 3, 120)
            return [(t1, n, self.rate), (t1 + 120, 4 * n, max(self.rate * 5, 2)), (t1 + 120 + 180, n, 5)]
        if self.profile == "breakpoint":
            return []  # decided step by step in tick()
        sys.exit(f"Unknown LT_PROFILE '{self.profile}' (smoke, average, peak, spike, soak, breakpoint)")

    def totals(self):
        entries = [e for k, e in self.runner.stats.entries.items() if not e.name.startswith("[setup]")]
        return sum(e.num_requests for e in entries), sum(e.num_failures for e in entries)

    def tick(self):
        now = self.get_run_time()
        if self.profile != "breakpoint":
            for end, users, rate in self.stages:
                if now < end:
                    return users, rate
            return None
        step = int(now // self.step_seconds)
        users = min(self.users + step * self.step_users, self.max_users)
        requests, failures = self.totals()
        if step != self.mark["step"]:
            if self.mark["step"] >= 0:  # judge the step that just finished
                made = requests - self.mark["requests"]
                bad = failures - self.mark["failures"]
                p95 = self.runner.stats.total.get_current_response_time_percentile(0.95) or 0
                previous = min(self.users + self.mark["step"] * self.step_users, self.max_users)
                print(f"[loadtest] step with {previous} users: {made} requests, {bad} failed, p95 {p95:.0f} ms", flush=True)
                if (made >= 20 and bad / made > MAX_FAIL) or p95 > P95_MS:
                    self.breakpoint = (previous, bad / max(made, 1), p95)
                    print(f"[loadtest] BREAKPOINT: limits exceeded at {previous} users "
                          f"(failures {100 * bad / max(made, 1):.1f}%, p95 {p95:.0f} ms)", flush=True)
                    return None
                if previous >= self.max_users:
                    print(f"[loadtest] reached LT_MAX_USERS={self.max_users} without breaking the limits", flush=True)
                    return None
            self.mark = {"requests": requests, "failures": failures, "step": step}
        return users, max(self.rate, 1)


# ── progress ──────────────────────────────────────────────────────────────────
PROGRESS_EVERY = int(env_num("LT_PROGRESS", 30))


def _progress(environment):
    started = time.time()
    last = (0, 0, started)
    while True:
        gevent.sleep(PROGRESS_EVERY)
        entries = [e for e in environment.stats.entries.values() if not e.name.startswith("[setup]")]
        requests, failures = sum(e.num_requests for e in entries), sum(e.num_failures for e in entries)
        now = time.time()
        rate = (requests - last[0]) / max(now - last[2], 1e-6)
        recent_fail = (failures - last[1]) / max(requests - last[0], 1)
        p95 = environment.stats.total.get_current_response_time_percentile(0.95) or 0
        users = environment.runner.user_count if environment.runner else 0
        print(f"[loadtest] t={int(now - started)}s users={users} {rate:.1f} req/s failures={100 * recent_fail:.1f}% p95={p95:.0f}ms", flush=True)
        last = (requests, failures, now)


@events.test_start.add_listener
def start_progress(environment, **_):
    if PROGRESS_EVERY > 0:
        gevent.spawn(_progress, environment)


# ── verdict ───────────────────────────────────────────────────────────────────
VERDICT_TEXT = []


@events.quit.add_listener
def print_verdict(**_):
    """Locust prints its own tables first; the verdict goes last, where it is read."""
    for text in VERDICT_TEXT:
        print(text, flush=True)


@events.quitting.add_listener
def verdict(environment, **_):
    entries = [e for e in environment.stats.entries.values()]
    real = [e for e in entries if not e.name.startswith("[setup]")]
    total = sum(e.num_requests for e in real)
    failed = sum(e.num_failures for e in real)
    ratio = failed / total if total else 0.0
    rows, worst = [], 0.0
    for e in sorted(real, key=lambda x: -x.num_requests):
        p50, p95, p99 = (e.get_response_time_percentile(p) or 0 for p in (0.5, 0.95, 0.99))
        rows.append({"name": e.name, "requests": e.num_requests, "failures": e.num_failures,
                     "p50_ms": p50, "p95_ms": p95, "p99_ms": p99, "avg_ms": round(e.avg_response_time, 1)})
        if e.num_requests >= 20:
            worst = max(worst, p95)
    problems = []
    if total == 0:
        problems.append("no requests were made")
    if ratio > MAX_FAIL:
        problems.append(f"{100 * ratio:.2f}% of requests failed (limit {100 * MAX_FAIL:.2f}%)")
    if worst > P95_MS:
        problems.append(f"slowest endpoint p95 {worst:.0f} ms (limit {P95_MS:.0f} ms)")
    shape = environment.shape_class
    broke = getattr(shape, "breakpoint", None)
    lines = ["", "=" * 78, f"{'endpoint':<46}{'reqs':>7}{'fail':>6}{'p50':>7}{'p95':>7}{'p99':>7}"]
    for r in rows:
        lines.append(f"{r['name'][:45]:<46}{r['requests']:>7}{r['failures']:>6}{r['p50_ms']:>7.0f}{r['p95_ms']:>7.0f}{r['p99_ms']:>7.0f}")
    lines.append("-" * 78)
    lines.append(f"{total} requests, {failed} failed ({100 * ratio:.2f}%), slowest endpoint p95 {worst:.0f} ms")
    if broke and getattr(shape, "profile", "") == "breakpoint":
        lines.append(f"BREAKPOINT: the limits were first exceeded at {broke[0]} concurrent users")
    lines.append("RESULT: " + ("PASS" if not problems else "FAIL - " + "; ".join(problems)))
    VERDICT_TEXT.append("\n".join(lines))
    out = env("LT_OUT")
    if out:
        Path(out).mkdir(parents=True, exist_ok=True)
        summary = {"run": RUN_ID, "seed": SEED, "total": total, "failed": failed, "worst_p95_ms": worst,
                   "limits": {"max_fail": MAX_FAIL, "p95_ms": P95_MS}, "problems": problems, "endpoints": rows,
                   "breakpoint_users": broke[0] if broke else None}
        (Path(out) / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    # Locust would exit 1 on any failed request, including rate-limited logins that the
    # verdict deliberately ignores; the verdict alone decides the exit code.
    environment.process_exit_code = 1 if problems else 0
