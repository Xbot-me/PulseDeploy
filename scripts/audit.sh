#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - audit.sh: read-only audit of a deployed laravel-next server
#   sudo bash scripts/audit.sh             settings, measurements, hardening
#   sudo bash scripts/audit.sh --load      also a short load burst on the API
#
# It changes nothing. Every line is PASS / WARN / FAIL / INFO with the measured
# value next to the target, so the result is evidence, not an opinion:
#   1. drift    live settings compared with what the tuning calculates for this RAM
#   2. runtime  memory, swap, cache hit rates, restarts, response times
#   3. hardening listening ports, firewall, file permissions, Laravel release state
# Exit status is 1 when any FAIL was found. "Optimised" is always relative to a
# target: the targets used are printed, and thresholds are guidelines.
# =============================================================================
# shellcheck disable=SC2015  # pass/warnc/fail/note always succeed, so "A && pass || warnc" is safe here
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/profile_tuning.sh
source "$ROOT/scripts/lib/profile_tuning.sh"

LNX_ETC="${LNX_ETC:-/etc/pulsedeploy}"
APPS_ROOT="${APPS_ROOT:-/var/www}"
SAMPLES="${AUDIT_SAMPLES:-20}"
P95_LIMIT_MS="${AUDIT_P95_MS:-300}"
PASS=0; WARN=0; FAIL=0; SKIP=0
OPC_FILES=""

pass()  { PASS=$((PASS + 1)); printf '  %s %s\n' "${GREEN}PASS${RESET}" "$*"; }
warnc() { WARN=$((WARN + 1)); printf '  %s %s\n' "${YELLOW}WARN${RESET}" "$*"; }
fail()  { FAIL=$((FAIL + 1)); printf '  %s %s\n' "${RED}FAIL${RESET}" "$*"; }
note()  { printf '  %s %s\n' "INFO" "$*"; }
skip()  { SKIP=$((SKIP + 1)); printf '  %s %s\n' "SKIP" "$*"; }
head_() { printf '\n%s\n' "$*"; }

have() { command -v "$1" &>/dev/null; }

# ── pure helpers (unit-tested) ────────────────────────────────────────────────
# Value of KEY=VALUE from a file, without executing it.
conf_val() { # conf_val <file> <key>
  [[ -r "$1" ]] || return 1
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

# Last assignment of a key in an ini/cnf style file (spaces around = allowed).
ini_val() { # ini_val <file> <key>
  [[ -r "$1" ]] || return 1
  awk -F= -v k="$2" '{
    key = $1; gsub(/[ \t]/, "", key)
    if (key == k) { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); r = v }
  } END { print r }' "$1"
}

# Nearest-rank percentile of the numbers given: percentile <p> <n>...
percentile() {
  local p="$1"; shift
  [[ $# -gt 0 ]] || return 1
  printf '%s\n' "$@" | sort -n | awk -v p="$p" '
    { a[NR] = $1 }
    END { i = int((p * NR + 99) / 100); if (i < 1) i = 1; if (i > NR) i = NR; print a[i] }'
}

# "port process" for every TCP listener that is not bound to loopback (stdin = ss -tlnpH).
public_listeners_from() {
  awk '{
    a = $4; p = a; sub(/.*:/, "", p); h = a; sub(/:[^:]*$/, "", h)
    if (h ~ /^127\./ || h == "[::1]" || h ~ /^\[?::1\]?$/) next
    proc = ""
    if (match($0, /"[^"]+"/)) proc = substr($0, RSTART + 1, RLENGTH - 2)
    print p, proc
  }' | sort -u -k1,1n
}

kb_to_mb() { echo $(($1 / 1024)); }

# ── gathering ─────────────────────────────────────────────────────────────────
mysql_q() { mysql -NBe "$1" 2>/dev/null; }
redis_bin() { local b; for b in redis-cli redis6-cli redis7-cli; do have "$b" && { echo "$b"; return 0; }; done; return 1; }
first_file() { local f; for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done; return 1; }
rss_mb_of() { # rss_mb_of <process-name-regex>
  ps -eo rss=,comm= 2>/dev/null | awk -v re="$1" '$2 ~ re { s += $1 } END { printf "%d", s / 1024 }'
}
mem_total_mb() { awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo; }
mem_avail_mb() { awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo; }

drift() { # drift <label> <actual> <target> [unit]
  if [[ "$2" == "$3" ]]; then
    pass "$1: $2${4:-} (target $3${4:-})"
  else
    warnc "$1: $2${4:-}, but the tuning for this RAM is $3${4:-} (edited by hand, or not applied)"
  fi
}

# ── sections ──────────────────────────────────────────────────────────────────
audit_overview() {
  head_ "Server"
  RAM="$(mem_total_mb)"
  note "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown OS}"), $(nproc) CPU, ${RAM} MB RAM, kernel $(uname -r)"
  note "$(tune_summary "$RAM")"
  if [[ -r "$LNX_ETC/pulse.conf" ]]; then
    API_HOST="$(conf_val "$LNX_ETC/pulse.conf" API_HOST)"
    ADMIN_HOST="$(conf_val "$LNX_ETC/pulse.conf" ADMIN_HOST)"
    SHOP_HOST="$(conf_val "$LNX_ETC/pulse.conf" SHOP_HOST)"
    pass "PulseDeploy install found ($LNX_ETC/pulse.conf): api=$API_HOST admin=$ADMIN_HOST shop=$SHOP_HOST"
  else
    API_HOST=""; ADMIN_HOST=""; SHOP_HOST=""
    warnc "$LNX_ETC/pulse.conf not found: this does not look like a laravel-next server, host checks are skipped"
  fi
}

audit_php() {
  head_ "PHP-FPM and OPcache (settings)"
  local pool ini v
  if pool="$(first_file /etc/php-fpm.d/pulse-laravel.conf /etc/php/*/fpm/pool.d/pulse-laravel.conf)"; then
    v="$(ini_val "$pool" pm)";               [[ "$v" == "ondemand" ]] && pass "pool mode: ondemand (idle RAM stays near zero)" || warnc "pool mode: ${v:-unset}, expected ondemand"
    drift "pm.max_children" "$(ini_val "$pool" pm.max_children)" "$(tune_fpm_children "$RAM")"
    v="$(ini_val "$pool" pm.max_requests)";  [[ -n "$v" && "$v" -gt 0 ]] 2>/dev/null && pass "pm.max_requests=$v (workers recycle, leaks cannot accumulate)" || warnc "pm.max_requests unset: workers never recycle"
  else
    skip "PulseDeploy PHP-FPM pool file not found"
  fi
  if ini="$(first_file /etc/php.d/99-pulsedeploy.ini /etc/php/*/fpm/conf.d/99-pulsedeploy.ini)"; then
    [[ "$(ini_val "$ini" opcache.enable)" == "1" ]] && pass "opcache.enable=1" || fail "OPcache is not enabled"
    v="$(ini_val "$ini" opcache.validate_timestamps)"
    if [[ "$v" == "0" ]]; then
      pass "opcache.validate_timestamps=0 (no per-request file stat; deploys reload PHP-FPM)"
    else
      warnc "opcache.validate_timestamps=${v:-unset}: PHP re-checks files on a timer. Set PHP_OPCACHE_VALIDATE=0 for the fastest production mode"
    fi
    OPC_FILES="$(ini_val "$ini" opcache.max_accelerated_files)"
    note "opcache.memory_consumption=$(ini_val "$ini" opcache.memory_consumption)M  jit=$(ini_val "$ini" opcache.jit)  jit_buffer=$(ini_val "$ini" opcache.jit_buffer_size)  memory_limit=$(ini_val "$ini" memory_limit)"
    [[ "$(ini_val "$ini" expose_php)" =~ ^[Oo]ff$ ]] && pass "expose_php=Off" || warnc "expose_php is not Off"
  else
    skip "99-pulsedeploy.ini not found"
  fi
}

audit_db() {
  head_ "Database"
  if ! have mysql || ! mysql_q 'SELECT 1' >/dev/null; then skip "cannot query the database (run as root so /root/.my.cnf is used)"; return; fi
  local v bp reads reqs up
  note "server: $(mysql_q 'SELECT VERSION()')"
  v="$(mysql_q 'SELECT @@innodb_buffer_pool_size')"; bp=$((v / 1048576))
  drift "innodb_buffer_pool_size" "$bp" "$(tune_mysql_buffer_pool "$RAM")" "M"
  drift "max_connections" "$(mysql_q 'SELECT @@max_connections')" "$(tune_mysql_max_connections "$RAM")"
  [[ "$(mysql_q 'SELECT @@performance_schema')" == "0" ]] && pass "performance_schema off (saves 200+ MB)" || warnc "performance_schema is on"
  [[ "$(mysql_q 'SELECT @@innodb_flush_method')" == "O_DIRECT" ]] && pass "innodb_flush_method=O_DIRECT (no double caching)" || warnc "innodb_flush_method=$(mysql_q 'SELECT @@innodb_flush_method')"
  [[ "$(mysql_q 'SELECT @@skip_name_resolve')" == "1" ]] && pass "skip_name_resolve on" || warnc "skip_name_resolve off: every connection does a DNS lookup"
  head_ "Database (measured)"
  up="$(mysql_q "SHOW GLOBAL STATUS LIKE 'Uptime'" | awk '{print $2}')"
  reads="$(mysql_q "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_reads'" | awk '{print $2}')"
  reqs="$(mysql_q "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read_requests'" | awk '{print $2}')"
  if [[ "${reqs:-0}" -ge 100000 ]]; then
    v="$(awk -v r="$reads" -v q="$reqs" 'BEGIN { printf "%.2f", 100 - (r * 100 / q) }')"
    if awk -v v="$v" 'BEGIN { exit !(v >= 99) }'; then pass "buffer pool hit ratio ${v}% (target >= 99%, ${reqs} reads, uptime ${up}s)"; else warnc "buffer pool hit ratio ${v}% (target >= 99%): data does not fit the ${bp}M pool"; fi
  else
    note "buffer pool hit ratio: not enough traffic yet (${reqs:-0} read requests, need 100000)"
  fi
  local tmpd tmpt
  tmpd="$(mysql_q "SHOW GLOBAL STATUS LIKE 'Created_tmp_disk_tables'" | awk '{print $2}')"
  tmpt="$(mysql_q "SHOW GLOBAL STATUS LIKE 'Created_tmp_tables'" | awk '{print $2}')"
  if [[ "${tmpt:-0}" -ge 1000 ]]; then
    v="$(awk -v d="$tmpd" -v t="$tmpt" 'BEGIN { printf "%.1f", d * 100 / t }')"
    awk -v v="$v" 'BEGIN { exit !(v <= 25) }' && pass "temp tables spilling to disk: ${v}% (target <= 25%)" || warnc "temp tables spilling to disk: ${v}% (target <= 25%): raise tmp_table_size or fix the queries"
  fi
  v="$(mysql_q "SHOW GLOBAL STATUS LIKE 'Max_used_connections'" | awk '{print $2}')"
  note "peak connections used: ${v:-?} of $(mysql_q 'SELECT @@max_connections')"
  v="$(mysql_q "SHOW GLOBAL STATUS LIKE 'Slow_queries'" | awk '{print $2}')"
  [[ "${v:-0}" -eq 0 ]] && pass "no slow queries (> 1 s) logged since start" || warnc "${v} slow queries logged: see the slow query log"
}

audit_redis() {
  head_ "Redis"
  local cli v mem maxb hits misses
  if ! cli="$(redis_bin)" || [[ "$("$cli" ping 2>/dev/null)" != "PONG" ]]; then skip "Redis not installed or not answering"; return; fi
  maxb="$("$cli" config get maxmemory 2>/dev/null | tail -n 1)"
  drift "maxmemory" "$((maxb / 1048576))" "$(tune_redis_mem "$RAM")" "M"
  v="$("$cli" config get maxmemory-policy 2>/dev/null | tail -n 1)"
  [[ "$v" == "allkeys-lru" ]] && pass "eviction policy allkeys-lru" || warnc "eviction policy $v"
  v="$("$cli" config get bind 2>/dev/null | tail -n 1)"
  [[ "$v" == 127.0.0.1* || "$v" == "localhost"* ]] && pass "bound to loopback ($v)" || fail "Redis bind is '$v': it must not listen on a public address"
  mem="$("$cli" info memory 2>/dev/null | awk -F: '/^used_memory:/ { gsub(/\r/, ""); printf "%d", $2 / 1048576 }')"
  note "memory used: ${mem}M of $((maxb / 1048576))M"
  v="$("$cli" info stats 2>/dev/null | awk -F: '/^evicted_keys:/ { gsub(/\r/, ""); print $2 }')"
  [[ "${v:-0}" -eq 0 ]] && pass "no keys evicted (the cache is big enough)" || warnc "${v} keys evicted: the cache is full, raise REDIS_MAXMEM_MB or shorten TTLs"
  hits="$("$cli" info stats 2>/dev/null | awk -F: '/^keyspace_hits:/ { gsub(/\r/, ""); print $2 }')"
  misses="$("$cli" info stats 2>/dev/null | awk -F: '/^keyspace_misses:/ { gsub(/\r/, ""); print $2 }')"
  if [[ "$((${hits:-0} + ${misses:-0}))" -ge 1000 ]]; then
    note "cache hit rate: $(awk -v h="$hits" -v m="$misses" 'BEGIN { printf "%.1f", h * 100 / (h + m) }')% (${hits} hits, ${misses} misses)"
  fi
}

audit_node() {
  head_ "Next.js apps"
  local app env heap unit mm restarts state
  for app in admin shop; do
    unit="pulse-next@${app}"
    if ! have systemctl || ! systemctl cat "$unit" &>/dev/null; then skip "$unit not installed"; continue; fi
    state="$(systemctl is-active "$unit" 2>/dev/null)"
    if [[ "$state" == "active" ]]; then
      pass "$unit active"
    else
      [[ "$app" == "shop" && ! -e "$APPS_ROOT/shop/current/server.js" ]] && note "$unit: no storefront deployed" || fail "$unit is $state"
    fi
    env="$LNX_ETC/$app.env"
    heap="$(conf_val "$env" NODE_OPTIONS | sed -n 's/.*max-old-space-size=\([0-9]*\).*/\1/p')"
    drift "$app node heap (--max-old-space-size)" "${heap:-unset}" "$(tune_node_heap "$RAM" "$app")" "M"
    mm="$(systemctl show -p MemoryMax --value "$unit" 2>/dev/null)"
    if [[ "$mm" =~ ^[0-9]+$ ]]; then
      drift "$app MemoryMax" "$((mm / 1048576))" "$(tune_node_memory_max "$RAM" "$app")" "M"
    else
      warnc "$app has no MemoryMax: a runaway process could take the whole machine"
    fi
    restarts="$(systemctl show -p NRestarts --value "$unit" 2>/dev/null)"
    [[ "${restarts:-0}" -eq 0 ]] && pass "$app: 0 restarts since it started" || warnc "$app restarted ${restarts} times: check 'journalctl -u $unit' (crash or out of memory)"
  done
}

audit_nginx() {
  head_ "nginx"
  if ! have nginx; then skip "nginx not installed"; return; fi
  local dump v
  nginx -t &>/dev/null && pass "nginx -t: configuration valid" || fail "nginx -t reports an error"
  dump="$(nginx -T 2>/dev/null || true)"
  [[ "$dump" == *"server_tokens off"* ]] && pass "server_tokens off (no version in headers)" || warnc "server_tokens is not off"
  [[ "$dump" == *"gzip on"* ]] && pass "gzip on" || warnc "gzip is off: JSON and JS are sent uncompressed"
  [[ "$dump" == *"limit_req_zone"* ]] && pass "login rate limiting configured" || warnc "no limit_req_zone: login endpoints are not rate limited"
  [[ "$dump" == *"return 444"* ]] && pass "unknown host names get no answer (444)" || warnc "no catch-all server block for unknown hosts"
  [[ "$dump" == *"immutable"* ]] && pass "hashed build assets are cached forever (immutable)" || warnc "no immutable cache header for build assets"
  v="$(awk '/^[ \t]*worker_processes/ { gsub(/;/, ""); print $2; exit }' <<<"$dump")"
  note "worker_processes ${v:-default}; $(nproc) CPU"
}

audit_memory() {
  head_ "Memory and swap (right now)"
  local avail swap_t swap_u pct nginx_m php_m db_m redis_m node_m workers v_sw
  avail="$(mem_avail_mb)"
  pct=$((avail * 100 / RAM))
  if [[ "$pct" -ge 20 ]]; then pass "available memory ${avail} MB (${pct}% of ${RAM} MB, target >= 20%)"; elif [[ "$pct" -ge 10 ]]; then warnc "available memory ${avail} MB (${pct}%): under 20% headroom"; else fail "available memory ${avail} MB (${pct}%): the server is about to swap or kill processes"; fi
  swap_t="$(awk '/^SwapTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)"
  swap_u="$(awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { printf "%d", (t - f) / 1024 }' /proc/meminfo)"
  if [[ "$swap_t" -eq 0 ]]; then
    warnc "no swap configured: one memory spike can trigger the OOM killer"
  elif [[ "$swap_u" -le $((swap_t / 10)) ]]; then
    pass "swap in use ${swap_u} MB of ${swap_t} MB (target <= 10%)"
  else
    warnc "swap in use ${swap_u} MB of ${swap_t} MB: the machine is short of RAM"
  fi
  v_sw="$(sysctl -n vm.swappiness 2>/dev/null)"; [[ "$v_sw" =~ ^[0-9]+$ && "$v_sw" -le 10 ]] && pass "vm.swappiness=$v_sw" || warnc "vm.swappiness=${v_sw:-?} (server workloads want <= 10)"
  nginx_m="$(rss_mb_of '^nginx$')"; php_m="$(rss_mb_of '^php-fpm')"; db_m="$(rss_mb_of '^(mysqld|mariadbd)$')"
  redis_m="$(rss_mb_of '^redis')"; node_m="$(rss_mb_of '^(node|MainThread)$')"
  note "resident memory: php-fpm ${php_m} MB, database ${db_m} MB, node ${node_m} MB, redis ${redis_m} MB, nginx ${nginx_m} MB"
  workers="$(pgrep -f 'php-fpm: pool pulse-laravel' 2>/dev/null | wc -l)"
  note "php-fpm workers running: ${workers} (ondemand: 0 when idle)"
}

audit_laravel() {
  head_ "Laravel release"
  local cur="$APPS_ROOT/api/current" env="$APPS_ROOT/api/shared/.env" v
  if [[ ! -d "$cur" ]]; then skip "no API release at $cur"; return; fi
  note "release: $(basename "$(readlink -f "$cur")")"
  [[ -f "$cur/bootstrap/cache/config.php" ]] && pass "config cached" || warnc "config is not cached (php artisan config:cache)"
  compgen -G "$cur/bootstrap/cache/routes-*.php" >/dev/null && pass "routes cached" || warnc "routes are not cached (php artisan route:cache)"
  compgen -G "$cur/storage/framework/views/*.php" >/dev/null && pass "views compiled" || note "no compiled views yet"
  if [[ "${OPC_FILES:-}" =~ ^[0-9]+$ ]]; then
    local nfiles
    nfiles="$(find -L "$cur" -name '*.php' -type f 2>/dev/null | wc -l)"
    if [[ "$nfiles" -le $((OPC_FILES * 80 / 100)) ]]; then
      pass "release has ${nfiles} PHP files; OPcache can hold ${OPC_FILES} (target: stay under 80%)"
    else
      warnc "release has ${nfiles} PHP files but opcache.max_accelerated_files is ${OPC_FILES}: a full OPcache slows every request"
    fi
  fi
  [[ -d "$cur/vendor/phpunit" || -d "$cur/vendor/fakerphp" ]] && warnc "dev dependencies are installed in production (composer install --no-dev)" || pass "no dev dependencies in vendor/"
  [[ -f "$cur/vendor/composer/autoload_classmap.php" && "$(wc -l <"$cur/vendor/composer/autoload_classmap.php")" -gt 50 ]] && pass "composer autoloader is optimised (class map)" || warnc "composer autoloader is not optimised (composer install --optimize-autoloader)"
  if [[ -r "$env" ]]; then
    v="$(conf_val "$env" APP_DEBUG)";  [[ "$v" == "false" ]] && pass "APP_DEBUG=false" || fail "APP_DEBUG=${v:-unset}: debug output must be off in production"
    v="$(conf_val "$env" APP_ENV)";    [[ "$v" == "production" ]] && pass "APP_ENV=production" || warnc "APP_ENV=${v:-unset}"
    v="$(conf_val "$env" CACHE_STORE)"; [[ "$v" == "redis" ]] && pass "cache store: redis" || warnc "cache store: ${v:-unset}"
    v="$(conf_val "$env" SESSION_DRIVER)"; [[ "$v" == "redis" ]] && pass "session driver: redis" || warnc "session driver: ${v:-unset}"
  fi
}

# ── measurements ──────────────────────────────────────────────────────────────
time_ms() { # time_ms <host> <path> <count>  → one line per answered request, milliseconds
  local host="$1" path="$2" n="$3" i t
  for ((i = 0; i < n; i++)); do
    t="$(curl -s -o /dev/null -m 15 -w '%{time_starttransfer}' -H "Host: $host" "http://127.0.0.1$path" 2>/dev/null)" || t=""
    [[ "$t" =~ ^[0-9.]+$ ]] && awk -v t="$t" 'BEGIN { printf "%d\n", t * 1000 + 0.5 }'
  done
}

http_status() { curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $1" "http://127.0.0.1$2" 2>/dev/null || echo 000; }

audit_response() {
  head_ "Response times (from this machine, ${SAMPLES} requests after a warm-up, time to first byte)"
  local name host path code times p50 p95 pmax
  local -a ms
  for target in "API|$API_HOST|/up" "admin|$ADMIN_HOST|/login"; do
    IFS='|' read -r name host path <<<"$target"
    [[ -n "$host" ]] || { skip "$name: no host configured"; continue; }
    code="$(http_status "$host" "$path")"
    if [[ ! "$code" =~ ^[23][0-9][0-9]$ ]]; then fail "$name ${host}${path}: HTTP $code"; continue; fi
    http_status "$host" "$path" >/dev/null # warm-up (ondemand workers start here)
    times="$(time_ms "$host" "$path" "$SAMPLES")"
    mapfile -t ms <<<"$times"
    [[ "${#ms[@]}" -gt 0 && -n "${ms[0]}" ]] || { fail "$name: no timing samples"; continue; }
    p50="$(percentile 50 "${ms[@]}")"; p95="$(percentile 95 "${ms[@]}")"; pmax="$(percentile 100 "${ms[@]}")"
    if [[ "$p95" -le "$P95_LIMIT_MS" ]]; then
      pass "$name ${path}: p50 ${p50} ms, p95 ${p95} ms, max ${pmax} ms (guideline p95 <= ${P95_LIMIT_MS} ms)"
    else
      warnc "$name ${path}: p50 ${p50} ms, p95 ${p95} ms, max ${pmax} ms (guideline p95 <= ${P95_LIMIT_MS} ms)"
    fi
  done
  if [[ -n "$ADMIN_HOST" ]]; then
    local enc
    enc="$(curl -s -o /dev/null -D - -m 10 -H 'Accept-Encoding: gzip' -H "Host: $ADMIN_HOST" "http://127.0.0.1/login" 2>/dev/null | tr -d '\r')"
    if grep -qi '^content-encoding: *\(gzip\|br\)' <<<"$enc"; then pass "admin pages are compressed (Content-Encoding)"; else warnc "admin pages are not compressed"; fi
    local asset
    asset="$(find "$APPS_ROOT/admin/current/.next/static" -type f -name '*.js' 2>/dev/null | head -n 1)" || asset=""
    if [[ -n "$asset" ]]; then
      local url="/_next/static/${asset#*/.next/static/}" cc
      cc="$(curl -s -o /dev/null -D - -m 10 -H "Host: $ADMIN_HOST" "http://127.0.0.1$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "cache-control:" { print; exit }')"
      [[ "$cc" == *immutable* ]] && pass "static assets: ${cc}" || warnc "static assets are not served as immutable (${cc:-no Cache-Control header})"
    fi
  fi
}

audit_load() {
  head_ "Load burst (200 requests, 10 at a time, API /up on this machine)"
  [[ -n "$API_HOST" ]] || { skip "no API host"; return; }
  local before after out total bad p95 secs start end
  before="$(mem_avail_mb)"
  start="$(date +%s.%N)"
  out="$(seq 200 | xargs -P 10 -I{} curl -s -o /dev/null -m 30 -w '%{http_code} %{time_total}\n' \
    -H "Host: $API_HOST" "http://127.0.0.1/up" 2>/dev/null)"
  end="$(date +%s.%N)"
  after="$(mem_avail_mb)"
  total="$(wc -l <<<"$out")"
  bad="$(awk '$1 !~ /^[23]/ { n++ } END { print n + 0 }' <<<"$out")"
  p95="$(awk '{ printf "%d\n", $2 * 1000 }' <<<"$out" | sort -n | awk '{ a[NR] = $1 } END { i = int((95 * NR + 99) / 100); print a[i] }')"
  secs="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')"
  note "$(awk -v n="$total" -v s="$secs" 'BEGIN { printf "%d requests in %s s = %.0f req/s", n, s, n / s }'), p95 ${p95} ms"
  [[ "$bad" -eq 0 ]] && pass "no failed requests (all 2xx/3xx)" || fail "${bad} of ${total} requests failed"
  note "available memory: ${before} MB before, ${after} MB after"
  [[ "$after" -ge $((RAM * 10 / 100)) ]] && pass "memory held up under load" || fail "available memory fell to ${after} MB under load"
}

audit_security() {
  head_ "Hardening"
  local lines port proc extra=0 sshp
  sshp="22"
  if have sshd; then sshp="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"; sshp="${sshp:-22}"; fi
  lines="$(ss -tlnpH 2>/dev/null | public_listeners_from)"
  while read -r port proc; do
    [[ -n "$port" ]] || continue
    if [[ "$port" == "80" || "$port" == "443" || "$port" == "$sshp" ]]; then
      note "public listener: ${port} (${proc:-?})"
    else
      extra=1; fail "port ${port} (${proc:-?}) is reachable from outside: only ${sshp}, 80 and 443 should be"
    fi
  done <<<"$lines"
  [[ "$extra" -eq 0 ]] && pass "only SSH, HTTP and HTTPS listen on public addresses"
  if have firewall-cmd; then
    [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]] && pass "firewalld running" || fail "firewalld is not running"
  elif have ufw; then
    ufw status 2>/dev/null | grep -q 'Status: active' && pass "ufw active" || fail "ufw is not active"
  else
    fail "no firewall (firewalld/ufw) found"
  fi
  if have fail2ban-client; then systemctl is-active --quiet fail2ban 2>/dev/null && pass "fail2ban active" || warnc "fail2ban installed but not running"; else warnc "fail2ban not installed"; fi
  if have sshd; then
    local cfg; cfg="$(sshd -T 2>/dev/null)"
    [[ "$cfg" == *"permitrootlogin no"* ]] && pass "SSH root login disabled" || warnc "SSH root login is allowed (PermitRootLogin)"
    [[ "$cfg" == *"passwordauthentication no"* ]] && pass "SSH password login disabled (keys only)" || warnc "SSH accepts passwords: use keys and set PasswordAuthentication no"
  fi
  perm_check "$APPS_ROOT/api/shared/.env" 640 "Laravel .env"
  perm_check /root/.my.cnf 600 "/root/.my.cnf"
  perm_check /root/pulsedeploy-crm-credentials.txt 600 "CRM credentials file"
  if have visudo && [[ -f /etc/sudoers.d/pulsedeploy ]]; then
    visudo -cf /etc/sudoers.d/pulsedeploy &>/dev/null && pass "sudoers rules for the deploy user are valid" || fail "sudoers file is invalid"
  fi
  local ww
  ww="$(find "$APPS_ROOT" -xdev -type f -perm -0002 2>/dev/null | wc -l)"
  [[ "$ww" -eq 0 ]] && pass "no world-writable files under $APPS_ROOT" || warnc "${ww} world-writable files under $APPS_ROOT"
  have getenforce && note "SELinux: $(getenforce 2>/dev/null)"
}

perm_check() { # perm_check <file> <max-octal> <label>
  [[ -e "$1" ]] || return 0
  local mode; mode="$(stat -c '%a' "$1")"
  if [[ "$((8#$mode & ~8#$2))" -eq 0 ]]; then pass "$3 permissions $mode (limit $2)"; else fail "$3 permissions $mode are wider than $2"; fi
}

audit_ops() {
  head_ "Backups and disk"
  local dir="/var/backups/pulsedeploy" newest age use ino
  if [[ -f /etc/cron.d/pulsedeploy-backup ]]; then pass "nightly backup job installed"; else warnc "no nightly backup job (/etc/cron.d/pulsedeploy-backup)"; fi
  if [[ -d "$dir" ]]; then
    newest="$(find "$dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1)"
    if [[ -n "$newest" ]]; then
      age=$(($(date +%s) - ${newest%%.*}))
      [[ "$age" -le 129600 ]] && pass "newest backup is $((age / 3600)) h old" || warnc "newest backup is $((age / 3600)) h old (should be < 36 h)"
    else
      warnc "no backup files in $dir yet (run: sudo pulse backup)"
    fi
  fi
  use="$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
  [[ "$use" -lt 80 ]] && pass "root disk ${use}% used (target < 80%)" || warnc "root disk ${use}% used"
  ino="$(df -Pi / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
  [[ "$ino" =~ ^[0-9]+$ && "$ino" -lt 80 ]] && pass "inodes ${ino}% used" || note "inode use ${ino:-unknown}"
}

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/audit.sh [--load] [--no-perf]
  --load      also run a 200-request burst against the API (loopback, read-only)
  --no-perf   skip the response-time section
Environment: AUDIT_SAMPLES (default 20), AUDIT_P95_MS (default 300)
EOF
}

main() {
  local load=0 perf=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --load) load=1 ;;
      --no-perf) perf=0 ;;
      -h | --help) usage; return 0 ;;
      *) echo "Unknown option: $1" >&2; usage >&2; return 2 ;;
    esac
    shift
  done
  [[ "$(id -u)" -eq 0 ]] || echo "Note: run as root for complete results (database, sockets, sshd, sudoers)."
  audit_overview
  audit_php
  audit_db
  audit_redis
  audit_node
  audit_nginx
  audit_memory
  audit_laravel
  [[ "$perf" -eq 1 ]] && audit_response
  [[ "$load" -eq 1 ]] && audit_load
  audit_security
  audit_ops
  printf '\nResult: %d pass, %d warn, %d fail, %d skipped\n' "$PASS" "$WARN" "$FAIL" "$SKIP"
  printf 'PASS = matches the target, WARN = worth a look, FAIL = fix it, SKIP = not installed here.\n'
  [[ "$FAIL" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
