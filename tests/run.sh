#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - unit tests for the shared helpers and the CLI surface.
# Needs no root, no network and changes nothing on the machine.
#   bash tests/run.sh
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
check() { # check "name" <command...>   - passes when the command succeeds
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
check_not() { # passes when the command FAILS
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$name (expected failure)"; else ok "$name"; fi
}
eq() { # eq "name" expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

echo "── conf_set"
f="$TMP/redis.conf"
cat >"$f" <<'CONF'
bind 127.0.0.1 -::1
# maxmemory <bytes>
# maxmemory-policy noeviction
appendonly yes
CONF
conf_set "$f" maxmemory "256mb"
conf_set "$f" maxmemory-policy "allkeys-lru"
conf_set "$f" bind "127.0.0.1"
conf_set "$f" appendonly "no"
conf_set "$f" protected-mode "yes"
eq "replaces active line"              "bind 127.0.0.1"      "$(grep '^bind' "$f")"
eq "comment example: value inserted"   "maxmemory 256mb"     "$(grep '^maxmemory ' "$f")"
eq "prefix key not confused"           "maxmemory-policy allkeys-lru" "$(grep '^maxmemory-policy' "$f")"
eq "comment line preserved"            "1"                   "$(grep -c '^# maxmemory <bytes>' "$f")"
eq "appends when absent"               "protected-mode yes"  "$(tail -n 1 "$f")"
before="$(cat "$f")"
conf_set "$f" maxmemory "256mb"; conf_set "$f" appendonly "no"
eq "idempotent"                        "$before"             "$(cat "$f")"

f="$TMP/www.conf"
printf '[www]\npm = ondemand\npm.max_children = 5\n;pm.max_requests = 500\n' >"$f"
conf_set "$f" pm dynamic " = "
conf_set "$f" pm.max_children 40 " = "
conf_set "$f" pm.max_requests 700 " = "
eq "ini: 'pm' does not touch pm.max_children" "pm = dynamic"        "$(grep '^pm ' "$f")"
eq "ini: max_children replaced"                "pm.max_children = 40" "$(grep '^pm.max_children' "$f")"
eq "ini: commented option activated"           "pm.max_requests = 700" "$(grep '^pm.max_requests' "$f")"

f="$TMP/special.conf"; : >"$f"
# shellcheck disable=SC2016  # literal dollar sign is the point of this test
conf_set "$f" path 'a|b&c\d $HOME' " = "
# shellcheck disable=SC2016
eq "special characters kept literally" 'path = a|b&c\d $HOME' "$(cat "$f")"
check_not "missing file returns failure" conf_set "$TMP/nope" a b

echo "── validators"
check     "port 22"            valid_port 22
check     "port 65535"         valid_port 65535
check_not "port 0"             valid_port 0
check_not "port 65536"         valid_port 65536
check_not "port abc"           valid_port abc
check     "domain"             valid_domain example.com
check     "subdomain"          valid_domain a.b-c.example.co.uk
check_not "domain no tld"      valid_domain localhost
check_not "domain injection"   valid_domain 'a.com;rm -rf /'
check     "email"              valid_email admin@example.com
check_not "email no @"         valid_email admin.example.com
check     "swap 2G"            valid_swap_size 2G
check     "swap 512m"          valid_swap_size 512m
check_not "swap 0G"            valid_swap_size 0G
check_not "swap 2GB"           valid_swap_size 2GB
check     "db name"            valid_db_name my_app1
check_not "db name quote"      valid_db_name "a'b"
check_not "db user too long"   valid_db_user "$(printf 'u%.0s' {1..33})"
check     "hostname"           valid_hostname web-01
check_not "hostname space"     valid_hostname "web 01"
check     "timezone UTC"       valid_timezone UTC
check_not "timezone traversal" valid_timezone ../../etc/passwd

echo "── generate_password (under pipefail, as bootstrap runs it)"
if ( set -Eeuo pipefail; p="$(generate_password 24)"; [[ ${#p} -eq 24 && "$p" =~ ^[A-Za-z0-9]+$ ]] ); then
  ok "24 alphanumeric chars, exit status 0"
else
  bad "generate_password failed under pipefail"
fi
p1="$(generate_password 24)"; p2="$(generate_password 24)"
if [[ "$p1" != "$p2" ]]; then ok "passwords differ"; else bad "passwords identical"; fi

echo "── ssh_ports"
port_list="$(SSH_PORT=2222 ssh_ports | tr '\n' ' ')"
if [[ "$port_list" == *"2222"* ]]; then ok "includes --ssh-port"; else bad "ssh_ports missing 2222" "$port_list"; fi
if [[ "$(ssh_ports | wc -l)" -ge 1 ]]; then ok "never empty"; else bad "ssh_ports empty"; fi

echo "── nginx default-server removal (RHEL nginx.conf)"
if (
  # shellcheck source=scripts/lib/web.sh
  source "$ROOT/scripts/lib/web.sh"
  # shellcheck disable=SC2030,SC2031  # the subshell keeps this override local
  PKG_MANAGER=dnf
  export NGINX_ROOT="$TMP/nginx"; NGINX_ROOT="$TMP/nginx"
  mkdir -p "$NGINX_ROOT"
  cp "$ROOT/tests/fixtures/nginx-el8.conf" "$NGINX_ROOT/nginx.conf"
  nginx_disable_defaults >/dev/null
  conf="$NGINX_ROOT/nginx.conf"
  active_servers="$(grep -Ec '^[[:space:]]*server[[:space:]]*\{' "$conf")"
  [[ "$active_servers" -eq 0 ]] || { echo "server block still present"; exit 1; }
  # braces must still balance and the rest of the file must survive
  [[ "$(tr -cd '{' <"$conf" | wc -c)" -eq "$(tr -cd '}' <"$conf" | wc -c)" ]] || { echo "unbalanced braces"; exit 1; }
  grep -q 'include /etc/nginx/conf.d/\*.conf;' "$conf" || { echo "conf.d include lost"; exit 1; }
  grep -q 'worker_connections 1024;' "$conf" || { echo "events block lost"; exit 1; }
  grep -q '^#    server {' "$conf" || { echo "commented TLS example lost"; exit 1; }
  [[ -f "$conf.pulsedeploy.bak" ]] || { echo "no backup"; exit 1; }
); then
  ok "stock server{} removed, rest intact, balanced, backup kept"
else
  bad "nginx.conf server-block stripping"
fi

echo "── profile tuning"
# shellcheck source=scripts/lib/profile_tuning.sh
source "$ROOT/scripts/lib/profile_tuning.sh"
eq "fpm children 2GB"            "6"    "$(tune_fpm_children 2048)"
eq "fpm children 4GB"            "13"   "$(tune_fpm_children 4096)"
eq "fpm children floor"          "4"    "$(tune_fpm_children 512)"
eq "fpm children cap"            "40"   "$(tune_fpm_children 65536)"
eq "buffer pool 1GB box"         "128"  "$(tune_mysql_buffer_pool 1024)"
eq "buffer pool 2GB (chunk 128)" "384"  "$(tune_mysql_buffer_pool 2048)"
eq "buffer pool 4GB"             "768"  "$(tune_mysql_buffer_pool 4096)"
eq "buffer pool 8GB (whole GB)"  "1024" "$(tune_mysql_buffer_pool 8192)"
eq "buffer pool 16GB"            "2048" "$(tune_mysql_buffer_pool 16384)"
eq "redis 2GB"                   "122"  "$(tune_redis_mem 2048)"
eq "redis floor"                 "64"   "$(tune_redis_mem 512)"
eq "redis cap"                   "512"  "$(tune_redis_mem 65536)"
eq "node heap admin 2GB"         "256"  "$(tune_node_heap 2048 admin)"
eq "node heap shop 4GB"          "384"  "$(tune_node_heap 4096 shop)"
eq "node memory max"             "576"  "$(tune_node_memory_max 4096 shop)"
total=0
for r in 2048 4096 8192; do   # 2GB is the supported minimum
  total=$(( $(tune_mysql_buffer_pool "$r") + $(tune_redis_mem "$r") + $(tune_node_heap "$r" admin) + $(tune_node_heap "$r" shop) ))
  if (( total * 100 / r <= 60 )); then ok "fixed memory under 60% of RAM at ${r}MB (${total}MB)"; else bad "memory budget too high at ${r}MB" "${total}MB"; fi
done

echo "── laravel-next templates"
(
  source "$ROOT/scripts/stacks/laravel_next.sh" >/dev/null 2>&1
  out="$TMP/render.out"
  lnx_render "$ROOT/config/laravel-next/nginx-api.conf" "$out" "HOST=api.example.com" "ROOT=/var/www/api/current/public" "PHP_SOCK=/run/php/x&y.sock"
  grep -q 'server_name api.example.com;' "$out" || exit 1
  grep -q 'unix:/run/php/x&y.sock;' "$out" || exit 2          # '&' must stay literal
  grep -q '@[A-Z_]*@' "$out" && exit 3                        # no unreplaced markers
  lnx_render "$ROOT/config/laravel-next/nginx-next.conf" "$out" "NAME=shop" "PORT=3000" "SERVER_NAMES=example.com"
  sed -i -e 's/^#shop# //' -e '/^#admin# /d' "$out"
  grep -q 'proxy_cache pulse_shop;' "$out" || exit 4
  grep -q 'X-Robots-Tag' "$out" && exit 5
  lnx_render "$ROOT/config/laravel-next/nginx-next.conf" "$out" "NAME=admin" "PORT=3001" "SERVER_NAMES=admin.example.com"
  sed -i -e 's/^#admin# //' -e '/^#shop# /d' "$out"
  grep -q 'X-Robots-Tag' "$out" || exit 6
  grep -q 'proxy_cache ' "$out" && exit 7
  exit 0
); rc=$?
if [[ $rc -eq 0 ]]; then ok "templates render: placeholders replaced, shop/admin variants correct"; else bad "template rendering (exit $rc)"; fi
if command -v nginx >/dev/null 2>&1; then
  if ( source "$ROOT/scripts/stacks/laravel_next.sh" >/dev/null 2>&1
    d="$TMP/ngx"; mkdir -p "$d/conf.d"
    if [[ -f /etc/nginx/fastcgi_params ]]; then cp /etc/nginx/fastcgi_params "$d/"; else : >"$d/fastcgi_params"; fi
    cp "$ROOT/config/laravel-next/nginx-http.conf" "$d/conf.d/00.conf"
    lnx_render "$ROOT/config/laravel-next/nginx-api.conf" "$d/conf.d/api.conf" "HOST=api.example.com" "ROOT=/tmp" "PHP_SOCK=/tmp/x.sock"
    lnx_render "$ROOT/config/laravel-next/nginx-next.conf" "$d/conf.d/shop.conf" "NAME=shop" "PORT=3000" "SERVER_NAMES=example.com"
    sed -i -e 's/^#shop# //' -e '/^#admin# /d' "$d/conf.d/shop.conf"
    [[ -e /proc/net/if_inet6 ]] || sed -i '/listen \[::\]/d' "$d"/conf.d/*.conf
    printf 'pid %s/nginx.pid;\nevents {}\nhttp {\n access_log off;\n client_body_temp_path %s/t/body;\n proxy_temp_path %s/t/proxy;\n fastcgi_temp_path %s/t/fcgi;\n uwsgi_temp_path %s/t/uwsgi;\n scgi_temp_path %s/t/scgi;\n include %s/conf.d/*.conf;\n}\n' "$d" "$d" "$d" "$d" "$d" "$d" "$d" >"$d/nginx.conf"
    mkdir -p "$d/cache" "$d/logs" "$d/t"
    sed -i -e "s|/var/cache/nginx/pulse_shop|$d/cache|" "$d/conf.d/00.conf"
    sed -i -e "s|/var/log/nginx|$d/logs|" -e 's/listen 80/listen 18080/' -e 's/\]:80/]:18080/' "$d"/conf.d/*.conf   # unprivileged users cannot bind :80
    nginx -t -c "$d/nginx.conf" -e "$d/err.log" -p "$d" >"$TMP/nginx-t.out" 2>&1 ); then
    ok "nginx accepts the rendered laravel-next configs"
  else
    bad "nginx -t on rendered laravel-next configs" "$(tail -n 3 "$TMP/nginx-t.out")"
  fi
fi

echo "── pulse CLI: deploy / rollback / prune (fake services)"
FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\necho "$@" >> "%s/systemctl.log"\nexit 0\n' "$TMP" >"$FB/systemctl"
# shellcheck disable=SC2016  # expanded by the fake sudo at run time
printf '#!/bin/sh\n[ "$1" = "-n" ] && shift\nexec "$@"\n' >"$FB/sudo"
# shellcheck disable=SC2016  # expanded by the fake curl at run time, not here
printf '#!/bin/sh\nprintf "%%s" "${FAKE_HTTP:-200}"\n' >"$FB/curl"
chmod +x "$FB"/*
export PULSE_CONF="$TMP/none.conf" APPS_ROOT="$TMP/www"
mkdir -p "$APPS_ROOT/shop/releases" "$APPS_ROOT/shop/shared"
mkart() { # mkart <name> [with-server]
  local d="$TMP/art-$1"; rm -rf "$d"; mkdir -p "$d/.next/static"
  [[ "${2:-yes}" == "yes" ]] && echo "// $1" >"$d/server.js"
  tar -czf "$TMP/$1.tar.gz" -C "$d" .
}
pulse() { PATH="$FB:$PATH" SHOP_HOST=example.com KEEP_RELEASES=3 bash "$ROOT/bin/pulse" "$@"; }
mkart a; mkart b; mkart c; mkart d; mkart bad no
if pulse deploy shop --artifact "$TMP/a.tar.gz" >/dev/null 2>&1; then ok "first deploy succeeds"; else bad "first deploy"; fi
rel1="$(basename "$(readlink -f "$APPS_ROOT/shop/current")")"
sleep 1; pulse deploy shop --artifact "$TMP/b.tar.gz" >/dev/null 2>&1
rel2="$(basename "$(readlink -f "$APPS_ROOT/shop/current")")"
if [[ "$rel1" != "$rel2" ]]; then ok "second deploy switches the release"; else bad "release did not change"; fi
if [[ -L "$APPS_ROOT/shop/releases/$rel2/.next/cache" ]]; then ok "next cache linked into shared/"; else bad "next cache not linked"; fi
if grep -q 'restart pulse-next@shop.service' "$TMP/systemctl.log"; then ok "service restarted via systemctl"; else bad "no restart recorded"; fi
pulse rollback shop >/dev/null 2>&1
eq "rollback returns to previous release" "$rel1" "$(basename "$(readlink -f "$APPS_ROOT/shop/current")")"
before="$(readlink -f "$APPS_ROOT/shop/current")"
if pulse deploy shop --artifact "$TMP/bad.tar.gz" >/dev/null 2>&1; then bad "artifact without server.js was accepted"; else ok "artifact without server.js is rejected"; fi
eq "failed deploy leaves current untouched" "$before" "$(readlink -f "$APPS_ROOT/shop/current")"
eq "failed deploy leaves no half-built release" "2" "$(find "$APPS_ROOT/shop/releases" -mindepth 1 -maxdepth 1 | wc -l)"
sleep 1
if FAKE_HTTP=502 pulse deploy shop --artifact "$TMP/c.tar.gz" >/dev/null 2>&1; then bad "unhealthy deploy reported success"; else ok "unhealthy deploy fails"; fi
eq "unhealthy deploy is rolled back automatically" "$before" "$(readlink -f "$APPS_ROOT/shop/current")"
for x in c d; do sleep 1; pulse deploy shop --artifact "$TMP/$x.tar.gz" >/dev/null 2>&1; done
n="$(find "$APPS_ROOT/shop/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [[ "$n" -le 4 ]]; then ok "old releases pruned (kept $n, KEEP_RELEASES=3 plus the failed one)"; else bad "prune did not run" "$n releases"; fi
if [[ -d "$(readlink -f "$APPS_ROOT/shop/current")" ]]; then ok "current release survives pruning"; else bad "current release was pruned"; fi
check_not "pulse rejects unknown command"  bash "$ROOT/bin/pulse" frobnicate
check_not "pulse rejects unknown app"      bash "$ROOT/bin/pulse" deploy nothing --artifact x
unset PULSE_CONF APPS_ROOT

echo "── bootstrap.sh CLI (no root needed for these)"
B=(bash "$ROOT/bootstrap.sh")
check     "--help works"                 "${B[@]}" --help
check     "--version works"              "${B[@]}" --version
check_not "unknown flag rejected"        "${B[@]}" --bogus
check_not "missing value rejected"       "${B[@]}" --stack
check_not "bad stack rejected"           "${B[@]}" --stack=cobol
check_not "bad php rejected"             "${B[@]}" --php 7.4
check_not "bad node rejected"            "${B[@]}" --node 12
check_not "bad port rejected"            "${B[@]}" --app-port 99999
check_not "bad domain rejected"          "${B[@]}" --domain 'x;y'
check_not "bad email rejected"           "${B[@]}" --email nope
check_not "bad swap rejected"            "${B[@]}" --swap-size 2GB
check_not "bad db name rejected"         "${B[@]}" --db-name "a b"
check_not "db-user without db-name"      "${B[@]}" --db-user bob
check_not "bad redis-conn rejected"      "${B[@]}" --redis-conn udp
check_not "bad open-ports rejected"      "${B[@]}" --open-ports 80,abc
check_not "unknown service rejected"     "${B[@]}" --services redis,mongo
check_not "bad api host rejected"        "${B[@]}" --api-host "bad host"
check_not "bad admin host rejected"      "${B[@]}" --admin-host "x;y"
check_not "root as app user rejected"    "${B[@]}" --app-user root
check_not "uppercase app user rejected"  "${B[@]}" --app-user Deploy
out="$("${B[@]}" --help)"
# shellcheck disable=SC1003  # the backslash is literal on purpose
if [[ "$out" != *'\033'* ]]; then ok "help has no raw escape sequences"; else bad "help prints literal backslash-033"; fi

echo "── revert.sh CLI"
R=(bash "$ROOT/revert.sh")
check     "--help works"                 "${R[@]}" --help
check_not "unknown flag rejected"        "${R[@]}" --bogus

echo "── syntax"
for s in "$ROOT"/bootstrap.sh "$ROOT"/revert.sh "$ROOT"/scripts/*/*.sh; do
  check "bash -n ${s#"$ROOT"/}" bash -n "$s"
done

echo
echo "Passed: $PASS   Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
