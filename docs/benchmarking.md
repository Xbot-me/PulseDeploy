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
sudo pulse-lt record attach L-001 --results ~/summary.json   # only if you stopped the record without (or with the wrong) results
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

## Results so far: AvenTech CRM on 2 vCPU / 4 GB (Amazon Linux 2023, VMware)

Every run: `loadtest/run.sh --profile breakpoint --time-scale 0.25 --step-users 10 --step-seconds 120`, aggregate of the
admin scenario (people at four times normal speed, so 150 users is roughly 600 ordinary staff), rate limits lifted.
Client p95 values are Locust's rounded buckets.

| Run | CRM | Data | Requests | Failed | Worst p95 | Dashboard p95 | Orders list p95 | CPU peak | Outcome |
|---|---|---|---|---|---|---|---|---|---|
| L-002 | before the reporting changes | 10k orders | 54,598 | 0 | 670 ms | 670 ms | 390 ms | 97% | PASS, no breakpoint found |
| L-003 | before the reporting changes | 200k orders | 676 | 0 | 17,000 ms | 17,000 ms | 11,000 ms | 100% | FAIL at the first step (about 10 users) |
| L-004 | 288396a (indexes, cache, no stampede) | 200k orders | 55,800 | 0 | 790 ms | 600 ms | 360 ms | 100% | PASS, no breakpoint found |

* L-003 stopped after 515 s at the first step, L-004 ran all steps (up to 150 users) for 37 minutes, so the improvement is
  larger than the table suggests.
* L-004 server side: nginx API p50 82 ms / p95 355 ms / p99 963 ms; MySQL 1,474 slow queries (the two cache-refresh
  aggregates, 1.9 to 3.6 s each); Redis 29,372 commands with 13,188 hits and 16 misses (the cache works); peak memory
  2.3 GB of 3.9 GB, no swap, no I/O wait.
* What is left: the p99 of the dashboard (2.0 s) and the status-filtered list (1.5 s) are requests that land on a cache
  refresh while both cores are busy, and CPU still touches 100% at the top of the ramp. No step failed, so the real
  breakpoint of this server has not been found yet (next: `--max-users 400`, or the `large` profile).
