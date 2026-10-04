"""pulse-lt init: write a scenario file for your own site.

    python3 init.py                          ask questions
    python3 init.py --from-urls urls.txt     build it from a list of paths or URLs
    python3 init.py --from-har app.har       build it from a browser recording

Standard library only. Run it through bin/pulse-lt.
"""
import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import builder  # noqa: E402


def valid_url(text):
    parts = urlsplit(text)
    return parts.scheme in ("http", "https") and bool(parts.netloc) and not any(c.isspace() for c in text)


def ask(prompt, default=None, ask_fn=input):
    suffix = f" [{default}]" if default else ""
    answer = ask_fn(f"{prompt}{suffix}: ").strip()
    return answer or default or ""


def choose(prompt, options, default, ask_fn=input):
    """options: {"w": "a website", ...}; returns the key."""
    shown = ", ".join(f"{k} = {v}" for k, v in options.items())
    while True:
        answer = ask(f"{prompt} ({shown})", default, ask_fn).lower()
        if answer in options:
            return answer
        print(f"  please type one of: {', '.join(options)}")


def wizard(ask_fn=input):
    print("Describe the site you want to test. Press Enter to accept the value in [brackets].\n")
    while True:
        url = ask("Address of the site (e.g. https://staging.example.com)", None, ask_fn).rstrip("/")
        if valid_url(url):
            break
        print("  that is not an address; it must start with http:// or https://")
    name = ask("A short name for this test", builder.slug(urlsplit(url).hostname or "site"), ask_fn)
    kind = choose("Is it a website with pages, or an API?", {"w": "website", "a": "API"}, "w", ask_fn)
    signin = choose("How do people sign in?", {"n": "they do not", "t": "a token you give at run time", "f": "a login form or endpoint"}, "n", ask_fn)
    auth = None
    if signin == "f":
        path = ask("Login path (e.g. /api/login or /login)", "/api/login", ask_fn)
        auth = {
            "type": "login", "path": path if path.startswith("/") else "/" + path,
            "user_field": ask("Name of the username field in the request", "email", ask_fn),
            "pass_field": ask("Name of the password field", "password", ask_fn),
            "token_path": ask("Where the response holds a token, e.g. data.token (blank = the server sets a session cookie)", "", ask_fn) or None,
        }
    print("\nNow the pages or endpoints people use, one per line, most important first.")
    print("  - A blank line ends one 'visit' (a few steps in a row, like browsing then opening an item).")
    print("  - Add 'weight=5' to a visit's first line if it is 5x as common as the others.")
    print("  - Type a single dot (.) on its own line when you are done.\n")
    lines = []
    while True:
        line = ask_fn("  > ").strip()
        if line == ".":
            break
        lines.append(line)
    text = "\n".join(lines)
    if not text.strip():
        print("  nothing entered; using the home page")
        text = "/"
    return text, name, url, kind, auth


def main(argv=None):
    ap = argparse.ArgumentParser(prog="pulse-lt init", description="Write a load-test scenario for your own site.")
    ap.add_argument("--from-urls", metavar="FILE", help="a file with one path or URL per line (blank line = new visit)")
    ap.add_argument("--from-har", metavar="FILE", help="a browser recording (DevTools > Network > Save all as HAR)")
    ap.add_argument("--url", help="address of the site, e.g. https://staging.example.com")
    ap.add_argument("--name", help="name of the scenario (default: from the address or file)")
    ap.add_argument("--kind", choices=["auto", "web", "api"], default="auto", help="with --from-urls: pages (fetch scripts and styles) or API")
    ap.add_argument("--login", metavar="PATH", help="with --from-urls: the login endpoint (POST) people sign in through")
    ap.add_argument("--user-field", default="email", help="name of the username field in the login request (default email)")
    ap.add_argument("--pass-field", default="password", help="name of the password field (default password)")
    ap.add_argument("--token-path", help="where the login response holds a token, e.g. data.token (omit for cookie sessions)")
    ap.add_argument("--out", metavar="FILE", help="where to write the scenario (default ./<name>.json)")
    ap.add_argument("--force", action="store_true", help="overwrite an existing file")
    args = ap.parse_args(argv)

    if args.url and not valid_url(args.url):
        ap.error("--url must start with http:// or https://")
    if args.from_urls and args.from_har:
        ap.error("use one of --from-urls and --from-har")
    auth = None
    if args.login:
        if not args.login.startswith("/"):
            ap.error("--login must be a path starting with /")
        auth = {"type": "login", "path": args.login, "user_field": args.user_field, "pass_field": args.pass_field, "token_path": args.token_path}

    try:
        if args.from_har:
            har = json.loads(Path(args.from_har).read_text(encoding="utf-8"))
            name = args.name or Path(args.from_har).stem
            scn, notes = builder.from_har(har, name, args.url)
        elif args.from_urls:
            text = Path(args.from_urls).read_text(encoding="utf-8")
            name = args.name or Path(args.from_urls).stem
            scn, notes = builder.from_urls(text, name, args.url, auth, args.kind)
        else:
            if not sys.stdin.isatty():
                ap.error("no terminal to ask questions on: give --from-urls or --from-har")
            text, name, url, kind, auth = wizard()
            scn, notes = builder.from_urls(text, args.name or name, url, auth, {"w": "web", "a": "api"}[kind])
        builder.check(scn)
    except (ValueError, OSError, KeyError) as exc:
        print(f"pulse-lt init: {exc}", file=sys.stderr)
        return 1

    out = Path(args.out or f"{scn['name']}.json")
    if out.exists() and not args.force:
        print(f"pulse-lt init: {out} already exists (use --force to overwrite, or --out to choose another name)", file=sys.stderr)
        return 1
    out.write_text(json.dumps(scn, indent=2) + "\n", encoding="utf-8")

    steps = sum(len(j["steps"]) for j in scn["journeys"])
    print(f"\nWrote {out}: {len(scn['journeys'])} visit type(s), {steps} step(s).")
    for note in notes:
        print(f"  note: {note}")
    target = scn.get("target", {}).get("url")
    login = bool(scn.get("setup"))
    print("\nNext:")
    print(f"  1. Check it (sends nothing):  pulse-lt check {out}" + ("" if target else " --url https://your-site"))
    print(f"  2. Try it small:              pulse-lt run {out} --profile smoke" + ("" if target else " --url https://your-site")
          + (" --username USER --password-file FILE" if login else ""))
    print(f"  3. The real run:              pulse-lt run {out} --users 50")
    return 0


if __name__ == "__main__":
    sys.exit(main())
