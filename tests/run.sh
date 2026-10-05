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
  lnx_render "$ROOT/config/laravel-next/nginx-api.conf" "$out" "HOST=api.example.com" "ROOT=/var/www/api/current/public" "PHP_SOCK=/run/php/x&y.sock" "LOCATIONS=/etc/nginx/pulsedeploy/api-locations.inc" "INTERNAL_PORT=8081"
  grep -q 'server_name api.example.com;' "$out" || exit 1
  grep -q 'unix:/run/php/x&y.sock;' "$out" || exit 2          # '&' must stay literal
  grep -q 'listen 127.0.0.1:8081;' "$out" || exit 8           # loopback-only internal listener
  [[ "$(grep -c 'include /etc/nginx/pulsedeploy/api-locations.inc;' "$out")" -eq 2 ]] || exit 9
  lnx_render "$ROOT/config/laravel-next/nginx-api-locations.inc" "$TMP/loc.out" "PHP_SOCK=/run/php/p.sock"
  grep -q 'fastcgi_pass unix:/run/php/p.sock;' "$TMP/loc.out" || exit 10
  # storage lines: removed when off, enabled when on
  lnx_render "$ROOT/config/laravel-next/nginx-next.conf" "$out" "NAME=shop" "PORT=3000" "SERVER_NAMES=example.com" "STORAGE_DIR=/var/www/api/shared/storage/app/public"
  sed -i -e '/^#storage# /d' "$out"; grep -q 'location /storage/' "$out" && exit 11
  lnx_render "$ROOT/config/laravel-next/nginx-next.conf" "$out" "NAME=shop" "PORT=3000" "SERVER_NAMES=example.com" "STORAGE_DIR=/var/www/api/shared/storage/app/public"
  sed -i -e 's/^#storage# //' "$out"; grep -q 'alias /var/www/api/shared/storage/app/public/;' "$out" || exit 12
  lnx_render "$ROOT/config/laravel-next/mysql-tuning.cnf" "$out" MAXCONN=50 BP=384 TMP=32 TABLE_CACHE=2000 TABLE_DEF=2000 "BINLOG="
  grep -q 'table_open_cache *= 2000' "$out" || exit 13
  grep -q '^bind-address *= 127.0.0.1$' "$out" || exit 15   # the database must never listen publicly
  lnx_render "$ROOT/config/laravel-next/nginx-api.conf" "$out" "HOST=api.example.com" "ROOT=/var/www/api/current/public" "PHP_SOCK=/run/php/x.sock" "LOCATIONS=/x.inc" "INTERNAL_PORT=8081"
  for p in /login /api/login /api/v1/admin/login /api/v1/forgot-password; do   # throttle must cover the real login paths
    printf '%s' "$p" | grep -Eq "$(sed -n 's/^ *location ~ \(.*\) {$/\1/p' "$out" | head -n 1)" || exit 14
  done
  lnx_render "$ROOT/config/laravel-next/nginx-api.conf" "$out" "HOST=api.example.com" "ROOT=/var/www/api/current/public" "PHP_SOCK=/run/php/x&y.sock" "LOCATIONS=/etc/nginx/pulsedeploy/api-locations.inc" "INTERNAL_PORT=8081"
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
    mkdir -p "$d/inc"
    lnx_render "$ROOT/config/laravel-next/nginx-api-locations.inc" "$d/inc/api-locations.inc" "PHP_SOCK=/tmp/x.sock"
    lnx_render "$ROOT/config/laravel-next/nginx-api.conf" "$d/conf.d/api.conf" "HOST=api.example.com" "ROOT=/tmp" "PHP_SOCK=/tmp/x.sock" "LOCATIONS=$d/inc/api-locations.inc" "INTERNAL_PORT=18081"
    lnx_render "$ROOT/config/laravel-next/nginx-next.conf" "$d/conf.d/shop.conf" "NAME=shop" "PORT=3000" "SERVER_NAMES=example.com" "STORAGE_DIR=$d"
    sed -i -e 's/^#shop# //' -e 's/^#storage# //' -e '/^#admin# /d' "$d/conf.d/shop.conf"
    [[ -e /proc/net/if_inet6 ]] || sed -i '/listen \[::\]/d' "$d"/conf.d/*.conf
    sed -i -e 's/^ *listen 127.0.0.1:18081;/    listen 127.0.0.1:18081;/' "$d/conf.d/api.conf"
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

echo "── tenant database grants"
(
  # shellcheck source=scripts/services/mysql.sh
  source "$ROOT/scripts/services/mysql.sh"
  mysql() { printf '%s\n' "$*" >"$TMP/mysql.sql"; }        # capture instead of running
  TENANT_DB_PREFIX=zymerce_tenant_ mysql_grant_tenant_prefix appuser >/dev/null
  sql="$(cat "$TMP/mysql.sql")"
  # underscores must be escaped: an unescaped "_" would match any character
  # shellcheck disable=SC2016  # backticks are literal SQL identifier quotes
  [[ "$sql" == *'`zymerce\_tenant\_%`.*'* ]] || exit 1
  [[ "$sql" == *"'appuser'@'localhost'"* ]] || exit 4
  rm -f "$TMP/mysql.sql"; TENANT_DB_PREFIX="" mysql_grant_tenant_prefix appuser >/dev/null
  [[ ! -e "$TMP/mysql.sql" ]] || exit 2                     # no prefix, no grant
  # error() exits, so run the invalid case in its own subshell
  if ( TENANT_DB_PREFIX="bad;prefix" mysql_grant_tenant_prefix appuser ) >/dev/null 2>&1; then exit 3; fi
  exit 0
); rc=$?
if [[ $rc -eq 0 ]]; then ok "tenant prefix grant: pattern escaped, skipped when unset, injection rejected"; else bad "tenant grant (exit $rc)"; fi

echo "── crm.sh: definitions, placeholders, config patching"
# shellcheck disable=SC2016  # literal $( ) text is the point of these checks
(
  # shellcheck source=scripts/lib/crm.sh
  source "$ROOT/scripts/lib/crm.sh"
  f="$TMP/def.conf"
  printf '# comment\r\nNAME=My App\r\n\r\nA_LIST+=one\nA_LIST+=two words\nMODE=x=y\n' >"$f"
  registry_load "$f" T "NAME MODE MISSING" "A_LIST"
  [[ "$T_NAME" == "My App" ]] || exit 1                       # CRLF tolerated, spaces kept
  [[ "${#T_A_LIST[@]}" -eq 2 && "${T_A_LIST[1]}" == "two words" ]] || exit 2
  [[ "$T_MODE" == "x=y" ]] || exit 3                          # only the first "=" splits
  [[ -z "$T_MISSING" ]] || exit 4                             # undefined scalar is empty, not unset
  printf 'EVIL=$(touch %s/pwned)\n' "$TMP" >"$f"
  if ( registry_load "$f" T "NAME" "" ) >/dev/null 2>&1; then exit 5; fi     # unknown key rejected
  printf 'NAME+=x\n' >"$f"
  if ( registry_load "$f" T "NAME" "" ) >/dev/null 2>&1; then exit 6; fi     # += on a scalar rejected
  printf 'NAME=$(touch %s/pwned2)\n' "$TMP" >"$f"; registry_load "$f" T "NAME" ""
  [[ ! -e "$TMP/pwned2" && "$T_NAME" == *'$(touch'* ]] || exit 7             # values are data, never executed
  printf 'not a valid line\n' >"$f"
  if ( registry_load "$f" T "NAME" "" ) >/dev/null 2>&1; then exit 8; fi
  CRM_VARS=([STORE]="a&b" [API_URL]="https://api.x.com")
  [[ "$(crm_expand 'u={API_URL}/api s={STORE}')" == "u=https://api.x.com/api s=a&b" ]] || exit 9   # "&" stays literal
  if ( crm_expand 'x={NOPE}' ) >/dev/null 2>&1; then exit 10; fi                                   # typo'd placeholder fails
  exit 0
); rc=$?
if [[ $rc -eq 0 ]]; then ok "definitions parsed as data; placeholders filled; bad input rejected"; else bad "crm definitions/placeholders (exit $rc)"; fi

(
  # shellcheck source=scripts/lib/crm.sh
  source "$ROOT/scripts/lib/crm.sh"
  # shellcheck disable=SC2030,SC2031  # subshell-local on purpose
  APP_USER="$(id -un)"
  d="$TMP/next"; mkdir -p "$d"
  patch() { printf '%s\n' "$2" >"$d/$1"; crm_ensure_standalone "$d" >/dev/null 2>&1; }
  # the exact style used by the AvenTech admin app
  patch next.config.ts 'import type { NextConfig } from "next";
const nextConfig: NextConfig = {
  allowedDevOrigins: ["127.0.0.1"],
};
export default nextConfig;' || exit 1
  grep -q 'output: "standalone"' "$d/next.config.ts" || exit 2
  [[ "$(grep -c 'output:' "$d/next.config.ts")" -eq 1 ]] || exit 3
  crm_ensure_standalone "$d" >/dev/null 2>&1; [[ "$(grep -c 'output:' "$d/next.config.ts")" -eq 1 ]] || exit 4   # idempotent
  rm -f "$d"/next.config.*
  patch next.config.js 'module.exports = { reactStrictMode: true };' || exit 5
  grep -q 'output: "standalone"' "$d/next.config.js" || exit 6
  rm -f "$d"/next.config.*
  patch next.config.mjs 'export default { reactStrictMode: true };' || exit 8
  grep -q 'output: "standalone"' "$d/next.config.mjs" || exit 9
  rm -f "$d"/next.config.*
  # a comment that mentions the setting must not count as the setting
  patch next.config.js '/** not using output: "standalone" here yet */
// output: "export" was tried once
module.exports = { reactStrictMode: true };' || exit 12
  [[ "$(grep -c '^  output: "standalone",' "$d/next.config.js")" -eq 1 ]] || exit 13
  rm -f "$d"/next.config.*
  printf 'const c = { output: "export" };\nmodule.exports = c;\n' >"$d/next.config.js"
  if ( crm_ensure_standalone "$d" ) >/dev/null 2>&1; then exit 10; fi      # a conflicting output mode is refused (error() exits, so isolate it)
  rm -f "$d"/next.config.*
  if ( crm_ensure_standalone "$d" ) >/dev/null 2>&1; then exit 11; fi      # not a Next.js app
  exit 0
); rc=$?
if [[ $rc -eq 0 ]]; then ok "standalone output enabled for ts/js/mjs configs, idempotent, conflicts refused"; else bad "next config patching (exit $rc)"; fi

(
  # shellcheck source=scripts/lib/crm.sh
  source "$ROOT/scripts/lib/crm.sh"
  # shellcheck disable=SC2030,SC2031  # subshell-local on purpose
  APP_USER="$(id -un)"
  e="$TMP/app.env"; printf 'KEEP=mine\n' >"$e"
  crm_env_put "$e" KEEP theirs; crm_env_put "$e" NEWKEY "has space & quote\"" ; crm_env_put "$e" PLAIN value
  grep -Fxq 'KEEP=mine' "$e" || exit 1                     # existing value kept by default
  grep -Fxq 'NEWKEY="has space & quote\""' "$e" || exit 2   # awkward values are quoted and escaped
  crm_env_put "$e" KEEP theirs overwrite; grep -Fxq 'KEEP=theirs' "$e" || exit 3
  if ( crm_env_put "$e" 'BAD KEY' x ) >/dev/null 2>&1; then exit 4; fi
  exit 0
); rc=$?
if [[ $rc -eq 0 ]]; then ok "env files: existing values kept, overwrite on request, values quoted, bad names rejected"; else bad "crm env handling (exit $rc)"; fi

(
  # shellcheck source=scripts/lib/crm.sh
  source "$ROOT/scripts/lib/crm.sh"
  CRM_GIT_TOKEN="tok-SECRET-123"; CRM_GIT_SSH_KEY_EFFECTIVE=""
  crm_git_setup
  env_line="${CRM_RUN_ENV[*]}"
  helper=""
  for e in "${CRM_RUN_ENV[@]}"; do [[ "$e" == GIT_ASKPASS=* ]] && helper="${e#GIT_ASKPASS=}"; done
  [[ -x "$helper" ]] || exit 1
  [[ "$("$helper" "Username for 'https://github.com': ")" == "x-access-token" ]] || exit 2
  [[ "$(PULSE_GIT_TOKEN=tok-SECRET-123 "$helper" "Password for 'https://x-access-token@github.com': ")" == "tok-SECRET-123" ]] || exit 3
  grep -q 'SECRET' "$helper" && exit 4                       # the helper script itself holds no secret
  [[ "$env_line" == *"GIT_TERMINAL_PROMPT=0"* ]] || exit 5   # never hang waiting for a prompt
  CRM_GIT_TOKEN=""; CRM_GIT_SSH_KEY_EFFECTIVE="/keys/deploy"; crm_git_setup
  [[ "${CRM_RUN_ENV[*]}" == *"GIT_SSH_COMMAND=ssh -i /keys/deploy -o IdentitiesOnly=yes -o BatchMode=yes"* ]] || exit 6
  [[ "${CRM_RUN_ENV[*]}" != *ASKPASS* ]] || exit 7
  [[ "${CRM_RUN_ENV[*]}" == *"GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1"* ]] || exit 16   # robust against dropped HTTP/2 streams
  exit 0
); rc=$?
if [[ $rc -eq 0 ]]; then ok "git auth: token answered via askpass from the environment (not stored), ssh key command built"; else bad "crm git auth (exit $rc)"; fi

C=(bash "$ROOT/crm.sh")
check_not "crm: install without --domain"          "${C[@]}" install --storefront none
check_not "crm: install without --storefront"      "${C[@]}" install --domain example.com
check_not "crm: unknown storefront id"             "${C[@]}" install --domain example.com --storefront nope --dry-run
check_not "crm: --certbot without --email"         "${C[@]}" install --domain example.com --storefront none --certbot --dry-run
check_not "crm: bad --only value"                  "${C[@]}" install --domain example.com --storefront none --only backend,foo --dry-run
check_not "crm: bad git url"                       "${C[@]}" install --domain example.com --storefront none --crm-repo "ftp://x" --dry-run
check_not "crm: bad ref"                           "${C[@]}" install --domain example.com --storefront none --crm-ref "a b" --dry-run
check_not "crm: bad store slug"                    "${C[@]}" install --domain example.com --storefront none --store "Bad Slug" --dry-run
check_not "crm: short admin password"              "${C[@]}" install --domain example.com --storefront none --admin-password short --dry-run
check_not "crm: bad build env"                     "${C[@]}" install --domain example.com --storefront https://github.com/o/r.git --storefront-build-env "no-equals" --dry-run
check_not "crm: unknown option"                    "${C[@]}" install --domain example.com --storefront none --bogus
check     "crm: help works"                        "${C[@]}" help
check     "crm: storefronts list works"            "${C[@]}" storefronts
plan="$("${C[@]}" install --domain example.com --storefront https://github.com/o/shop.git --storefront-ref v2 --store acme --store-name "Acme Shop" --cloudflare --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
if [[ "$plan" == *"https://api.example.com"* && "$plan" == *"shop.git @ v2"* && "$plan" == *"slug acme"* ]]; then ok "crm: dry-run plan shows hosts (https via --cloudflare), storefront @ ref, store"; else bad "crm dry-run plan" "$plan"; fi
regdir="$TMP/reg"; mkdir -p "$regdir/storefronts"; printf 'NAME=Custom Shop\nREPO=https://github.com/o/custom.git\nREF=stable\nBUILD_ENV+=NEXT_PUBLIC_API_URL={API_URL}/api\n' >"$regdir/storefronts/custom.conf"
listing="$("${C[@]}" storefronts --registry-dir "$regdir" 2>&1)"
if [[ "$listing" == *custom* ]]; then ok "crm: extra registry directory is listed"; else bad "crm registry-dir listing" "$listing"; fi
plan2="$("${C[@]}" install --domain example.com --storefront custom --registry-dir "$regdir" --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
if [[ "$plan2" == *"Custom Shop"* && "$plan2" == *"custom.git @ stable"* ]]; then ok "crm: storefront picked from the registry by id"; else bad "crm registry storefront" "$plan2"; fi

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
# api deploy with the queue switched off must not touch the queue service
mkdir -p "$APPS_ROOT/api/releases" "$APPS_ROOT/api/shared/storage"
printf 'APP_KEY=base64:x\n' >"$APPS_ROOT/api/shared/.env"
mkapi() { local d="$TMP/api-src"; rm -rf "$d"; mkdir -p "$d/public" "$d/vendor" "$d/bootstrap"; echo "<?php" >"$d/artisan"; echo "<?php" >"$d/public/index.php"; echo "<?php" >"$d/vendor/autoload.php"; tar -czf "$TMP/api.tar.gz" -C "$d" .; }
mkapi; printf '#!/bin/sh\nexit 0\n' >"$TMP/fakephp"; chmod +x "$TMP/fakephp"; : >"$TMP/systemctl.log"
QUEUE_ENABLED=0 SCHEDULER_ENABLED=0 PHP_BIN="$TMP/fakephp" API_HOST=api.example.com pulse deploy api --artifact "$TMP/api.tar.gz" --no-migrate >/dev/null 2>&1
if grep -q 'pulse-queue' "$TMP/systemctl.log" || grep -q 'pulse-scheduler' "$TMP/systemctl.log"; then bad "queue/scheduler touched although disabled"; else ok "queue and scheduler untouched when disabled"; fi
: >"$TMP/systemctl.log"; sleep 1
PHP_BIN="$TMP/fakephp" API_HOST=api.example.com pulse deploy api --artifact "$TMP/api.tar.gz" --no-migrate >/dev/null 2>&1
if grep -q 'restart pulse-queue.service' "$TMP/systemctl.log"; then ok "queue restarted when enabled"; else bad "queue not restarted when enabled"; fi
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
check_not "bad tenant prefix rejected"   "${B[@]}" --tenant-db-prefix "a;b"
check_not "root as app user rejected"    "${B[@]}" --app-user root
check_not "uppercase app user rejected"  "${B[@]}" --app-user Deploy
out="$("${B[@]}" --help)"
# shellcheck disable=SC1003  # the backslash is literal on purpose
if [[ "$out" != *'\033'* ]]; then ok "help has no raw escape sequences"; else bad "help prints literal backslash-033"; fi

echo "── revert.sh CLI"
R=(bash "$ROOT/revert.sh")
check     "--help works"                 "${R[@]}" --help
check_not "unknown flag rejected"        "${R[@]}" --bogus

echo "── audit helpers"
audit() { bash -c 'source "$1"; shift; "$@"' _ "$ROOT/scripts/audit.sh" "$@"; } # own shell: audit.sh keeps its own PASS/FAIL counters
eq "percentile p50 of 1..10"          "5"   "$(audit percentile 50 10 1 9 2 8 3 7 4 6 5)"
eq "percentile p95 of 1..20"          "19"  "$(audit percentile 95 $(seq 1 20))"
eq "percentile p100 is the maximum"   "250" "$(audit percentile 100 12 250 40)"
eq "percentile of one sample"         "7"   "$(audit percentile 95 7)"
check_not "percentile of nothing fails" audit percentile 95
printf 'API_HOST=api.example.com\nKEEP_RELEASES=5\n# X=1\n' >"$TMP/pulse.conf"
eq "conf_val reads a key"             "api.example.com" "$(audit conf_val "$TMP/pulse.conf" API_HOST)"
eq "conf_val ignores comments"        ""    "$(audit conf_val "$TMP/pulse.conf" X)"
check_not "conf_val on a missing file fails" audit conf_val "$TMP/none" API_HOST
printf '; managed\npm = ondemand\npm.max_children = 12\npm.max_children = 14\nopcache.jit=tracing\n' >"$TMP/pool.conf"
eq "ini_val trims spaces"             "ondemand" "$(audit ini_val "$TMP/pool.conf" pm)"
eq "ini_val takes the last assignment" "14"  "$(audit ini_val "$TMP/pool.conf" pm.max_children)"
eq "ini_val without spaces"           "tracing" "$(audit ini_val "$TMP/pool.conf" opcache.jit)"
ss_sample='LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1,fd=6))
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=2,fd=3))
LISTEN 0 80 127.0.0.1:3306 0.0.0.0:* users:(("mariadbd",pid=3,fd=20))
LISTEN 0 511 127.0.0.1:8081 0.0.0.0:* users:(("nginx",pid=1,fd=8))
LISTEN 0 511 [::]:80 [::]:* users:(("nginx",pid=1,fd=7))
LISTEN 0 100 [::1]:25 [::]:*
LISTEN 0 128 0.0.0.0:6379 0.0.0.0:* users:(("redis-server",pid=4,fd=6))'
eq "public listeners skip loopback and dedupe" "22 sshd
80 nginx
6379 redis-server" "$(printf '%s\n' "$ss_sample" | audit public_listeners_from)"
eq "perm_check accepts 640 against 640" "ok" "$(touch "$TMP/p640" && chmod 640 "$TMP/p640" && audit perm_check "$TMP/p640" 640 x | grep -q PASS && echo ok)"
eq "perm_check rejects 644 against 640" "ok" "$(touch "$TMP/p644" && chmod 644 "$TMP/p644" && audit perm_check "$TMP/p644" 640 x | grep -q FAIL && echo ok)"
eq "cpu_delta busy/iowait/steal"       "55.0 5.0 5.0" "$(audit cpu_delta 'cpu 0 0 0 0 0 0 0 0 0 0' 'cpu 400 0 100 400 50 0 0 50 0 0')"  # 1000 ticks: 450 idle+wait, 50 wait, 50 steal
eq "cpu_delta with no elapsed time"    "0.0 0.0 0.0"   "$(audit cpu_delta 'cpu 1 0 1 1 1 0 0 1' 'cpu 1 0 1 1 1 0 0 1')"
eq "php_budget_mb for a 4 GB server"   "1180" "$(audit php_budget_mb 3889 768 233 448 448)"
eq "suggest_children divides the budget" "19" "$(audit suggest_children 1180 60)"
eq "suggest_children never below 4"    "4"   "$(audit suggest_children 100 80)"
eq "cpu_children_cap: 2 CPUs"           "12"  "$(audit cpu_children_cap 2)"
eq "cpu_children_cap: 1 CPU"              "6"   "$(audit cpu_children_cap 1)"
eq "suggest_children survives 0 MB"    "100" "$(audit suggest_children 100 0)"
check_not "audit rejects requests < concurrency" bash "$ROOT/scripts/audit.sh" --requests 3 --concurrency 10
check_not "audit rejects a relative load path"   bash "$ROOT/scripts/audit.sh" --load-path up
check "audit --help works"               bash "$ROOT/scripts/audit.sh" --help
check_not "audit rejects an unknown flag" bash "$ROOT/scripts/audit.sh" --bogus

echo "── tuning overrides"
tune() { bash -c 'source "$1"; shift; "$@"' _ "$ROOT/scripts/lib/profile_tuning.sh" "$@"; }
eq "no overrides: fpm children unchanged"  "12"  "$(tune tune_fpm_children 3889)"
printf 'FPM_CHILDREN=20\nMYSQL_BUFFER_POOL_MB=1024\nREDIS_MAXMEM_MB=300\nNODE_HEAP_ADMIN=320\nNODE_HEAP_SHOP=abc\nEVIL=1; rm -rf /\nMYSQL_MAX_CONNECTIONS=0\n' >"$TMP/tuning.conf"
ov() { bash -c 'source "$1"; tune_load_overrides "$2"; shift 2; "$@"' _ "$ROOT/scripts/lib/profile_tuning.sh" "$TMP/tuning.conf" "$@"; }
eq "override: fpm children"               "20"   "$(ov tune_fpm_children 3889)"
eq "override: buffer pool"                "1024" "$(ov tune_mysql_buffer_pool 3889)"
eq "override: redis memory"               "300"  "$(ov tune_redis_mem 3889)"
eq "override: node heap admin"            "320"  "$(ov tune_node_heap 3889 admin)"
eq "override: MemoryMax follows the heap" "512"  "$(ov tune_node_memory_max 3889 admin)"
eq "non-numeric override ignored"         "256"  "$(ov tune_node_heap 3889 shop)"
eq "zero override ignored"                "50"   "$(ov tune_mysql_max_connections 3889)"
eq "active overrides are listed"          "FPM_CHILDREN=20
MYSQL_BUFFER_POOL_MB=1024
REDIS_MAXMEM_MB=300
NODE_HEAP_ADMIN=320" "$(ov tune_active_overrides)"
eq "unknown keys are never executed"      "no" "$([[ -e '/rm' ]] && echo yes || echo no)"
# shellcheck disable=SC2016  # $1/$2 are meant for the inner shell
check "missing tuning file is fine"        bash -c 'source "$1"; tune_load_overrides "$2"' _ "$ROOT/scripts/lib/profile_tuning.sh" "$TMP/none"

rt() { bash -c 'source "$1"; RAM="$2"; WORKER_MB="$3"; FORCE="$4"; fits_in_ram' _ "$ROOT/scripts/retune.sh" "$1" "${2:-60}" "${3:-0}"; }
check "retune: default plan fits a 4 GB server"        rt 3889
check_not "retune: an oversized plan is refused"       rt 2048 60 0
check "retune: --force overrides the memory check"     rt 2048 60 1
check "retune --help works"                            bash "$ROOT/scripts/retune.sh" --help
check_not "retune rejects an unknown flag"             bash "$ROOT/scripts/retune.sh" --bogus
check_not "retune needs root and an install"           bash "$ROOT/scripts/retune.sh"

echo "── repository URL validation"
vurl() { bash -c 'source <(sed -n "/^valid_git_url()/p" "$1"); valid_git_url "$2"' _ "$ROOT/crm.sh" "$1"; }
check "https URL accepted"                     vurl https://github.com/o/r.git
check "ssh form accepted"                      vurl git@github.com:o/r.git
check "local clone accepted"                   vurl file:///srv/crm.git
check_not "relative path rejected"             vurl ./crm.git
check_not "option-looking value rejected"      vurl --upload-pack=evil
check_not "file URL with spaces rejected"      vurl "file:///srv/a b"
check_not "file URL with shell characters rejected" vurl 'file:///srv/x;rm'

echo "── load-test module"
check "loadtest/run.sh --help works"                  bash "$ROOT/loadtest/run.sh" --help
check_not "loadtest/run.sh needs a target"            bash "$ROOT/loadtest/run.sh" --scenario aventech-admin
check_not "loadtest/run.sh rejects an unknown flag"   bash "$ROOT/loadtest/run.sh" --bogus
check_not "loadtest/run.sh refuses an oversized plan" bash "$ROOT/loadtest/run.sh" --ip 1.2.3.4 --domain x.test --profile spike --users 80 --check
check_not "loadtest/run.sh without a terminal needs --yes" bash "$ROOT/loadtest/run.sh" --ip 1.2.3.4 --domain x.test </dev/null
printf '\033[200~secret~' >"$TMP/pw-bad"; printf 'secret' >"$TMP/pw-good"
check_not "loadtest/run.sh rejects a password file with paste markers" bash "$ROOT/loadtest/run.sh" --ip 1.2.3.4 --domain x.test --password-file "$TMP/pw-bad" --check
check "loadtest/run.sh accepts a clean password file"  bash "$ROOT/loadtest/run.sh" --ip 1.2.3.4 --domain x.test --password-file "$TMP/pw-good" --check
check "loadtest/run.sh --check validates and sends nothing" bash "$ROOT/loadtest/run.sh" --ip 1.2.3.4 --domain x.test --scenario aventech-admin:1,aventech-storefront:3 --check
echo "── crm.sh: smoke tests report failures by name"
sc() { bash "$ROOT/tests/smoke_case.sh" "$@"; }
check     "smoke: healthy install passes (store name checked)" sc ok 1
check     "smoke: healthy install passes (name not checked)"   sc ok 0
check_not "smoke: unreadable tenant database fails"            sc dbdown 0
check_not "smoke: refused admin login fails"                   sc badlogin 0
check_not "smoke: inactive scheduler timer fails"              sc ok 0 inactive
echo "── crm.sh: store:provision step (fake artisan)"
st() { bash "$ROOT/tests/store_case.sh" "$@"; }
check "store: created, credentials 0600, password by file, no leak" st created
check "store: operator-supplied password is kept"                  st supplied
check "store: --catalog/--demo/--vertical are passed through"      st catalog
check "store: existing store is left alone, no credentials"        st exists
check "store: a refusal fails the run and shows the message"       st refused
check "store: a crash fails the run"                               st crash
echo "── pulse-lt: throttles, seed, record diff (fake artisan)"
lt() { bash "$ROOT/tests/lt_case.sh" "$@"; }
check "pulse-lt: throttles off/on restores .env byte for byte"   lt cycle
check "pulse-lt: an existing LOADTEST_MODE line is restored"     lt keeps-existing-mode
check "pulse-lt: refuses a CRM without LOADTEST_MODE, no change"  lt old-crm
check "pulse-lt: seed validates, refuses the live store, passes options" lt seed
check "pulse-lt: diff lists only what changed"                   lt diff
check "pulse-lt: usage and bad input"                            lt usage
check "seed.sh --help works"                          bash "$ROOT/loadtest/seed/seed.sh" --help
check_not "seed.sh needs --store"                     bash "$ROOT/loadtest/seed/seed.sh" --dry-run
check_not "seed.sh --no-data needs --create-store"    bash "$ROOT/loadtest/seed/seed.sh" --store t --no-data --dry-run
check_not "seed.sh rejects an unknown flag"           bash "$ROOT/loadtest/seed/seed.sh" --store t --bogus
check_not "seed.sh rejects a bad store name"          bash "$ROOT/loadtest/seed/seed.sh" --store 'a;b' --dry-run
check_not "seed.sh rejects a non-numeric count"       bash "$ROOT/loadtest/seed/seed.sh" --store t --orders many --dry-run
check_not "seed.sh rejects an oversized plan"         bash "$ROOT/loadtest/seed/seed.sh" --store t --orders 99999999 --dry-run
check "seed.sh --dry-run changes nothing"             bash "$ROOT/loadtest/seed/seed.sh" --store t --dry-run
if command -v python3 >/dev/null 2>&1; then
  check "loadtest python files compile"               python3 -m py_compile "$ROOT/loadtest/humanlib.py" "$ROOT/loadtest/locustfile.py" "$ROOT/loadtest/tests/mock_server.py"
  check "loadtest unit tests (behaviour model)"       python3 -m unittest discover -s "$ROOT/loadtest/tests" -p 'test_humanlib.py'
  if [[ "${PULSE_TEST_ENGINE:-0}" == "1" ]]; then
    check "loadtest engine tests (real Locust, mock CRM)" python3 -m unittest "$ROOT/loadtest/tests/test_engine.py"
  else
    echo "  skip loadtest engine tests (set PULSE_TEST_ENGINE=1 with locust installed)"
  fi
else
  echo "  skip loadtest python tests (python3 not found)"
fi

echo "── syntax"
for s in "$ROOT"/bootstrap.sh "$ROOT"/revert.sh "$ROOT"/crm.sh "$ROOT"/bin/pulse "$ROOT"/scripts/vm-check.sh "$ROOT"/scripts/audit.sh "$ROOT"/scripts/retune.sh "$ROOT"/loadtest/run.sh "$ROOT"/scripts/*/*.sh; do
  check "bash -n ${s#"$ROOT"/}" bash -n "$s"
done

echo
echo "Passed: $PASS   Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
