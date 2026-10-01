# Auditing a deployed server

```bash
sudo pulse-crm audit            # on a server installed with crm.sh
sudo bash scripts/audit.sh      # from a checkout of this repository
sudo bash scripts/audit.sh --load      # plus a burst against the API (memory, CPU, latency)
sudo bash scripts/audit.sh --no-perf   # skip the response-time section
sudo pulse-crm retune                  # apply hand-tuned values (see "Fine-tuning from measurements")
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
| Load burst (`--load`) | configurable requests and concurrency on the loopback; endpoint and auth via `--load-path`, `--headers-file` | no 5xx, memory still >= 10% free; prints req/s, p50/p95/p99, CPU busy / disk wait / steal, and the measured PHP worker size |
| Kernel and limits | sysctl, `/sys`, systemd, Redis log | transparent hugepages `madvise`/`never`, `vm.overcommit_memory=1`, `somaxconn` >= 1024, no Redis warnings |

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

## Fine-tuning from measurements

Settings tuned on guesses are wrong half the time, so tune in this loop: **measure a
realistic load, change one thing, measure again**.

### 1. A realistic load (the health check is not one)

`/up` only proves PHP answers. Use real endpoints with a real login. This writes the
request headers to a root-only file (the password and token never appear in a command
line or in `ps`):

```bash
sudo bash -c '
API=$(awk -F= "/^API_HOST=/ {print \$2}" /etc/pulsedeploy/pulse.conf)
STORE=$(awk -F= "/^STORE=/ {print \$2}" /etc/pulsedeploy/crm.conf)
EMAIL=$(awk "/^email:/ {print \$2}" /root/pulsedeploy-crm-credentials.txt)
PASS=$(awk "/^password:/ {print \$2}" /root/pulsedeploy-crm-credentials.txt)
TOKEN=$(curl -s -H "Host: $API" -H "X-Store-Subdomain: $STORE" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" http://127.0.0.1/api/v1/admin/login \
  | sed -n "s/.*\"token\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
install -m 600 /dev/null /root/load-headers
printf "X-Store-Subdomain: %s\nAuthorization: Bearer %s\n" "$STORE" "$TOKEN" >/root/load-headers
echo "token length: ${#TOKEN}"'
```

The token length should be about 40. Then hit endpoints that cost something (authentication
and tenant resolution, a list query):

```bash
sudo bash scripts/audit.sh --no-perf --load --load-path /api/v1/admin/me     --headers-file /root/load-headers
sudo bash scripts/audit.sh --no-perf --load --load-path /api/v1/admin/orders --headers-file /root/load-headers \
     --requests 500 --concurrency 20
```

If the burst reports refused (4xx) responses the numbers measure error pages, not your app.
Add data first (import or create realistic rows): an empty database is always fast.

### 2. What the burst tells you

| Line | Meaning | Action |
|---|---|---|
| `PHP workers ... about N MB each` | **measured** memory of one worker (PSS, shared OPcache split fairly); the default sizing assumes 60 MB | use N when sizing `FPM_CHILDREN` |
| `memory left for PHP ... up to K workers` | RAM minus database, Redis, both Node limits and the OS, divided by N | `FPM_CHILDREN` up to K |
| `every PHP worker was busy at once` | requests queued behind `pm.max_children` | raise it if memory allows; otherwise make the endpoint faster |
| `CPU ... steal > 5%` | the host is oversubscribed or out of CPU credits | no setting helps: change instance type |
| `disk wait > 10%` | storage is the bottleneck (slow volume, database reading from disk) | faster volume, bigger buffer pool, or an index |
| `CPU saturated` | more workers cannot help | faster code, caching, or more CPU |
| p95 much larger than p50 | queueing or cold `ondemand` workers | raise the workers, or use `pm = dynamic` with spare servers if cold starts matter |

### 3. Keep a tuned value: `/etc/pulsedeploy/tuning.conf`

```
# only these keys are read; values must be positive whole numbers
FPM_CHILDREN=16
MYSQL_BUFFER_POOL_MB=1024
MYSQL_MAX_CONNECTIONS=80
REDIS_MAXMEM_MB=300
NODE_HEAP_ADMIN=320
NODE_HEAP_SHOP=384
```

Anything not listed keeps the RAM-based value. The installer reads this file on every run
(so a re-run no longer resets your numbers) and `audit.sh` treats these values as the target.
Apply them to the running server without re-provisioning:

```bash
sudo pulse-crm retune                 # shows what would change, changes nothing
sudo pulse-crm retune --apply         # applies it
sudo pulse-crm retune --apply --worker-mb 38     # check the memory plan with your measured worker size
```

`retune` changes only these numbers: PHP-FPM is config-tested then reloaded (no dropped
requests), the database pool and Redis limit are changed live with no restart, and each
Node app restarts for about a second. A plan that does not fit in RAM is refused unless
`--force` is given. Afterwards run `audit.sh` again and compare.

### 4. Count what one request really costs

When the CPU is saturated, the cost of a single request is the whole story. This counts the
database statements and writes that one authenticated API call causes:

```bash
sudo bash -c '
q() { mysql -NBe "SHOW GLOBAL STATUS LIKE \"$1\"" | awk "{print \$2}"; }
API=$(awk -F= "/^API_HOST=/ {print \$2}" /etc/pulsedeploy/pulse.conf)
a=$(q Questions); u=$(q Com_update); i=$(q Com_insert); c=$(q Connections)
curl -s -o /dev/null -H "Host: $API" -H @/root/load-headers http://127.0.0.1/api/v1/admin/me
echo "statements: $(( $(q Questions) - a - 1 ))  updates: $(( $(q Com_update) - u ))  inserts: $(( $(q Com_insert) - i ))  new connections: $(( $(q Connections) - c - 3 ))"'
```

(The `- 1` and `- 3` remove the status queries themselves.) A read-only request that causes
an UPDATE, or a dozen statements, is the place to optimise: cache what does not change per
request, and avoid writes on reads.

### 5. Where the real gains usually are

Server settings rarely matter as much as these, so check them before tuning further:

1. **Slow queries and missing indexes.** `mysqldumpslow` on the slow log, then `EXPLAIN` the
   worst ones; an index turns a 500 ms query into 1 ms. `Innodb_buffer_pool_reads` growing
   means the data does not fit the pool.
2. **N+1 queries and uncached lists in the application** (eager-load relations, cache
   expensive queries in Redis). The audit cannot see these; Laravel Telescope or Debugbar
   on a staging copy can.
3. **Persistent workers.** Laravel Octane (FrankenPHP or Swoole) removes the framework boot on
   every request and often multiplies throughput, at the cost of keeping workers in RAM and
   requiring code that is safe to keep in memory. Worth trying only after the two points above.
4. **A CDN in front** for images and build assets (`--cloudflare` is supported).
5. **More RAM or CPU.** If the burst shows saturated CPU or no memory left for workers, no
   setting will change that.

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
