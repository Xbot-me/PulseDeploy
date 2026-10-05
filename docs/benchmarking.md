# Benchmarks you can repeat and compare

A load-test number means little on its own. `pulse-lt` (on the server) records everything that could
change the answer, so two runs are only compared when they differ in the one thing you changed.

Two machines take part:

| Machine | Tool | Job |
|---|---|---|
| the server being tested | `pulse-lt` (installed with the Laravel + Next.js stack) | seeds data, lifts the rate limits, records the server's side |
| a **separate** load generator (your PC or another VM) | `loadtest/run.sh` | creates the human-like traffic ([docs/load-testing.md](load-testing.md)) |

## One benchmark, step by step

On the server (a disposable store, never a client's):

```bash
# 1. a store whose plan is "loadtest", empty
sudo bash loadtest/seed/seed.sh --store loadtest --create-store --no-data   # prints where the admin login is saved
# 2. fill it. small = 10k orders + 100k behaviour events, medium = 200k + 1M, large = 1M + 5M
sudo pulse-lt seed loadtest --profile small --seed 42 --as-of 2026-10-01
# 3. optional: lift the per-IP rate limits so one generator can reach the real capacity
sudo pulse-lt throttles off --for 120
# 4. start recording
sudo pulse-lt record start L-001 --note "small dataset, 20 staff, throttles off"
```

On the load generator, run the traffic (the run writes `loadtest/results/<time>/summary.json`):

```bash
bash loadtest/run.sh --ip <server-ip> --domain <domain> --store loadtest --email lt@loadtest.test \
     --password-file ~/lt-password --profile average --users 20 --hold 600
scp loadtest/results/<time>/summary.json you@<server-ip>:
```

Back on the server:

```bash
sudo pulse-lt record stop --results ~/summary.json     # writes benchmark-L-001.json and .md
sudo pulse-lt throttles on                              # always: puts the server back as it was
sudo pulse-lt diff /var/lib/pulsedeploy/lt/L-001/benchmark-L-001.json /var/lib/pulsedeploy/lt/L-002/benchmark-L-002.json
```

## What a record contains

`/var/lib/pulsedeploy/lt/<id>/benchmark-<id>.json` (and a readable `.md`):

* **Environment:** vCPU, RAM, disk, provider, OS and kernel; PHP, MySQL, Redis, Node and nginx versions;
  the CRM commit and the PulseDeploy commit that were installed.
* **Configuration:** MySQL (buffer pool, max connections, flush mode, table cache), PHP-FPM (`pm.*`), OPcache,
  Redis `maxmemory`, nginx workers; the dataset manifest (profile, seed, counts) and whether the rate limits were lifted.
* **Server during the run:** nginx request time p50/p95/p99 and status counts; CPU busy, I/O wait, steal and
  swap from `vmstat`; peaks of load, memory, PHP workers (and their memory), Node memory, MySQL threads, Redis memory;
  MySQL counters over the run (queries, slow, buffer-pool hit ratio, temp tables on disk, lock waits) and Redis
  counters (hits, misses, evictions); every query slower than 200 ms (`SLOW_MS`), worst five listed.
* **Load generator:** the verdict and the p50/p95/p99 and failures of each request name from `summary.json`.

`pulse-lt diff a.json b.json` prints every environment and configuration value that differs, then the results
side by side. If that first list contains more than the change you meant to test, the comparison is not fair.

## Rate limits: `--throttles on|off`

The CRM limits requests per IP (login 5 a minute; checkout, lookups and behaviour events have their own limits).
One load generator is one IP, so with the limits on you mostly measure the limits (and get 429s, which is the
right answer to "do they protect the app?"). With them off you measure capacity.

`pulse-lt throttles off` sets `LOADTEST_MODE=true` **and** `APP_ENV=staging` in the API's `.env`, rebuilds the
config cache and reloads PHP-FPM, because the CRM ignores `LOADTEST_MODE` in production on purpose. The original
values are saved and `pulse-lt throttles on` restores them byte for byte. A systemd timer does the same
automatically after `--for` minutes (default 120) in case you forget. While it is off the server is not
production-configured: use it only on a test server or in a window you control. nginx's own limit on the login
URLs (30 a minute per IP) is not affected; use a shared login or `--accounts-file` as described in the load-testing guide.

Checked for real against the CRM: with the limits on, the 6th wrong login within a minute got HTTP 429; with
`throttles off`, twelve in a row all got 401; after `throttles on` the `.env` was identical to the original.

## Two seeders

* `sudo pulse-lt seed <store> --profile ...` runs the CRM's own `loadtest:seed`: products, customers, orders,
  reviews and behaviour events, reproducible by seed and date. It refuses `APP_ENV=production` (the command is
  told `--env=staging` for that one process only; the server's configuration is untouched) and any store whose plan
  is not `loadtest` or `demo`. It needs a CRM commit that has the command.
* `loadtest/seed/seed.sh` fills the order tables with plain SQL and works with any CRM version, but has no behaviour events.

Use one or the other for a store, not both. On a disposable test server whose only store is the one `crm.sh` installed
(plan `standard`), add `--force`: `sudo pulse-lt seed <store> --profile small --force`. Never on a client's server.

## Limits of what this measures

* One load generator and one source address; real traffic comes from many.
* A virtual user is a model of a person, not a recording of one; set the think times from your analytics.
* The record reads counters and logs; it does not profile PHP. A slow endpoint with no slow query is a PHP problem:
  profile it (Xdebug, Blackfire, SPX) rather than guess.
* MySQL's slow-query threshold is changed for the duration of the recording and put back by `record stop`.
  If a recording is abandoned, run `sudo pulse-lt record stop` anyway.
