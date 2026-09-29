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
