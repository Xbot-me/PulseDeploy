#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - loadtest/run.sh: human-like load against a server you own
#
#   bash loadtest/run.sh --ip 203.0.113.10 --domain crm.test \
#        --email admin@crm.test --password-file ~/lt-password --profile average --users 20
#
# Run it from a DIFFERENT machine than the server (your laptop or a second VM): load
# generated on the server's own CPUs measures the load generator as much as the server.
# It asks you to type the target's name before any traffic is sent.
# Details: docs/load-testing.md
# =============================================================================
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

SCENARIO="aventech-admin"; PROFILE="average"; USERS=20; HOLD=600; SPAWN="0.4"; STORE="main"
EMAIL=""; PASSWORD_FILE=""; WRITES=0; MAX_FAIL="0.01"; P95_MS="1500"; TIME_SCALE="1"; SEED=""
ACCOUNTS_FILE=""; SHARE_LOGIN=1
OUT=""; ASSUME_YES=0; ALLOW_LARGE=0; CHECK_ONLY=0; VERBOSE=0; NO_VENV=0
STEP_USERS=""; STEP_SECONDS=""; MAX_USERS=""; IP=""; DOMAIN=""
declare -a BASES=() HOSTHDRS=()

usage() {
  cat <<'EOF'
Usage: bash loadtest/run.sh [target] [what to run] [options]

TARGET (where the traffic goes; the servers must be yours)
  --ip <addr> --domain <domain>   a server reached by IP, hosts api.<domain> admin.<domain> shop.<domain>
                                  (sets the Host header, so no DNS entry is needed)
  --base <key>=<url>              base URL of one host key, repeatable (key = api, admin, shop, ...)
  --host-header <key>=<name>      Host header to send to that key, repeatable

WHAT TO RUN
  --scenario <a[:w],b[:w]>        scenario files in loadtest/scenarios (default aventech-admin);
                                  several run together, w is the share of virtual users
  --profile <name>                smoke | average (default) | peak | spike | soak | breakpoint
  --users <n>                     the "normal" number of people on the site (default 20)
  --hold <seconds>                how long to hold the load (default 600)
  --spawn <per second>            new people per second, also paces logins (default 0.4)
  --store <slug>                  tenant (X-Store-Subdomain) to use (default main)
  --email <e> --password-file <f> staff login used by the scenarios (the password is never
                                  taken from the command line; or set LT_VAR_PASSWORD)
  --accounts-file <f>             one "email:password" per line: each virtual person gets their own
                                  account (cycled). Without it, everyone shares the one --email login
  --no-share-login                with a single account, make every person log in (the CRM allows only
                                  5 logins a minute per account, so expect refusals)
  --writes                        also run steps that write data (carts, orders). Use a
                                  dedicated test store, never real data
  --var <name>=<value>            extra {name} value for the scenarios, repeatable

LIMITS (the run FAILS, and exits 1, when exceeded)
  --max-fail <fraction>           failed requests allowed (default 0.01 = 1%)
  --p95-ms <ms>                   slowest acceptable p95 of any endpoint (default 1500)

OTHER
  --time-scale <f>                multiply every human pause (0.1 = ten times faster clicking)
  --step-users/--step-seconds/--max-users   breakpoint profile steps
  --seed <text>                   repeat a run's random choices
  --out <dir>                     results folder (default loadtest/results/<time>)
  --check                         validate scenarios and the plan, send nothing
  --yes                           skip the confirmation (automation)
  --allow-large                   permit more than 200 peak users
  --no-venv                       use the locust already on PATH instead of loadtest/.venv
  --verbose                       show Locust's live tables as well
  -h, --help                      this text

You may only generate load against servers you own or have written permission to test.
EOF
}

need_value() { [[ $# -ge 2 && -n "${2:-}" ]] || error "$1 needs a value"; }
is_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

declare -a EXTRA_VARS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) need_value "$@"; IP="$2"; shift 2 ;;
    --domain) need_value "$@"; DOMAIN="$2"; shift 2 ;;
    --base) need_value "$@"; BASES+=("$2"); shift 2 ;;
    --host-header) need_value "$@"; HOSTHDRS+=("$2"); shift 2 ;;
    --scenario) need_value "$@"; SCENARIO="$2"; shift 2 ;;
    --profile) need_value "$@"; PROFILE="$2"; shift 2 ;;
    --users) need_value "$@"; USERS="$2"; shift 2 ;;
    --hold) need_value "$@"; HOLD="$2"; shift 2 ;;
    --spawn) need_value "$@"; SPAWN="$2"; shift 2 ;;
    --store) need_value "$@"; STORE="$2"; shift 2 ;;
    --email) need_value "$@"; EMAIL="$2"; shift 2 ;;
    --password-file) need_value "$@"; PASSWORD_FILE="$2"; shift 2 ;;
    --accounts-file) need_value "$@"; ACCOUNTS_FILE="$2"; shift 2 ;;
    --no-share-login) SHARE_LOGIN=0; shift ;;
    --writes) WRITES=1; shift ;;
    --var) need_value "$@"; EXTRA_VARS+=("$2"); shift 2 ;;
    --max-fail) need_value "$@"; MAX_FAIL="$2"; shift 2 ;;
    --p95-ms) need_value "$@"; P95_MS="$2"; shift 2 ;;
    --time-scale) need_value "$@"; TIME_SCALE="$2"; shift 2 ;;
    --step-users) need_value "$@"; STEP_USERS="$2"; shift 2 ;;
    --step-seconds) need_value "$@"; STEP_SECONDS="$2"; shift 2 ;;
    --max-users) need_value "$@"; MAX_USERS="$2"; shift 2 ;;
    --seed) need_value "$@"; SEED="$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --allow-large) ALLOW_LARGE=1; shift ;;
    --no-venv) NO_VENV=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    ... | …) error "'...' in the documentation stands for your target options: write them out, for example --ip 203.0.113.10 --domain crm.test --email admin@crm.test --password-file ~/lt-password" ;;
    *) error "Unknown option: $1 (see --help)" ;;
  esac
done

# ── validate everything before anything else happens ──────────────────────────
case "$PROFILE" in smoke | average | peak | spike | soak | breakpoint) ;; *) error "Unknown --profile '$PROFILE'" ;; esac
is_int "$USERS" || error "--users must be a whole number >= 1"
[[ "$USERS" -ge 1 ]] || error "--users must be a whole number >= 1"
is_int "$HOLD" || error "--hold must be a whole number of seconds"
is_number "$SPAWN" || error "--spawn must be a number"
is_number "$MAX_FAIL" || error "--max-fail must be a fraction such as 0.01"
is_number "$P95_MS" || error "--p95-ms must be a number"
is_number "$TIME_SCALE" || error "--time-scale must be a number"
[[ "$STORE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || error "--store must be a store slug (lowercase letters, digits, dashes)"
[[ "$SCENARIO" =~ ^[A-Za-z0-9_./:,-]+$ ]] || error "--scenario has unexpected characters"
[[ -z "$SEED" || "$SEED" =~ ^[A-Za-z0-9_.-]+$ ]] || error "--seed has unexpected characters"
for v in "$STEP_USERS" "$STEP_SECONDS" "$MAX_USERS"; do [[ -z "$v" ]] || is_int "$v" || error "step and max values must be whole numbers"; done
if [[ -n "$IP" || -n "$DOMAIN" ]]; then
  [[ -n "$IP" && -n "$DOMAIN" ]] || error "--ip and --domain go together"
  [[ "$IP" =~ ^[A-Za-z0-9.-]+$ ]] || error "--ip has unexpected characters"
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || error "--domain has unexpected characters"
  BASES+=("api=http://$IP" "admin=http://$IP" "shop=http://$IP")
  HOSTHDRS+=("api=api.$DOMAIN" "admin=admin.$DOMAIN" "shop=$DOMAIN")
fi
for b in "${BASES[@]}"; do [[ "$b" =~ ^[a-z][a-z0-9_]*=https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~/-]*)?$ ]] || error "Invalid --base '$b' (expected key=http(s)://host[:port])"; done
for h in "${HOSTHDRS[@]}"; do [[ "$h" =~ ^[a-z][a-z0-9_]*=[A-Za-z0-9.-]+$ ]] || error "Invalid --host-header '$h' (expected key=name)"; done
for v in "${EXTRA_VARS[@]}"; do [[ "$v" =~ ^[a-z][a-z0-9_]*=.+$ ]] || error "Invalid --var '$v' (expected name=value)"; done
[[ ${#BASES[@]} -gt 0 ]] || error "No target: give --ip and --domain, or --base key=URL"

PASSWORD="${LT_VAR_PASSWORD:-}"
if [[ -n "$PASSWORD_FILE" ]]; then
  [[ -r "$PASSWORD_FILE" ]] || error "Cannot read --password-file $PASSWORD_FILE"
  PASSWORD="$(tr -d '\r\n' <"$PASSWORD_FILE")"
fi
if [[ "$PASSWORD" =~ [[:cntrl:]] ]]; then
  error "The password contains control characters. Pasting into a terminal often adds invisible markers (shown as ^[[200~ and ~).
  Recreate the file by typing the password at a prompt:   read -rs -p 'Password: ' p; printf '%s' \"\$p\" > FILE; unset p
  and check it with:   cat -A FILE   (it must show only the password)"
fi

if [[ -n "$ACCOUNTS_FILE" ]]; then
  [[ -r "$ACCOUNTS_FILE" ]] || error "Cannot read --accounts-file $ACCOUNTS_FILE"
  if grep -q '[[:cntrl:]]' < <(tr -d '\r\n\t' <"$ACCOUNTS_FILE"); then
    error "--accounts-file contains control characters (terminal paste markers?). Create it in a text editor."
  fi
fi

# the largest number of people the run can put on the site
case "$PROFILE" in
  smoke) PEAK=5 ;;
  average | soak) PEAK="$USERS" ;;
  peak) PEAK=$((USERS * 3)) ;;
  spike) PEAK=$((USERS * 4)) ;;
  breakpoint) PEAK="${MAX_USERS:-400}" ;;
esac
if [[ "$PEAK" -gt 200 && "$ALLOW_LARGE" -eq 0 ]]; then
  error "This plan reaches $PEAK users; pass --allow-large if you really mean it"
fi

# ── scenarios must be valid, and every host they use needs a base URL ─────────
# python3 on Linux/macOS, python on Windows (where "python3" is often a Microsoft Store stub that
# fails when run), or the "py" launcher: take the first one that really runs and is 3.9 or newer.
declare -a PY=()
for candidate in "${PYTHON:-}" python3 python py; do
  if [[ -z "$candidate" ]] || ! command -v "$candidate" >/dev/null 2>&1; then continue; fi
  probe=("$candidate"); [[ "$candidate" != "py" ]] || probe=(py -3)
  if "${probe[@]}" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then PY=("${probe[@]}"); break; fi
done
[[ ${#PY[@]} -gt 0 ]] || error "Python 3.9 or newer was not found (tried python3, python, py). Install it from python.org and make sure it is on PATH."
declare -a FILES=()
IFS=',' read -ra ITEMS <<<"$SCENARIO"
for item in "${ITEMS[@]}"; do
  name="${item%%:*}"
  if [[ -f "$name" ]]; then FILES+=("$name"); else FILES+=("$HERE/scenarios/$name.json"); fi
done
CHECK_OUT="$("${PY[@]}" "$HERE/humanlib.py" "${FILES[@]}")" || error "Scenario problem:
$CHECK_OUT"
CHECK_OUT="${CHECK_OUT//$'\r'/}" # Windows Python ends lines with CRLF
for host in $(grep -oE 'hosts=[A-Za-z0-9_,]+' <<<"$CHECK_OUT" | cut -d= -f2 | tr ',' '\n' | sort -u); do
  found=0
  for b in "${BASES[@]}"; do [[ "${b%%=*}" == "$host" ]] && found=1; done
  [[ "$found" -eq 1 ]] || error "The scenarios use host '$host': add --base $host=URL (or --ip/--domain)"
done

# the name the operator must type: the Host header of the first target, else its URL host
first="${BASES[0]}"; CONFIRM_NAME="${first#*=}"; CONFIRM_NAME="${CONFIRM_NAME#*://}"; CONFIRM_NAME="${CONFIRM_NAME%%[:/]*}"
for h in "${HOSTHDRS[@]}"; do [[ "${h%%=*}" == "${first%%=*}" ]] && CONFIRM_NAME="${h#*=}"; done

[[ -n "$OUT" ]] || OUT="$HERE/results/$(date +%Y%m%d-%H%M%S)"

section "Load test plan"
printf '  %-14s %s\n' "Scenarios" "$SCENARIO"
printf '  %-14s %s (normal %s users, at most %s)\n' "Profile" "$PROFILE" "$USERS" "$PEAK"
for b in "${BASES[@]}"; do
  key="${b%%=*}"; hh=""
  for h in "${HOSTHDRS[@]}"; do [[ "${h%%=*}" == "$key" ]] && hh="  (Host: ${h#*=})"; done
  printf '  %-14s %s%s\n' "Target $key" "${b#*=}" "$hh"
done
printf '  %-14s %s\n' "Store" "$STORE"
if [[ -n "$ACCOUNTS_FILE" ]]; then
  LOGIN_NOTE="one account per person ($(grep -c . "$ACCOUNTS_FILE") accounts)"
elif [[ "$SHARE_LOGIN" -eq 1 ]]; then
  LOGIN_NOTE="one shared account, logged in once"
else
  LOGIN_NOTE="one shared account, every person logs in"
fi
printf '  %-14s %s\n' "Logins" "$LOGIN_NOTE"
printf '  %-14s %s\n' "Writes data" "$([[ $WRITES -eq 1 ]] && echo 'YES (carts / orders are created)' || echo no)"
printf '  %-14s fail > %s%% or p95 > %s ms\n' "Fails when" "$(awk -v f="$MAX_FAIL" 'BEGIN { printf "%g", f * 100 }')" "$P95_MS"
printf '  %-14s %s\n' "Results" "$OUT"
echo
[[ "$CHECK_ONLY" -eq 0 ]] || { info "Check only: scenarios are valid and nothing was sent."; exit 0; }

warn "Only run this against servers you own or have written permission to test."
[[ "$WRITES" -eq 0 ]] || warn "Writes are enabled: use a dedicated test store, never one with real orders."
if [[ "$ASSUME_YES" -eq 0 ]]; then
  [[ -t 0 ]] || error "Not an interactive terminal: pass --yes to confirm in automation"
  read -rp "Type the target name ($CONFIRM_NAME) to start: " answer || answer=""
  [[ "$answer" == "$CONFIRM_NAME" ]] || error "Cancelled: nothing was sent."
fi

# ── Python environment ────────────────────────────────────────────────────────
if [[ "$NO_VENV" -eq 1 ]]; then
  LOCUST="$(command -v locust)" || error "locust is not on PATH"
else
  VENV="${LT_VENV:-$HERE/.venv}"
  case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) VBIN="$VENV/Scripts"; EXE=".exe" ;; *) VBIN="$VENV/bin"; EXE="" ;; esac
  if [[ ! -x "$VBIN/locust$EXE" ]]; then
    info "Setting up the load-test environment in $VENV (once) ..."
    "${PY[@]}" -m venv "$VENV" || error "Could not create a virtual environment (on Debian/Ubuntu: install python3-venv)"
    "$VBIN/python$EXE" -m pip install -q -r "$HERE/requirements.txt" || error "pip could not install the load-test requirements"
  fi
  LOCUST="$VBIN/locust$EXE"
fi

mkdir -p "$OUT"
export LT_SCENARIO="$SCENARIO" LT_PROFILE="$PROFILE" LT_USERS="$USERS" LT_HOLD="$HOLD" LT_SPAWN="$SPAWN"
export LT_WRITES="$WRITES" LT_MAX_FAIL="$MAX_FAIL" LT_P95_MS="$P95_MS" LT_TIME_SCALE="$TIME_SCALE" LT_OUT="$OUT"
export LT_VAR_STORE="$STORE" LT_SHARE_LOGIN="$SHARE_LOGIN"
[[ -z "$ACCOUNTS_FILE" ]] || export LT_ACCOUNTS_FILE="$ACCOUNTS_FILE"
[[ -z "$EMAIL" ]] || export LT_VAR_EMAIL="$EMAIL"
[[ -z "$PASSWORD" ]] || export LT_VAR_PASSWORD="$PASSWORD"
[[ -z "$SEED" ]] || export LT_SEED="$SEED"
[[ -z "$STEP_USERS" ]] || export LT_STEP_USERS="$STEP_USERS"
[[ -z "$STEP_SECONDS" ]] || export LT_STEP_SECONDS="$STEP_SECONDS"
[[ -z "$MAX_USERS" ]] || export LT_MAX_USERS="$MAX_USERS"
for b in "${BASES[@]}"; do export "LT_BASE_$(tr '[:lower:]' '[:upper:]' <<<"${b%%=*}")=${b#*=}"; done
for h in "${HOSTHDRS[@]}"; do export "LT_HOSTHDR_$(tr '[:lower:]' '[:upper:]' <<<"${h%%=*}")=${h#*=}"; done
for v in "${EXTRA_VARS[@]}"; do export "LT_VAR_$(tr '[:lower:]' '[:upper:]' <<<"${v%%=*}")=${v#*=}"; done

log "Starting: results go to $OUT"
args=(-f "$HERE/locustfile.py" --headless --csv "$OUT/stats" --html "$OUT/report.html")
[[ "$VERBOSE" -eq 1 ]] || args+=(--only-summary)
cd "$HERE"
exec "$LOCUST" "${args[@]}"
