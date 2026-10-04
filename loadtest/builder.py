"""Turn simple inputs into scenario files (standard library only).

    from_urls(text, ...)   a list of paths or URLs, blank lines separate journeys
    from_har(har, ...)     a browser recording (DevTools > Network > Save all as HAR)

Both return (scenario dict, notes list). The scenario always passes
humanlib.validate_scenario; notes are things the person should read before running it.
"""
import json
import re
from datetime import datetime
from urllib.parse import urlsplit

import humanlib as hl

HOST = "app"
STATIC_EXT = {
    ".js", ".mjs", ".css", ".map", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".avif", ".ico",
    ".woff", ".woff2", ".ttf", ".otf", ".eot", ".mp4", ".webm", ".mp3", ".pdf",
}
LOGIN_PATH = re.compile(r"/(log-?in|sign-?in|auth|session|token|authenticate)\b", re.I)
SECRET_KEY = re.compile(r"pass|pwd|secret|token|card|cvv|cvc|ssn|otp", re.I)
USER_KEY = re.compile(r"e-?mail|user|login|phone", re.I)
TOKEN_KEY = re.compile(r"^(access_?token|token|jwt|id_?token|auth_?token)$", re.I)


def slug(text, fallback="scenario"):
    out = re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-")
    return out or fallback


def looks_like_page(path):
    """A guess for whether a GET returns a web page (so scripts and styles are fetched too)."""
    p = path.split("?", 1)[0].lower()
    if re.match(r"^/(api|v\d+|graphql|rest|rpc)(/|$)", p) or p.endswith(".json"):
        return False
    return "." not in p.rsplit("/", 1)[-1] or p.endswith((".html", ".htm"))


def skeleton(name, url=None, description=""):
    scn = {
        "name": slug(name),
        "description": description or f"Human-like traffic for {name}.",
        "hosts": [HOST],
        "think": {"median": 6, "sigma": 0.7, "min": 1.0, "max": 90},
        "session": {
            "journeys": {"median": 3, "sigma": 0.5, "min": 1, "max": 6},
            "gap": {"median": 45, "sigma": 0.8, "min": 5, "max": 600},
        },
        "journeys": [],
    }
    if url:
        scn["target"] = {"url": url.rstrip("/")}
    return scn


def login_step(path, user_field="email", pass_field="password", token_path=None, method="POST"):
    step = {
        "name": "api: login", "login": True, "host": HOST, "method": method, "path": path,
        "json": {user_field: "{username}", pass_field: "{password}"}, "expect": [200, 201, 204],
    }
    if token_path:
        step["extract"] = {"token": token_path}
    return step


def apply_auth(scn, auth):
    """auth: None, {"type": "login", "path", "user_field", "pass_field", "token_path"}."""
    if not auth or auth.get("type") in (None, "none", "token"):
        return
    if auth["type"] != "login":
        raise ValueError(f"unknown auth type {auth['type']!r}")
    scn["setup"] = [login_step(auth["path"], auth.get("user_field") or "email", auth.get("pass_field") or "password",
                               auth.get("token_path"))]
    if auth.get("token_path"):
        scn["headers"] = {HOST: {"Authorization": "Bearer {token?}"}}


# ── from a list of URLs ───────────────────────────────────────────────────────
_LINE = re.compile(r"^(?:(GET|POST|PUT|PATCH|DELETE|HEAD)\s+)?(\S+)(?:\s+weight=(\d+(?:\.\d+)?))?$", re.I)


def parse_urls(text, base=None):
    """-> (base, groups) where a group is {"name", "weight", "steps": [(method, path)]}.

    One target per line: "/path", "GET /path", "https://host/path", optionally "weight=3".
    A blank line ends a journey; "# journey: name" names the next one; other # lines are comments.
    """
    groups, current, pending_name = [], None, None
    errors, origin = [], None
    for number, raw in enumerate((text or "").splitlines(), 1):
        line = raw.strip()
        if not line:
            current = None
            continue
        if line.startswith("#"):
            m = re.match(r"#\s*journey:\s*(.+)$", line, re.I)
            if m:
                pending_name, current = m.group(1).strip(), None
            continue
        m = _LINE.match(line)
        if not m:
            errors.append(f"line {number}: expected [METHOD] /path or URL [weight=N], got {line!r}")
            continue
        method, target, weight = (m.group(1) or "GET").upper(), m.group(2), m.group(3)
        if re.match(r"^https?://", target, re.I):
            parts = urlsplit(target)
            this_origin = f"{parts.scheme}://{parts.netloc}"
            if origin and this_origin != origin:
                errors.append(f"line {number}: {this_origin} is a different site from {origin}; one scenario tests one site")
                continue
            origin = this_origin
            target = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
        elif not target.startswith("/"):
            errors.append(f"line {number}: {target!r} must start with / or be a full URL")
            continue
        if current is None:
            current = {"name": pending_name, "weight": 1.0, "steps": []}
            groups.append(current)
            pending_name = None
        if weight:
            current["weight"] = float(weight)
        current["steps"].append((method, target))
    if errors:
        raise ValueError("\n".join(errors))
    if not groups:
        raise ValueError("no paths found")
    return (base or origin), groups


def from_urls(text, name, url=None, auth=None, kind="auto"):
    base, groups = parse_urls(text, url)
    scn = skeleton(name, base)
    notes = []
    if not base:
        notes.append("no site address in the list: pass --url when you run it")
    for g in groups:
        steps = []
        for method, path in g["steps"]:
            step = {"name": f"{method} {path.split('?', 1)[0]}"[:60], "host": HOST, "path": path}
            if method != "GET":
                step["method"] = method
                step["writes"] = True
            if method == "GET" and (kind == "web" or (kind == "auto" and looks_like_page(path))):
                step.update(html=True, assets=True)
            steps.append(step)
        first = g["steps"][0][1].split("?", 1)[0]
        journey = {"name": g["name"] or f"visit {first}", "steps": steps}
        if g["weight"] != 1:
            journey["weight"] = g["weight"]
        scn["journeys"].append(journey)
    if any(m != "GET" for g in groups for m, _ in g["steps"]):
        notes.append("steps that are not GET were marked as writes: they are skipped unless you run with --writes, "
                     "and they send no body (add a \"json\" object to the step if the endpoint needs one)")
    apply_auth(scn, auth)
    return scn, notes


# ── from a browser recording ──────────────────────────────────────────────────
def _when(text):
    text = re.sub(r"Z$", "+00:00", text or "")
    text = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], text, count=1)
    return datetime.fromisoformat(text).timestamp()


def _body_json(entry):
    post = entry["request"].get("postData") or {}
    if "json" not in (post.get("mimeType") or "").lower():
        return None
    try:
        return json.loads(post.get("text") or "")
    except ValueError:
        return None


def _response_json(entry):
    content = entry["response"].get("content") or {}
    text = content.get("text")
    if not text or "json" not in (content.get("mimeType") or "").lower():
        return None
    if content.get("encoding") == "base64":
        import base64
        try:
            text = base64.b64decode(text).decode("utf-8", "replace")
        except ValueError:
            return None
    try:
        return json.loads(text)
    except ValueError:
        return None


def find_token_path(data, prefix="", depth=0):
    """Path (data.token) of a bearer-looking field in a login response, or None."""
    if depth > 3 or not isinstance(data, dict):
        return None
    for key, value in data.items():
        if TOKEN_KEY.match(key) and isinstance(value, str) and value:
            return prefix + key
    for key, value in data.items():
        found = find_token_path(value, f"{prefix}{key}.", depth + 1)
        if found:
            return found
    return None


def _scrub(body, notes):
    """Replace credentials in a recorded request body so none is stored in the scenario."""
    if isinstance(body, dict):
        out = {}
        for key, value in body.items():
            if re.search(r"pass|pwd", key, re.I):
                out[key] = "{password}"
            elif USER_KEY.search(key) and isinstance(value, str):
                out[key] = "{username}"
            elif SECRET_KEY.search(key):
                notes.append(f"dropped the secret field {key!r} from a recorded request body")
            else:
                out[key] = _scrub(value, notes)
        return out
    if isinstance(body, list):
        return [_scrub(v, notes) for v in body]
    return body


def from_har(har, name, url=None, gap_seconds=20, max_steps=200):
    entries = (har.get("log") or {}).get("entries") or []
    if not entries:
        raise ValueError("the recording has no requests")
    entries = sorted(entries, key=lambda e: _when(e.get("startedDateTime")))
    notes = []

    # the site under test: the origin that served the most requests
    counts = {}
    for e in entries:
        parts = urlsplit(e["request"]["url"])
        origin = f"{parts.scheme}://{parts.netloc}"
        counts[origin] = counts.get(origin, 0) + 1
    base = (url or max(counts, key=counts.get)).rstrip("/")
    bp = urlsplit(base)
    base_origin = f"{bp.scheme}://{bp.netloc}"
    if len(counts) > 1:
        others = ", ".join(sorted(o for o in counts if o != base_origin))
        notes.append(f"requests to other sites were left out ({others})")

    auth_header = cookie_header = False
    kept, setup, token_path = [], [], None
    for e in entries:
        req, res = e["request"], e["response"]
        parts = urlsplit(req["url"])
        if f"{parts.scheme}://{parts.netloc}" != base_origin:
            continue
        names = {h["name"].lower() for h in req.get("headers", [])}
        auth_header |= "authorization" in names
        cookie_header |= "cookie" in names
        method = req["method"].upper()
        path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
        ext = "." + parts.path.rsplit(".", 1)[-1].lower() if "." in parts.path.rsplit("/", 1)[-1] else ""
        mime = ((res.get("content") or {}).get("mimeType") or "").lower()
        if method in ("OPTIONS", "CONNECT") or ext in STATIC_EXT or mime.startswith(("image/", "font/", "text/css", "application/javascript", "text/javascript")):
            continue
        status = res.get("status", 0)
        if status >= 400 or status == 0:
            continue
        if method == "POST" and LOGIN_PATH.search(parts.path) and not setup:
            body = _body_json(e) or {}
            fields = [k for k in body if isinstance(k, str)]
            user_field = next((k for k in fields if USER_KEY.search(k)), "email")
            pass_field = next((k for k in fields if re.search(r"pass|pwd", k, re.I)), "password")
            token_path = find_token_path(_response_json(e))
            setup.append(login_step(parts.path, user_field, pass_field, token_path))
            continue
        step = {"name": f"{method} {parts.path}"[:60], "host": HOST, "path": path, "_t": _when(e["startedDateTime"])}
        if method != "GET":
            step["method"] = method
            step["writes"] = True
            body = _body_json(e)
            if body is not None:
                step["json"] = _scrub(body, notes)
        elif "html" in mime:
            step.update(html=True, assets=True)
        if 200 <= status < 300 and status != 200:
            step["expect"] = [status]
        kept.append(step)

    if not kept:
        raise ValueError("nothing left after dropping static files, failed requests and other sites")
    if len(kept) > max_steps:
        notes.append(f"kept the first {max_steps} of {len(kept)} requests")
        kept = kept[:max_steps]

    # split the recording into journeys wherever the person paused for a while, and use the
    # recorded gap after each request as that step's think time
    journeys, current = [], []
    for i, step in enumerate(kept):
        current.append(step)
        gap = kept[i + 1]["_t"] - step["_t"] if i + 1 < len(kept) else None
        if gap is None or gap > gap_seconds:
            journeys.append(current)
            current = []
        else:
            median = round(max(gap, 0.2), 1)
            step["think"] = {"median": median, "sigma": 0.4, "min": round(max(0.05, median * 0.2), 2), "max": round(max(median * 4, 2), 1)}
    scn = skeleton(name, base, "Replayed with human timing from a browser recording.")
    for n, steps in enumerate(journeys, 1):
        for step in steps:
            step.pop("_t", None)
        scn["journeys"].append({"name": f"recorded visit {n}: {steps[0]['name']}"[:80], "steps": steps})
    if setup:
        scn["setup"] = setup
        if token_path:
            scn["headers"] = {HOST: {"Authorization": "Bearer {token?}"}}
        notes.append("found a login request: run with --username and --password-file (the recorded credentials were not stored)")
    elif auth_header:
        notes.append("the recording sent an Authorization header, which is not copied: run with --token-file FILE (or --header)")
    elif cookie_header:
        notes.append("the recording used session cookies, which are not copied: add a login with "
                     "'pulse-lt init' (sign-in = form) or pass --header 'Cookie: name=value' for a test session")
    if any(s.get("writes") for j in journeys for s in j):
        notes.append("recorded POST/PUT/DELETE requests were marked as writes: skipped unless you run with --writes, "
                     "and then only against a test environment")
    notes.append("paths were copied as recorded (same ids, same search terms): look through them for anything private")
    return scn, notes


def check(scn):
    problems = hl.validate_scenario(scn)
    if problems:
        raise ValueError("generated scenario is invalid:\n  - " + "\n  - ".join(problems))
    return scn
