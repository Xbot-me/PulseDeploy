#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - loadtest/seed/seed.sh: realistic test data for a CRM store
#
#   sudo bash loadtest/seed/seed.sh --store loadtest --create-store
#   sudo bash loadtest/seed/seed.sh --store loadtest --purge
#
# Run it ON the server (it talks to the local database). It only ever touches a
# store that holds no real data, and never the live store from /etc/pulsedeploy/crm.conf.
# Everything it adds is marked, so --purge removes exactly that. Details: docs/load-testing.md
# =============================================================================
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

STORE=""; PRODUCTS=5000; CUSTOMERS=20000; ORDERS=100000; MONTHS=12; SEED=1
CREATE_STORE=0; PURGE=0; ASSUME_YES=0; DRY_RUN=0
MAX_PRODUCTS=200000; MAX_CUSTOMERS=1000000; MAX_ORDERS=1000000
MYSQL=(mysql)
ADMIN_EMAIL="lt@loadtest.test"
CRED_FILE="/root/loadtest-store-credentials.txt"

usage() {
  cat <<'EOF2'
Usage: sudo bash loadtest/seed/seed.sh --store <slug> [options]

  --store <slug>        the test store (database zymerce_tenant_<slug>); required
  --create-store        create the store first (needs the installed CRM); the admin login
                        is saved to /root/loadtest-store-credentials.txt
  --products <n>        default 5000   (max 200000)
  --customers <n>       default 20000  (max 1000000)
  --orders <n>          default 100000 (max 1000000)
  --months <n>          spread orders over this many months, default 12 (1-60)
  --seed <n>            same number, same data (default 1)
  --purge               remove everything this tool added, then stop
  --dry-run             show the plan and the disk estimate, change nothing
  --yes                 do not ask for confirmation
EOF2
}

need_value() { [[ $# -ge 2 && "$2" != --* ]] || error "$1 needs a value"; }
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --store)        need_value "$@"; STORE="$2"; shift 2 ;;
    --products)     need_value "$@"; PRODUCTS="$2"; shift 2 ;;
    --customers)    need_value "$@"; CUSTOMERS="$2"; shift 2 ;;
    --orders)       need_value "$@"; ORDERS="$2"; shift 2 ;;
    --months)       need_value "$@"; MONTHS="$2"; shift 2 ;;
    --seed)         need_value "$@"; SEED="$2"; shift 2 ;;
    --create-store) CREATE_STORE=1; shift ;;
    --purge)        PURGE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; error "Unknown option: $1" ;;
  esac
done

[[ -n "$STORE" ]] || { usage >&2; error "--store is required"; }
[[ "$STORE" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || error "--store must be lower-case letters, digits and dashes"
for pair in "products:$PRODUCTS" "customers:$CUSTOMERS" "orders:$ORDERS" "months:$MONTHS" "seed:$SEED"; do
  is_num "${pair#*:}" || error "--${pair%%:*} must be a whole number (got '${pair#*:}')"
done
((PRODUCTS >= 10 && PRODUCTS <= MAX_PRODUCTS)) || error "--products must be 10..$MAX_PRODUCTS"
((CUSTOMERS >= 10 && CUSTOMERS <= MAX_CUSTOMERS)) || error "--customers must be 10..$MAX_CUSTOMERS"
((ORDERS >= 10 && ORDERS <= MAX_ORDERS)) || error "--orders must be 10..$MAX_ORDERS"
((MONTHS >= 1 && MONTHS <= 60)) || error "--months must be 1..60"

DB="zymerce_tenant_${STORE//-/_}"

# The live store must never be seeded.
LIVE=""
if [[ -r /etc/pulsedeploy/crm.conf ]]; then
  LIVE="$(sed -n 's/^STORE=//p' /etc/pulsedeploy/crm.conf | head -n1 | tr -d "'\"")"
fi
[[ -z "$LIVE" || "$STORE" != "$LIVE" ]] || error "'$STORE' is the live store from /etc/pulsedeploy/crm.conf. Use a separate test store."

# ~1.2 KB per order (order, lines, payment, history) plus products and customers, with indexes.
est_mb() { echo $(((ORDERS * 14 / 10 + CUSTOMERS * 1 + PRODUCTS * 4) / 1024 + 20)); }
EST_MB="$(est_mb)"

cat <<EOF2
Plan
  database   $DB
  products   $PRODUCTS    customers $CUSTOMERS    orders $ORDERS over $MONTHS months (seed $SEED)
  disk       about ${EST_MB} MB
  mode       $([[ $PURGE -eq 1 ]] && echo "PURGE test data" || echo "add test data")$([[ $CREATE_STORE -eq 1 ]] && echo ", create the store first")
EOF2
[[ "$DRY_RUN" -eq 0 ]] || { info "Dry run: nothing changed."; exit 0; }

[[ "$(id -u)" -eq 0 ]] || error "Run as root (sudo)."
command -v mysql >/dev/null || error "mysql client not found."
mysql -e 'SELECT 1' >/dev/null 2>&1 || error "Cannot connect to the local database as root."

if [[ "$ASSUME_YES" -eq 0 ]]; then
  read -r -p "Type the store name '$STORE' to continue: " answer
  [[ "$answer" == "$STORE" ]] || error "Not confirmed."
fi

db_exists() { [[ -n "$("${MYSQL[@]}" -N -e "SELECT 1 FROM information_schema.schemata WHERE schema_name='$DB'")" ]]; }

if [[ "$CREATE_STORE" -eq 1 ]]; then
  db_exists && error "Store '$STORE' already exists; drop --create-store to use it."
  [[ -r /etc/pulsedeploy/pulse.conf ]] || error "No /etc/pulsedeploy/pulse.conf: the CRM is not installed here."
  # shellcheck source=/dev/null
  source /etc/pulsedeploy/pulse.conf
  # shellcheck source=scripts/lib/crm.sh
  source "$ROOT/scripts/lib/crm.sh"
  APP_USER="${APP_USER:-deploy}"
  PASS="$(generate_password 20)"
  info "Creating store '$STORE'..."
  crm_store_create "${PHP_BIN:-php}" "already provisioned" store:create "Load Test" "$STORE" \
    "--email=$ADMIN_EMAIL" "--password=$PASS" || { rc=$?; [[ $rc -eq 2 ]] && error "Store already exists."; error "store:create failed."; }
  umask 077
  printf 'store=%s\nemail=%s\npassword=%s\n' "$STORE" "$ADMIN_EMAIL" "$PASS" >"$CRED_FILE"
  log "Admin login saved to $CRED_FILE (mode 600)."
fi

db_exists || error "Database $DB does not exist. Create the store first (--create-store)."

if [[ "$PURGE" -eq 1 ]]; then
  "${MYSQL[@]}" "$DB" <"$HERE/purge.sql"
  log "Test data removed from $DB."
  exit 0
fi

# Only a store without real data may be seeded: anything not made by this tool is "real".
real="$("${MYSQL[@]}" -N "$DB" -e "
  SELECT (SELECT COUNT(*) FROM products WHERE sku NOT LIKE 'LT-%')
       + (SELECT COUNT(*) FROM orders WHERE order_no NOT LIKE 'LT-%')
       + (SELECT COUNT(*) FROM customers WHERE email NOT LIKE 'lt%@loadtest.example')" 2>/dev/null)" \
  || error "$DB does not look like a CRM store database."
[[ "$real" -eq 0 ]] || error "$DB holds $real products/orders/customers that are not test data. Refusing; use a fresh store."

existing="$("${MYSQL[@]}" -N "$DB" -e "SELECT COUNT(*) FROM orders WHERE order_no LIKE 'LT-%'")"
[[ "$existing" -eq 0 ]] || error "$DB already has $existing test orders. Run with --purge first."

free_mb="$(df -Pm "$("${MYSQL[@]}" -N -e 'SELECT @@datadir')" | awk 'NR==2{print $4}')"
((free_mb > EST_MB * 3)) || error "Not enough free disk: ${free_mb} MB free, about $((EST_MB * 3)) MB needed (data, indexes and temp)."

info "Seeding $DB..."
start=$SECONDS
{
  printf 'SET @lt_products=%d, @lt_customers=%d, @lt_orders=%d, @lt_months=%d, @lt_seed=%d;\n' \
    "$PRODUCTS" "$CUSTOMERS" "$ORDERS" "$MONTHS" "$SEED"
  cat "$HERE/seed.sql"
} | "${MYSQL[@]}" "$DB" --table

info "Updating table statistics..."
for t in products product_variants customers orders ordered_products payments order_status_history; do
  "${MYSQL[@]}" "$DB" -e "ANALYZE TABLE $t" >/dev/null 2>&1 || true
done
log "Done in $((SECONDS - start)) s. Run the load test with:  --store $STORE --email $ADMIN_EMAIL"
