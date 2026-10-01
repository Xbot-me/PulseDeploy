# Load testing with human-like traffic

`loadtest/` generates the traffic of **people**, not a flood of identical requests:
they log in once, look at a page, think, click, sometimes leave half-way, and a
different person arrives later. It is meant to answer "how many people can this
server serve before it hurts, and what breaks first?", for a server you own.

```bash
# from your laptop or a second VM, NOT from the server being tested
bash loadtest/run.sh --ip 172.20.119.56 --domain crm.test \
     --email admin@crm.test --password-file ~/lt-password \
     --profile average --users 20 --hold 600
```

It prints the plan, asks you to type the target's name, then runs and finishes with a
verdict (`RESULT: PASS` / `FAIL`, exit status 0 / 1). Results land in
`loadtest/results/<time>/`: `report.html`, CSV files and `summary.json`.

## Why Locust, and what is ours

The engine is [Locust](https://locust.io) (open source, plain Python, no browser
needed, around since 2011), pinned by a version range in `loadtest/requirements.txt`. Everything
that makes the traffic human, and everything you might need to audit, is small and
ordinary Python in this repository:

| File | Job |
|---|---|
| `loadtest/humanlib.py` | think-time model, weighted choices, templates, response parsing, scenario validation (standard library only, fully unit-tested) |
| `loadtest/locustfile.py` | turns scenario files into virtual people; load profiles; the verdict |
| `loadtest/scenarios/*.json` | what people do (data, not code) |
| `loadtest/run.sh` | validates everything, shows the plan, asks for confirmation, runs |
| `loadtest/tests/` | unit tests, a mock CRM server and end-to-end tests of the engine |

If you distrust the engine itself, `humanlib.py` and the scenarios do not depend on it:
the behaviour model and the scenario format can drive any other HTTP client.

## Requirements

* Python 3.9 or newer. `run.sh` finds it as `python3`, `python` or `py`, then creates
  `loadtest/.venv` once and installs Locust there. On Windows use Git Bash (Python from
  python.org) or WSL; `.gitattributes` keeps the scripts' line endings Unix-style.
* **Run it from a different machine than the server.** Load generated on the server's own
  CPUs mostly measures the load generator: an earlier test on a 2-CPU VM showed this.
* Test the **origin** directly (an IP, or a hostname that bypasses the CDN), not through
  Cloudflare, which may rate-limit or ban the test traffic.

## Safety

* It asks you to type the target's name before any traffic is sent (`--yes` skips this for
  automation). Only test servers you own or have written permission to test; cloud providers
  have their own rules for stress tests.
* **No data is written by default.** Steps that create data (a shopping cart) are skipped
  unless you pass `--writes`; use a dedicated test store for that, never one with real orders.
* More than 200 users at the peak needs `--allow-large`.
* Every request carries `X-Load-Test: <run id>` so you can find or filter it in server logs.
* The password is read from a file or the environment, never from the command line.
* **Logins are throttled by the CRM itself**: `throttle:login` allows 5 attempts a minute per
  email and IP (nginx adds 30 a minute per IP on the API host). Behind the admin app every
  login reaches the API from `127.0.0.1`, so the limit is effectively per account. Twenty virtual
  staff on one account would be refused almost every time (the first real run saw 81% of login
  attempts answered 429). So by default people sharing the one `--email` account log in **once**
  and reuse that session, which costs the server the same per request. For a more faithful run give each
  person their own account with `--accounts-file` (one `email:password` per line, cycled, so 20
  people need 20 accounts to avoid sharing); `--no-share-login` makes everyone log in anyway,
  to test the throttle itself. A person whose login is refused retries after a pause.

## How a virtual person behaves

| Real behaviour | How it is modelled |
|---|---|
| People pause between actions; most pauses are short, a few are long | log-normal think time per step (`think`: `median`, `sigma`, `min`, `max`) |
| A visit is a handful of things | each visit runs a few weighted "journeys" (`session.journeys`) |
| Not everyone finishes | after a step the person may leave (`continue_p`) |
| A failed page ends the attempt | a failed or impossible step ends the journey |
| Staff log in once, not on every click | `setup` steps run once per virtual person (people on one shared account reuse the first login, see Safety) |
| A new visitor's browser downloads scripts and styles; a returning one has them cached | page steps with `"assets": true` fetch `/…js` and `/…css` once, then not again; 30% of "returning" visits keep the cache |
| Different people, different devices | each person gets a real desktop or mobile browser identity |
| After a visit the person is gone; another arrives later | a gap (`session.gap`) then a fresh person (new cart, usually a cold cache) |
| Rate limits exist | a rate-limited login is retried after a pause |

`--time-scale 0.1` makes everyone click ten times faster (a harsher run).

## Load profiles

| Profile | Shape | Answers |
|---|---|---|
| `smoke` | 5 users, 1 minute | does the scenario work at all? |
| `average` | ramp to `--users`, hold `--hold` seconds | an ordinary busy day |
| `peak` | `--users`, then 3x, then back | the busiest hour |
| `spike` | `--users`, a sudden 4x for 2 minutes, back | a campaign or a mention |
| `soak` | `--users` for 2 hours or more | slow leaks, filling disks, exhausted connections |
| `breakpoint` | add `--step-users` every `--step-seconds` until a limit breaks, then stop | where is the edge, and what fails first? |

The run **fails** when more than `--max-fail` (default 1%) of requests fail, or any
endpoint's p95 exceeds `--p95-ms` (default 1500 ms). Setup requests (logins, discovery) are not counted.

## Watch the server while it runs

On the server, in another terminal, during the hold phase:

```bash
sudo bash scripts/audit.sh --no-perf          # memory, swap, workers, CPU steal, database and Redis counters
```

and afterwards check `journalctl -u pulse-next@admin` for restarts. The load-test verdict says
what users would see; the audit says why.

## Scenarios

A scenario is a JSON file in `loadtest/scenarios/` (or any path). Shipped:

* `aventech-admin`: back-office staff in the admin app: login page, dashboard, orders, order
  detail, products, search, categories, brands. It goes through the Next.js app (pages and the
  `/api/proxy/...` calls those pages make), so it exercises nginx, Node and PHP together. Read-only.
* `aventech-storefront`: shoppers calling the CRM's public storefront API: home content,
  categories, discounts, recommendations and (with `--writes`) a guest cart. The CRM repository has no
  product listing or search endpoint for shoppers, and the storefront application itself is not part of
  it, so **add your storefront's own calls** (copy the file and edit it).

Run several at once, with a share of the virtual users each: `--scenario aventech-admin:1,aventech-storefront:9`.

```json
{
  "name": "my-shop",
  "hosts": ["api"],                                         // keys that need a --base
  "headers": { "api": { "X-Store-Subdomain": "{store}" } }, // sent with every request to that host
  "think": { "median": 8, "sigma": 0.8, "min": 1, "max": 120 },
  "session": { "journeys": { "median": 3 }, "gap": { "median": 30 } },
  "shared": { "search_terms": ["shirt", "bag"] },           // lists usable as {any:search_terms}
  "setup": [ /* steps run once per person, e.g. a login */ ],
  "discover": [ /* steps run once per run, to learn ids: "extract_shared" */ ],
  "journeys": [
    { "name": "find and open a product", "weight": 5, "steps": [
      { "name": "search", "host": "api", "path": "/shop/search?q={any:search_terms}",
        "extract": { "pid": { "path": "data.items[*].id", "pick": "random" } },
        "think": { "median": 6 }, "continue_p": 0.8 },
      { "name": "product", "host": "api", "path": "/shop/products/{pid}" }
    ] }
  ]
}
```

Step keys: `name`, `path` (required), `host`, `method`, `json`, `headers`, `think`, `expect`
(accepted status codes, default `[200]`), `continue_p`, `html` and `assets` (for pages),
`extract` (a path such as `data.token` or `a.b[0].id`; `{"header": "X-Name"}`; or
`{"path": …, "pick": "random"}`), `extract_shared` (a list for `{any:name}`), `writes` (skipped
unless `--writes`). In strings: `{name}` is a value of the person or the run (`--var name=value`,
`--store`, `--email`), `{name?}` is optional (an empty header is dropped) and `{any:list}` picks a
random element. Check a file without sending anything: `bash loadtest/run.sh --check ...`.

## Realistic test data

An empty store makes every endpoint look fast. `loadtest/seed/seed.sh` fills a **separate test store**
with a catalogue, customers and orders shaped like a real shop: popular products, repeat customers,
more recent orders than old ones, the CRM's own order statuses, payment methods and districts.
Run it on the server:

```bash
sudo bash loadtest/seed/seed.sh --store loadtest --create-store          # 5,000 products, 20,000 customers, 100,000 orders
sudo bash loadtest/seed/seed.sh --store loadtest --purge --yes           # remove exactly what it added
sudo bash loadtest/seed/seed.sh --store loadtest --orders 30000 --dry-run  # plan and disk estimate only
```

`--create-store` makes the store through the CRM's own `store:create` and saves the admin login in
`/root/loadtest-store-credentials.txt` (mode 600). Then point the load test at it with
`--store loadtest --email lt@loadtest.test` (the password is in that file).

Safety: it refuses the live store from `/etc/pulsedeploy/crm.conf`, refuses any store that holds products,
orders or customers it did not create, checks free disk first, and asks you to type the store name. Everything
it adds is marked (`LT-` SKUs and order numbers, `lt-` slugs, `lt...@loadtest.example` e-mails) so `--purge` removes exactly that.
The same `--seed` gives the same data. 100,000 orders load in about 10 seconds and take roughly 110 MB.

### What it showed on the CRM (MariaDB 10.11, one core, measured once, your numbers will differ)

| Orders in the store | `GET /admin/orders` | `GET /admin/dashboard` |
|---|---|---|
| 2,000 | 0.35 s | 0.58 s |
| 10,000 | 1.5 s | 2.5 s |
| 30,000 | 8.6 s | 8.0 s |
| 100,000 | times out (30 s PHP limit) | times out |

The cause is in the application, not the server: `OrderController::index` runs `(clone $query)->get()` to
build its summary, which loads **every** order with its lines and payments into PHP before paginating. Tuning
PHP, MySQL or Redis does not fix that; the summary needs SQL aggregates. Check this with a seeded store
before trusting a result from an empty one.

## What this does not tell you

* **It is server-side load, not a browser.** Pages are fetched but JavaScript is not run, so
  client-side rendering time and layout cost are not measured; use Lighthouse for those.
* **Think times are a model.** Defaults are plausible, not measured from your analytics. Set the
  `median` values from real data (your analytics, or the server's access log) for a faithful result.
* **One source address.** Real users come from many addresses. Per-IP limits (the login throttle,
  fail2ban, a firewall) see this test as one visitor. Network-level floods cannot be simulated from one
  machine, and this is not a denial-of-service tool.
* **An empty database is always fast.** Load realistic data first (see "Realistic test data" below).
* **Fixed number of people.** Virtual users are a closed population (each waits for its own
  responses), a good model for staff and for shoppers on a healthy site; during an overload real arrivals
  keep coming, which `spike` and `breakpoint` approximate but do not copy exactly.

## Testing the module itself

```bash
python3 -m unittest discover -s loadtest/tests -p 'test_humanlib.py'   # no dependencies
pip install -r loadtest/requirements.txt && python3 -m unittest loadtest/tests/test_engine.py
LT_SLOW_TESTS=1 python3 -m unittest loadtest/tests/test_engine.py      # adds writes, rate limits, breakpoint
```

The engine tests start a mock CRM (`loadtest/tests/mock_server.py`) and run real Locust against it with
human pauses shortened 50x. `bash tests/run.sh` runs the dependency-free tests, and the engine tests when Locust is installed.
