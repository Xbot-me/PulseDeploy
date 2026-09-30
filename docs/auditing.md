# Auditing a deployed server

```bash
sudo pulse-crm audit            # on a server installed with crm.sh
sudo bash scripts/audit.sh      # from a checkout of this repository
sudo bash scripts/audit.sh --load      # plus a 200-request burst against the API
sudo bash scripts/audit.sh --no-perf   # skip the response-time section
```

The audit is **read-only**. Each line is `PASS`, `WARN`, `FAIL`, `INFO` or `SKIP`, with
the measured value next to its target. It exits 1 when anything failed, so it also
works in a monitoring job.

## What "optimised" means here

There is no such thing as 100% optimised: every setting trades something for something
else. What can be shown is whether the server

1. **matches its own tuning** (the numbers `scripts/lib/profile_tuning.sh` calculates
   from the machine's RAM),
2. **behaves well under real measurement** (memory headroom, cache hit rates, latency),
3. **is hardened** (only the intended ports, correct permissions, production Laravel).

Thresholds marked *guideline* are starting points, not laws; change them with
`AUDIT_P95_MS` and `AUDIT_SAMPLES`.

## 1. Drift: live settings against the calculated targets

The targets come from the RAM found on the machine (`tune_summary` is printed at the
top). A `WARN` here means the live value differs from the target: someone edited it, or
the change was never applied. It is not automatically wrong.

| Check | Read from | Target |
|---|---|---|
| PHP-FPM `pm`, `pm.max_children`, `pm.max_requests` | `pulse-laravel.conf` pool | `ondemand`, `RAM x 20% / 60 MB` (4..40), recycle set |
| OPcache, `validate_timestamps`, `expose_php` | `99-pulsedeploy.ini` | enabled, `0` (deploys reload PHP-FPM), Off |
| InnoDB buffer pool | `SELECT @@innodb_buffer_pool_size` | about 18% of RAM, in InnoDB chunk sizes |
| `max_connections`, `performance_schema`, `innodb_flush_method`, `skip_name_resolve` | live database | 50 (<= 4 GB RAM), off, `O_DIRECT`, on |
| Redis `maxmemory`, policy, `bind` | `CONFIG GET` | about 6% of RAM (64..512 MB), `allkeys-lru`, loopback |
| Node heap and `MemoryMax` per app | `/etc/pulsedeploy/<app>.env`, systemd | heap 256-512 MB, `MemoryMax` = heap + 192 MB |
| nginx | `nginx -T` | valid config, `server_tokens off`, gzip, login rate limit, catch-all 444, immutable assets |

## 2. Runtime: measured, not configured

| Check | How | Target |
|---|---|---|
| Available memory | `/proc/meminfo` `MemAvailable` | >= 20% of RAM (WARN < 20%, FAIL < 10%) |
| Swap in use, `vm.swappiness` | `/proc/meminfo`, sysctl | <= 10% of swap, swappiness <= 10 |
| InnoDB buffer pool hit ratio | `Innodb_buffer_pool_reads` / `read_requests` | >= 99% (only judged after 100 000 reads) |
| Temp tables spilling to disk | `Created_tmp_disk_tables` / `Created_tmp_tables` | <= 25% |
| Slow queries | `Slow_queries` (> 1 s) | 0 since start |
| Redis evictions and hit rate | `INFO stats` | 0 evicted keys |
| Node restarts | `systemctl show NRestarts` | 0 (a crash or out-of-memory kill shows up here) |
| Response time (API `/up`, admin `/login`) | 20 requests after a warm-up, time to first byte, p50 / p95 / max | p95 <= 300 ms (guideline) |
| Compression, static asset caching | `Accept-Encoding: gzip`; `Cache-Control` on a hashed asset | gzip, `immutable` |
| Laravel release | files in `current/` | config and routes cached, no dev dependencies, optimised autoloader, `APP_DEBUG=false`, Redis cache and sessions, OPcache big enough for the file count |
| Load burst (`--load`) | 200 requests, 10 at a time, on the loopback | no failed request, memory still >= 10% free, req/s and p95 printed |

The response times are measured **from the server itself**, so they show what the
application and nginx cost, without the network. Because PHP-FPM runs `ondemand`, the
first request after idle is slower; the audit does one warm-up request first and so
reports the warm figure.

## 3. Hardening

* Only SSH, 80 and 443 listen on public addresses (every other public listener is a
  FAIL and is named with its process); databases and Redis must be loopback only.
* A firewall is running; fail2ban is active.
* SSH: root login and password login are reported (WARN when allowed).
* Permissions: Laravel `.env` <= 640, `/root/.my.cnf` <= 600, the CRM credentials file
  <= 600, the sudoers file validates, nothing world-writable under `/var/www`.
* Nightly backup job installed and the newest backup younger than 36 hours; disk and
  inode use under 80%.

## What this cannot tell you

* **OPcache hit rate and FPM queueing.** These are only visible from inside PHP-FPM
  (the PHP CLI has its own OPcache). Add a protected status endpoint if you need them.
* **What users experience.** Latency here excludes the network, TLS, the CDN and the
  browser. Measure the real path too:
  * from another machine: `hey -n 2000 -c 20 https://api.example.com/up`,
    `wrk`, or `k6` with your real endpoints (login, product list, checkout);
  * front end: Lighthouse / PageSpeed Insights on the admin and the storefront;
  * TLS and headers: SSL Labs, securityheaders.com.
* **Whether a slow query is slow.** Turn the slow query log (already on, > 1 s) into a
  weekly review: `mysqldumpslow "$(mysql -NBe 'SELECT @@slow_query_log_file')"`.
* **Deep security.** Use `lynis audit system` for a broader operating-system review and
  keep the OS updated. This audit only checks what PulseDeploy configures.

## Reading a result

Fix `FAIL` first. Then look at `WARN` lines with a number next to them:

| Line | What to do |
|---|---|
| buffer pool hit ratio < 99% | the data no longer fits the pool: add RAM, then raise `innodb_buffer_pool_size` |
| Redis keys evicted | raise `REDIS_MAXMEM_MB` or shorten cache TTLs |
| swap in use / low available memory | the machine is short of RAM; lower `pm.max_children`, or resize the server |
| p95 above the guideline | compare `pulse logs api` with the slow query log; on a cold `ondemand` pool the first request is slower by design |
| Node restarts > 0 | `journalctl -u pulse-next@admin`: a memory limit (raise the heap) or a crash |
| drift WARN | re-run `bootstrap.sh` to restore the target, or accept the change and ignore the line |

Run it after every install, after each `pulse-crm update`, and on a schedule
(`/etc/cron.d`, weekly, output to a log). To compare over time, keep the output files.
