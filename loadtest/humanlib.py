"""Pure helpers for the load-test engine.

Nothing here imports Locust or touches the network, so everything can be
unit-tested with the standard library only (loadtest/tests/test_humanlib.py).

The model of a "human":
  * time between actions is log-normal: most pauses are short, a few are long
    (reading, getting a coffee), none are negative or zero;
  * a person does a handful of things in a visit, then leaves, and a different
    person arrives later;
  * not everyone finishes what they start (funnel drop-off);
  * a new visitor's browser downloads the page's scripts and styles, a returning
    one already has them cached.
"""
import json
import math
import random
import re

# Real desktop and mobile browsers, so servers and caches see ordinary clients.
UA_POOL = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
]

METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"}


class ScenarioError(ValueError):
    """The scenario file is malformed."""


class MissingVar(Exception):
    """A template needs a value that is not available (yet)."""

    def __init__(self, name):
        super().__init__(name)
        self.name = name


# ── time and choice ───────────────────────────────────────────────────────────
def think_time(rng, spec):
    """A human pause in seconds: log-normal around spec["median"], clamped to [min, max]."""
    median = max(float(spec.get("median", 5)), 1e-6)
    sigma = float(spec.get("sigma", 0.6))
    lo = float(spec.get("min", 0.2))
    hi = float(spec.get("max", median * 20))
    return min(max(rng.lognormvariate(math.log(median), sigma), lo), hi)


def count_from(rng, spec):
    """A whole number drawn from the same log-normal shape (journeys per visit, at least 1)."""
    return max(1, int(round(think_time(rng, spec))))


def pick_weighted(rng, items):
    """One item, chosen with probability proportional to its "weight" (default 1)."""
    weights = [max(float(i.get("weight", 1)), 0.0) for i in items]
    total = sum(weights)
    if total <= 0:
        raise ScenarioError("all weights are zero")
    point = rng.random() * total
    running = 0.0
    for item, weight in zip(items, weights):
        running += weight
        if point <= running:
            return item
    return items[-1]


# ── templates ─────────────────────────────────────────────────────────────────
_TOKEN = re.compile(r"\{(any:)?([A-Za-z_][A-Za-z0-9_]*)(\?)?\}")


def render(text, values, shared=None, rng=None):
    """Fill {name}, {name?} and {any:list} in a string.

    {name}      a value of this visitor or of the run; MissingVar when unset
    {name?}     the same, but an empty string when unset
    {any:list}  a random element of a list discovered once per run
    """
    pick = (rng or random).choice

    def substitute(match):
        any_, name, optional = match.groups()
        if any_:
            pool = (shared or {}).get(name) or []
            if pool:
                return str(pick(pool))
        elif values.get(name) not in (None, ""):
            return str(values[name])
        if optional:
            return ""
        raise MissingVar(name)

    return _TOKEN.sub(substitute, text)


def render_obj(obj, values, shared=None, rng=None):
    """render() applied to every string inside nested dicts and lists."""
    if isinstance(obj, str):
        return render(obj, values, shared, rng)
    if isinstance(obj, list):
        return [render_obj(i, values, shared, rng) for i in obj]
    if isinstance(obj, dict):
        return {k: render_obj(v, values, shared, rng) for k, v in obj.items()}
    return obj


# ── reading responses ─────────────────────────────────────────────────────────
_PATH_TOKEN = re.compile(r"[^.\[\]]+|\[-?\d+\]|\[\*\]")


def extract(data, path):
    """Pick a value out of parsed JSON with a tiny path language.

    a.b[0].c   a scalar (None when anything on the way is missing)
    a.b[*].id  a list, fanning out over every element
    """
    nodes = [data]
    fan = False
    for token in _PATH_TOKEN.findall(path):
        nxt = []
        for node in nodes:
            if token == "[*]":
                fan = True
                if isinstance(node, list):
                    nxt.extend(node)
            elif token.startswith("["):
                index = int(token[1:-1])
                if isinstance(node, list) and -len(node) <= index < len(node):
                    nxt.append(node[index])
            elif isinstance(node, dict) and token in node:
                nxt.append(node[token])
        nodes = nxt
        if not nodes:
            break
    if fan:
        return [n for n in nodes if n is not None]
    return nodes[0] if nodes else None


_ASSET = re.compile(r"""(?:src|href)=["'](/[^"'/][^"']*\.(?:js|css)(?:\?[^"']*)?)["']""", re.I)


def asset_paths(html, limit=12):
    """Same-origin scripts and stylesheets a browser would fetch for this page."""
    found = []
    for match in _ASSET.finditer(html or ""):
        path = match.group(1)
        if path not in found:
            found.append(path)
            if len(found) >= limit:
                break
    return found


# ── accounts ──────────────────────────────────────────────────────────────────
def parse_accounts(text):
    """Lines of "email:password" (blank lines and # comments ignored) -> [(email, password)].

    The password may contain colons; only the first colon separates the two.
    """
    accounts = []
    for number, raw in enumerate((text or "").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        email, sep, password = line.partition(":")
        if not sep or not email.strip() or not password:
            raise ScenarioError(f"accounts file line {number}: expected email:password")
        if any(ord(c) < 32 for c in line):
            raise ScenarioError(f"accounts file line {number}: contains control characters (paste markers?)")
        accounts.append((email.strip(), password))
    return accounts


# ── scenarios ─────────────────────────────────────────────────────────────────
def _check_think(spec, where, errors):
    if spec is None:
        return
    if not isinstance(spec, dict):
        errors.append(f"{where}: must be an object such as {{\"median\": 5}}")
        return
    for key in ("median", "sigma", "min", "max"):
        if key in spec and not isinstance(spec[key], (int, float)):
            errors.append(f"{where}.{key}: must be a number")


def _check_steps(steps, hosts, where, errors):
    if not isinstance(steps, list) or not steps:
        errors.append(f"{where}: needs at least one step")
        return
    for i, step in enumerate(steps):
        at = f"{where}[{i}]"
        if not isinstance(step, dict):
            errors.append(f"{at}: must be an object")
            continue
        for key in ("name", "path"):
            if not isinstance(step.get(key), str) or not step[key]:
                errors.append(f"{at}: missing \"{key}\"")
        if isinstance(step.get("path"), str) and not step["path"].startswith("/"):
            errors.append(f"{at}: path must start with /")
        if str(step.get("method", "GET")).upper() not in METHODS:
            errors.append(f"{at}: unknown method {step.get('method')!r}")
        if step.get("host", hosts[0] if hosts else None) not in hosts:
            errors.append(f"{at}: host {step.get('host')!r} is not in \"hosts\" {hosts}")
        if "expect" in step and not (isinstance(step["expect"], list) and all(isinstance(c, int) for c in step["expect"])):
            errors.append(f"{at}: expect must be a list of status codes")
        if "continue_p" in step and not (isinstance(step["continue_p"], (int, float)) and 0 <= step["continue_p"] <= 1):
            errors.append(f"{at}: continue_p must be between 0 and 1")
        _check_think(step.get("think"), f"{at}.think", errors)
        for var, source in step.get("extract", {}).items():
            ok = isinstance(source, str) or (isinstance(source, dict) and ("header" in source or "path" in source))
            if not ok:
                errors.append(f"{at}.extract.{var}: use a path string, {{\"header\": NAME}} or {{\"path\": P, \"pick\": \"random\"}}")


def validate_scenario(scn):
    """A list of human-readable problems; empty when the scenario is usable."""
    errors = []
    if not isinstance(scn, dict):
        return ["the scenario must be a JSON object"]
    if not isinstance(scn.get("name"), str) or not scn["name"]:
        errors.append("missing \"name\"")
    hosts = scn.get("hosts")
    if not (isinstance(hosts, list) and hosts and all(isinstance(h, str) for h in hosts)):
        errors.append("\"hosts\" must be a non-empty list such as [\"api\", \"admin\"]")
        hosts = []
    _check_think(scn.get("think"), "think", errors)
    session = scn.get("session", {})
    if not isinstance(session, dict):
        errors.append("\"session\" must be an object")
    else:
        _check_think(session.get("journeys"), "session.journeys", errors)
        _check_think(session.get("gap"), "session.gap", errors)
    journeys = scn.get("journeys")
    if not isinstance(journeys, list) or not journeys:
        errors.append("\"journeys\" must be a non-empty list")
    else:
        for i, journey in enumerate(journeys):
            if not isinstance(journey, dict) or not journey.get("name"):
                errors.append(f"journeys[{i}]: missing \"name\"")
                continue
            if not isinstance(journey.get("weight", 1), (int, float)):
                errors.append(f"journeys[{i}].weight: must be a number")
            _check_steps(journey.get("steps"), hosts, f"journeys[{i}].steps", errors)
    for section in ("setup", "discover"):
        if section in scn:
            _check_steps(scn[section], hosts, section, errors)
    return errors


def load_scenario(path):
    with open(path, encoding="utf-8") as handle:
        try:
            scn = json.load(handle)
        except json.JSONDecodeError as exc:
            raise ScenarioError(f"{path}: not valid JSON ({exc})") from exc
    problems = validate_scenario(scn)
    if problems:
        raise ScenarioError(f"{path}:\n  - " + "\n  - ".join(problems))
    return scn


def hosts_used(scn):
    """Every host key a scenario talks to (so missing base URLs fail before the run starts)."""
    used = set()
    steps = list(scn.get("setup", [])) + list(scn.get("discover", []))
    for journey in scn.get("journeys", []):
        steps.extend(journey.get("steps", []))
    default = scn["hosts"][0]
    for step in steps:
        used.add(step.get("host", default))
    return sorted(used)


if __name__ == "__main__":
    # python3 humanlib.py FILE...   validate scenario files; prints "OK name hosts=a,b" or the problems
    import sys

    status = 0
    for target in sys.argv[1:]:
        try:
            scenario = load_scenario(target)
            print(f"OK {scenario['name']} hosts={','.join(hosts_used(scenario))}")
        except (ScenarioError, OSError) as exc:
            print(f"BAD {exc}")
            status = 1
    sys.exit(status)
