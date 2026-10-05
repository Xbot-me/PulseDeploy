#!/usr/bin/env bash
# Runs crm.sh's smoke_tests against tests/smoke_mock.py.   smoke_case.sh <mode> <store-name-check 0|1> [timer-state]
# shellcheck disable=SC2034,SC2317  # variables and stubs are read by the sourced smoke_tests function
# Prints the number of failed checks and their names; exit status = number of failures.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="$1"; NAMECHK="$2"; TIMER="${3:-active}"
source "$ROOT/scripts/lib/common.sh" 2>/dev/null
source "$ROOT/scripts/lib/crm.sh"
# the two functions under test, taken from the real file
# shellcheck source=/dev/null
source <(awk '/^SMOKE_FAILED=\(\)/{p=1} p{print} /^smoke_tests\(\)/{f=1} f&&/^}$/{exit}' "$ROOT/crm.sh")
PORT=$((20000 + RANDOM % 20000))
python3 "$ROOT/tests/smoke_mock.py" "$PORT" "Acme Shop" "$MODE" & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/up" && break; sleep 0.1; done
export CRM_LOCAL_URL="http://127.0.0.1:$PORT"
# shellcheck disable=SC2317  # called by the smoke_tests function under test
systemctl() { [[ "$1" == "is-active" && "$TIMER" == "active" ]]; }
component_selected() { true; }
API_HOST=api.t.test; ADMIN_HOST=admin.t.test; SHOP_HOST=shop.t.test; STORE=acme; STORE_NAME="Acme Shop"
ADMIN_EMAIL=a@t.test; ADMIN_PASSWORD=pw; SF_NAME=gadgets; CERTBOT=0
CD_SERVER_OPT=(--serve-storage --no-queue)
CD_SMOKE_INFO_PATH=/api/v1/storefront/web-info; CD_SMOKE_STORE_NAME="$NAMECHK"
CD_ADMIN_LOGIN_PATH=/api/auth/login; CD_ADMIN_LOGIN_HEADER="X-Store-Subdomain: {STORE}"
declare -A CRM_VARS=([STORE]=acme)
rc=0; smoke_tests >/dev/null 2>&1 || rc=$?
printf '%s failed:' "$rc"; printf ' [%s]' "${SMOKE_FAILED[@]}"; echo
exit "$rc"
