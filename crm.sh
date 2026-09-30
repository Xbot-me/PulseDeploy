#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - crm.sh: pull, build, install and configure a whole CRM
# (Laravel API + Next.js admin) with a chosen storefront, on one server.
#
#   sudo bash crm.sh install --domain example.com --storefront <id|git-url|none> [...]
#   sudo pulse-crm update [--only backend,admin,storefront]
#   bash crm.sh storefronts
#
# Definitions live in apps/ (see apps/README.md). Run "crm.sh help" for options.
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CRM_VERSION="1.0.0"
CRM_LOG="${PULSE_CRM_LOG:-/var/log/pulsedeploy-crm.log}"
# shellcheck source=scripts/lib/crm.sh
source "$ROOT/scripts/lib/crm.sh"

trap 'printf "%s\n" "${RED}[error]${RESET} failed at ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ── options ───────────────────────────────────────────────────────────────────
CMD=""
CRM_ID="aventech"; CRM_REPO_OVERRIDE=""; CRM_REF_OVERRIDE=""
STOREFRONT=""; SF_REF_OVERRIDE=""; SF_DIR_OVERRIDE=""; SF_BUILD_CMD_OVERRIDE=""
SF_BUILD_ENV_CLI=(); SF_RUNTIME_ENV_CLI=()
DOMAIN=""; EMAIL=""; API_HOST=""; ADMIN_HOST=""; SHOP_HOST=""; SCHEME=""
CLOUDFLARE=0; CERTBOT=0; APP_USER="deploy"; APP_NAME=""
STORE=""; STORE_NAME=""; ADMIN_EMAIL=""; ADMIN_PASSWORD=""
GIT_TOKEN_FILE=""; GIT_SSH_KEY=""; REGISTRY_DIR=""
SKIP_SERVER=0; CHECK_ONLY=0; DRY_RUN=0; ASSUME_YES=0; RESET_ENV=0; ONLY=""
BOOTSTRAP_ARGS=()
CRM_GIT_TOKEN="${PULSE_GIT_TOKEN:-}"

print_help() {
  cat <<EOF
${BOLD}USAGE${RESET}
  sudo bash crm.sh install --domain <domain> --storefront <id|git-url|none> [options]
  sudo pulse-crm update  [--only backend,admin,storefront] [--crm-ref REF] [--storefront-ref REF]
  bash crm.sh storefronts          list the storefronts you can choose from
  bash crm.sh help

${BOLD}WHAT install DOES${RESET}
  1. checks the repositories are reachable (before touching the server)
  2. provisions the server (nginx, PHP, MySQL, Redis, Node, firewall, TLS)
  3. pulls, builds and deploys the CRM backend, the admin app and the storefront
  4. creates the first store and its admin login
  5. runs smoke tests and prints the URLs

${BOLD}REQUIRED${RESET}
  --domain <domain>          Main domain, for example example.com
  --storefront <choice>      A storefront id (see "storefronts"), a Git URL, or "none"

${BOLD}FIRST STORE${RESET}
  --store <slug>             Tenant slug (default: main)
  --store-name <name>        Display name (default: My Store)
  --admin-email <email>      First admin login (default: admin@<domain>)
  --admin-password <pass>    Default: generated and saved to /root/pulsedeploy-crm-credentials.txt
  --app-name <name>          Name shown in the admin app (default: the CRM's name)

${BOLD}WHAT TO INSTALL${RESET}
  --crm <id>                 CRM definition in apps/crm/ (default: aventech)
  --crm-repo <url>           Override the CRM repository
  --crm-ref <ref>            Branch, tag or commit (default from the definition)
  --storefront-ref <ref>     Storefront branch, tag or commit
  --storefront-dir <path>    Folder inside the storefront repo holding package.json
  --storefront-build-cmd <c> Build command (default: npm ci && npm run build)
  --storefront-build-env K=V   Build-time variable, repeatable (NEXT_PUBLIC_* are compiled in)
  --storefront-runtime-env K=V Runtime variable for the storefront server, repeatable
                             Values may use {API_URL} {SHOP_URL} {ADMIN_URL}
                             {INTERNAL_API_URL} {STORE} {STORE_NAME} {DOMAIN}
  --registry-dir <dir>       Extra definitions (same layout as apps/)

${BOLD}PRIVATE REPOSITORIES${RESET}
  --git-token-file <file>    File containing a GitHub/GitLab token (or env PULSE_GIT_TOKEN)
  --git-ssh-key <file>       SSH private key for git@ URLs

${BOLD}SERVER${RESET}
  --email <email>            Certificate notices (needed with --certbot)
  --certbot                  Issue TLS certificates (DNS must already point here)
  --cloudflare               Cloudflare proxy in front (real client IPs, https URLs)
  --scheme <http|https>      URL scheme used in generated settings (default: https with
                             --certbot or --cloudflare, otherwise http)
  --api-host / --admin-host / --shop-host <host>   Override api.<d>, admin.<d>, <d>
  --app-user <name>          Deploy/runtime user (default: deploy)
  --                         Everything after -- goes to bootstrap.sh (--hostname,
                             --timezone, --swap-size, --ssh-port, --disable-root-ssh, ...)

${BOLD}FLOW${RESET}
  --skip-server              Server already provisioned; only pull, build and deploy
  --only <list>              With update/install: backend,admin,storefront
  --reset-env                Overwrite existing values of managed settings (default: keep)
  --check                    Validate options and repository access, then stop
  --dry-run                  Print the plan, then stop
  -y, --yes                  No confirmation prompt

${BOLD}EXAMPLE${RESET}
  sudo bash crm.sh install --domain example.com --email me@example.com --certbot \\
    --storefront https://github.com/your-org/your-storefront.git \\
    --store-name "Acme Shop" --store acme \\
    --git-token-file /root/gh-token --cloudflare -- --timezone Asia/Dhaka --swap-size 2G
EOF
}

need_value() { [[ $# -ge 2 && -n "$2" ]] || error "Option $1 requires a value (see: crm.sh help)"; }

parse_args() {
  CMD="${1:-help}"
  shift || true
  local -a args=()
  local a seen_dd=0
  for a in "$@"; do
    if [[ "$seen_dd" -eq 0 && "$a" == --*=* ]]; then args+=("${a%%=*}" "${a#*=}"); else args+=("$a"); fi
    [[ "$a" == "--" ]] && seen_dd=1
  done
  set -- "${args[@]+"${args[@]}"}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)                need_value "$@"; DOMAIN="$2"; shift 2 ;;
      --storefront)            need_value "$@"; STOREFRONT="$2"; shift 2 ;;
      --store)                 need_value "$@"; STORE="$2"; shift 2 ;;
      --store-name)            need_value "$@"; STORE_NAME="$2"; shift 2 ;;
      --admin-email)           need_value "$@"; ADMIN_EMAIL="$2"; shift 2 ;;
      --admin-password)        need_value "$@"; ADMIN_PASSWORD="$2"; shift 2 ;;
      --app-name)              need_value "$@"; APP_NAME="$2"; shift 2 ;;
      --crm)                   need_value "$@"; CRM_ID="$2"; shift 2 ;;
      --crm-repo)              need_value "$@"; CRM_REPO_OVERRIDE="$2"; shift 2 ;;
      --crm-ref)               need_value "$@"; CRM_REF_OVERRIDE="$2"; shift 2 ;;
      --storefront-ref)        need_value "$@"; SF_REF_OVERRIDE="$2"; shift 2 ;;
      --storefront-dir)        need_value "$@"; SF_DIR_OVERRIDE="$2"; shift 2 ;;
      --storefront-build-cmd)  need_value "$@"; SF_BUILD_CMD_OVERRIDE="$2"; shift 2 ;;
      --storefront-build-env)  need_value "$@"; SF_BUILD_ENV_CLI+=("$2"); shift 2 ;;
      --storefront-runtime-env) need_value "$@"; SF_RUNTIME_ENV_CLI+=("$2"); shift 2 ;;
      --registry-dir)          need_value "$@"; REGISTRY_DIR="$2"; shift 2 ;;
      --git-token-file)        need_value "$@"; GIT_TOKEN_FILE="$2"; shift 2 ;;
      --git-ssh-key)           need_value "$@"; GIT_SSH_KEY="$2"; shift 2 ;;
      --email)                 need_value "$@"; EMAIL="$2"; shift 2 ;;
      --certbot)               CERTBOT=1; shift ;;
      --cloudflare)            CLOUDFLARE=1; shift ;;
      --scheme)                need_value "$@"; SCHEME="$2"; shift 2 ;;
      --api-host)              need_value "$@"; API_HOST="$2"; shift 2 ;;
      --admin-host)            need_value "$@"; ADMIN_HOST="$2"; shift 2 ;;
      --shop-host)             need_value "$@"; SHOP_HOST="$2"; shift 2 ;;
      --app-user)              need_value "$@"; APP_USER="$2"; shift 2 ;;
      --skip-server)           SKIP_SERVER=1; shift ;;
      --only)                  need_value "$@"; ONLY="$2"; shift 2 ;;
      --reset-env)             RESET_ENV=1; shift ;;
      --check)                 CHECK_ONLY=1; shift ;;
      --dry-run)               DRY_RUN=1; shift ;;
      -y|--yes)                ASSUME_YES=1; shift ;;
      -h|--help)               CMD="help"; shift ;;
      --)                      shift; BOOTSTRAP_ARGS=("$@"); break ;;
      *) error "Unknown option: $1 (see: crm.sh help)" ;;
    esac
  done
}

# ── definitions ───────────────────────────────────────────────────────────────
find_def() { # find_def <crm|storefronts> <id>
  local kind="$1" id="$2" d
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  for d in "$REGISTRY_DIR" "$ROOT/apps"; do
    if [[ -n "$d" && -f "$d/$kind/$id.conf" ]]; then printf '%s' "$d/$kind/$id.conf"; return 0; fi
  done
  return 1
}

list_storefronts() {
  local d f id
  echo "Available storefronts (use with --storefront):"
  for d in "$REGISTRY_DIR" "$ROOT/apps"; do
    [[ -n "$d" && -d "$d/storefronts" ]] || continue
    for f in "$d"/storefronts/*.conf; do
      [[ -f "$f" ]] || continue
      id="$(basename "$f" .conf)"
      printf '  %-18s %s\n' "$id" "$(sed -n 's/^NAME=//p' "$f" | head -n 1) ($(sed -n 's/^REPO=//p' "$f" | head -n 1))"
    done
  done
  echo "  <git-url>          any Next.js storefront repository (https://... or git@...)"
  echo "  none               install the CRM without a storefront"
  echo
  echo "Add your own by copying apps/storefronts/sample.conf.disabled to <id>.conf"
}

valid_git_url() { [[ "$1" =~ ^(https://|http://|ssh://|git@)[A-Za-z0-9._@:/~+-]+$ ]]; }
valid_ref()     { [[ "$1" =~ ^[A-Za-z0-9._/@-]{1,100}$ && "$1" != *..* ]]; }
valid_subdir()  { [[ "$1" =~ ^[A-Za-z0-9._/-]*$ && "$1" != *..* && "$1" != /* ]]; }
valid_kv()      { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }
valid_slug()    { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,30}$ ]]; }

load_definitions() {
  local file
  file="$(find_def crm "$CRM_ID")" || error "Unknown CRM '$CRM_ID' (definitions: $(for f in "$ROOT"/apps/crm/*.conf; do basename "$f" .conf; done | tr '\n' ' '))"
  registry_load "$file" CD \
    "NAME REPO REF BACKEND_DIR ADMIN_DIR DB_NAME DB_USER TENANT_DB_PREFIX STORE_EXISTS_TEXT ADMIN_LOGIN_PATH ADMIN_LOGIN_HEADER" \
    "SERVER_OPT BACKEND_ENV ADMIN_BUILD_ENV ADMIN_RUNTIME_ENV STORE_ARG"
  [[ -z "$CRM_REPO_OVERRIDE" ]] || CD_REPO="$CRM_REPO_OVERRIDE"
  [[ -z "$CRM_REF_OVERRIDE" ]]  || CD_REF="$CRM_REF_OVERRIDE"
  CD_REF="${CD_REF:-main}"
  local o
  for o in "${CD_SERVER_OPT[@]}"; do [[ "$o" =~ ^--[a-z-]+$ ]] || error "CRM definition has an invalid server option '$o'"; done
}

# Sets SF_REPO SF_REF SF_DIR SF_BUILD_CMD SF_NAME and the SF_BUILD_ENV / SF_RUNTIME_ENV lists
resolve_storefront() {
  SF_NAME=""; SF_REPO=""; SF_REF="main"; SF_DIR="."; SF_BUILD_CMD="npm ci && npm run build"
  SF_BUILD_ENV=(); SF_RUNTIME_ENV=()
  case "$STOREFRONT" in
    none|"") SF_NAME="none" ;;
    *)
      if valid_git_url "$STOREFRONT"; then
        SF_NAME="$STOREFRONT"; SF_REPO="$STOREFRONT"
      else
        local file
        file="$(find_def storefronts "$STOREFRONT")" ||
          error "Unknown storefront '$STOREFRONT'. Use an id from 'crm.sh storefronts', a Git URL, or 'none'."
        registry_load "$file" SD "NAME REPO REF DIR BUILD_CMD" "BUILD_ENV RUNTIME_ENV"
        [[ -n "$SD_REPO" ]] || error "$file: REPO is required"
        SF_NAME="${SD_NAME:-$STOREFRONT}"; SF_REPO="$SD_REPO"
        [[ -z "$SD_REF" ]] || SF_REF="$SD_REF"
        [[ -z "$SD_DIR" ]] || SF_DIR="$SD_DIR"
        [[ -z "$SD_BUILD_CMD" ]] || SF_BUILD_CMD="$SD_BUILD_CMD"
        SF_BUILD_ENV=("${SD_BUILD_ENV[@]}"); SF_RUNTIME_ENV=("${SD_RUNTIME_ENV[@]}")
      fi
      [[ -z "$SF_REF_OVERRIDE" ]]       || SF_REF="$SF_REF_OVERRIDE"
      [[ -z "$SF_DIR_OVERRIDE" ]]       || SF_DIR="$SF_DIR_OVERRIDE"
      [[ -z "$SF_BUILD_CMD_OVERRIDE" ]] || SF_BUILD_CMD="$SF_BUILD_CMD_OVERRIDE"
      SF_BUILD_ENV+=("${SF_BUILD_ENV_CLI[@]}"); SF_RUNTIME_ENV+=("${SF_RUNTIME_ENV_CLI[@]}")
      ;;
  esac
}

# ── validation ────────────────────────────────────────────────────────────────
validate_options() {
  [[ -n "$DOMAIN" ]] || error "--domain is required (for example --domain example.com)"
  valid_domain "$DOMAIN" || error "Invalid --domain '$DOMAIN'"
  if [[ "$CMD" == "install" && -z "$STOREFRONT" ]]; then
    error "--storefront is required: an id, a Git URL, or 'none'. See: bash crm.sh storefronts"
  fi
  [[ -z "$EMAIL" ]] || valid_email "$EMAIL" || error "Invalid --email '$EMAIL'"
  [[ "$CERTBOT" -eq 0 || -n "$EMAIL" ]] || error "--certbot needs --email (Let's Encrypt registration)"
  local h
  for h in "$API_HOST" "$ADMIN_HOST" "$SHOP_HOST"; do
    [[ -z "$h" ]] || valid_domain "$h" || error "Invalid host name '$h'"
  done
  [[ -z "$SCHEME" || "$SCHEME" == "http" || "$SCHEME" == "https" ]] || error "--scheme must be http or https"
  [[ "$APP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$APP_USER" != "root" ]] || error "Invalid --app-user '$APP_USER'"
  [[ -z "$STORE" ]] || valid_slug "$STORE" || error "Invalid --store '$STORE' (lowercase letters, digits, - and _)"
  [[ -z "$STORE_NAME" || "$STORE_NAME" =~ ^[^[:cntrl:]]{1,80}$ ]] || error "Invalid --store-name"
  [[ -z "$ADMIN_EMAIL" ]] || valid_email "$ADMIN_EMAIL" || error "Invalid --admin-email '$ADMIN_EMAIL'"
  [[ -z "$ADMIN_PASSWORD" || ${#ADMIN_PASSWORD} -ge 10 ]] || error "--admin-password must be at least 10 characters"
  [[ -z "$CRM_REPO_OVERRIDE" ]] || valid_git_url "$CRM_REPO_OVERRIDE" || error "Invalid --crm-repo"
  local r
  for r in "$CRM_REF_OVERRIDE" "$SF_REF_OVERRIDE"; do [[ -z "$r" ]] || valid_ref "$r" || error "Invalid git ref '$r'"; done
  [[ -z "$SF_DIR_OVERRIDE" ]] || valid_subdir "$SF_DIR_OVERRIDE" || error "Invalid --storefront-dir"
  local kv
  for kv in "${SF_BUILD_ENV_CLI[@]}" "${SF_RUNTIME_ENV_CLI[@]}"; do valid_kv "$kv" || error "Expected KEY=value, got '$kv'"; done
  local part
  IFS=',' read -ra parts <<<"$ONLY"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "backend" || "$part" == "admin" || "$part" == "storefront" ]] || error "--only accepts backend, admin, storefront (got '$part')"
  done
  [[ -z "$GIT_TOKEN_FILE" || -r "$GIT_TOKEN_FILE" ]] || error "Cannot read --git-token-file $GIT_TOKEN_FILE"
  [[ -z "$GIT_SSH_KEY" || -r "$GIT_SSH_KEY" ]] || error "Cannot read --git-ssh-key $GIT_SSH_KEY"
  return 0
}

component_selected() { [[ -z "$ONLY" || ",${ONLY}," == *",$1,"* ]]; }

setup_vars() {
  STORE="${STORE:-main}"
  STORE_NAME="${STORE_NAME:-My Store}"
  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
  APP_NAME="${APP_NAME:-$CD_NAME}"
  API_HOST="${API_HOST:-api.${DOMAIN}}"
  ADMIN_HOST="${ADMIN_HOST:-admin.${DOMAIN}}"
  SHOP_HOST="${SHOP_HOST:-${DOMAIN}}"
  if [[ -z "$SCHEME" ]]; then
    if [[ "$CERTBOT" -eq 1 || "$CLOUDFLARE" -eq 1 ]]; then SCHEME="https"; else SCHEME="http"; fi
  fi
  CRM_VARS=(
    [API_URL]="${SCHEME}://${API_HOST}" [ADMIN_URL]="${SCHEME}://${ADMIN_HOST}" [SHOP_URL]="${SCHEME}://${SHOP_HOST}"
    [INTERNAL_API_URL]="http://127.0.0.1:8081" [STORE]="$STORE" [STORE_NAME]="$STORE_NAME"
    [ADMIN_EMAIL]="$ADMIN_EMAIL" [DOMAIN]="$DOMAIN" [APP_NAME]="$APP_NAME"
  )
}

# ── plan ──────────────────────────────────────────────────────────────────────
print_plan() {
  section "Plan"
  printf '  %-22s %s\n' "CRM" "$CD_NAME  ($CD_REPO @ $CD_REF)"
  if [[ "$SF_NAME" == "none" ]]; then
    printf '  %-22s %s\n' "Storefront" "none"
  else
    printf '  %-22s %s\n' "Storefront" "$SF_NAME  ($SF_REPO @ $SF_REF, dir $SF_DIR)"
  fi
  printf '  %-22s %s\n' "Hosts" "${SCHEME}://${API_HOST}  ${SCHEME}://${ADMIN_HOST}  ${SCHEME}://${SHOP_HOST}"
  printf '  %-22s %s\n' "First store" "$STORE_NAME  (slug $STORE, admin $ADMIN_EMAIL)"
  printf '  %-22s %s\n' "Server setup" "$([[ "$SKIP_SERVER" -eq 1 ]] && echo skipped || echo "bootstrap.sh -s laravel-next ${CD_SERVER_OPT[*]} $([[ $CERTBOT -eq 1 ]] && echo 'with TLS')")"
  printf '  %-22s %s\n' "Components" "${ONLY:-backend, admin, storefront}"
  local access="none"
  if [[ -n "$GIT_TOKEN_FILE" || -n "${PULSE_GIT_TOKEN:-}" ]]; then access="token"; elif [[ -n "$GIT_SSH_KEY" ]]; then access="ssh key"; fi
  printf '  %-22s %s\n' "Private repo access" "$access"
  echo
}

# ── steps ─────────────────────────────────────────────────────────────────────
prepare_git() {
  if [[ -n "$GIT_TOKEN_FILE" ]]; then
    CRM_GIT_TOKEN="$(tr -d '[:space:]' <"$GIT_TOKEN_FILE")"
  fi
  CRM_GIT_SSH_KEY_EFFECTIVE="$GIT_SSH_KEY"
  crm_git_setup
}

preflight_git() {
  section "Checking repositories"
  crm_git_check "$CD_REPO" "$CD_REF" "CRM repository"
  if [[ "$SF_NAME" != "none" ]] && component_selected storefront; then
    crm_git_check "$SF_REPO" "$SF_REF" "Storefront repository"
  fi
}

provision_server() {
  section "Provisioning the server"
  local -a args=(-s laravel-next --domain "$DOMAIN" --app-user "$APP_USER" -y)
  [[ -z "$CD_DB_NAME" ]] || args+=(--db-name "$CD_DB_NAME")
  [[ -z "$CD_DB_USER" ]] || args+=(--db-user "$CD_DB_USER")
  [[ -z "$CD_TENANT_DB_PREFIX" ]] || args+=(--tenant-db-prefix "$CD_TENANT_DB_PREFIX")
  [[ -z "$EMAIL" ]] || args+=(--email "$EMAIL")
  [[ -z "$API_HOST" ]] || args+=(--api-host "$API_HOST")
  [[ -z "$ADMIN_HOST" ]] || args+=(--admin-host "$ADMIN_HOST")
  [[ -z "$SHOP_HOST" ]] || args+=(--shop-host "$SHOP_HOST")
  [[ "$CLOUDFLARE" -eq 0 ]] || args+=(--cloudflare)
  [[ "$CERTBOT" -eq 0 ]] || args+=(--services certbot)
  args+=("${CD_SERVER_OPT[@]}" "${BOOTSTRAP_ARGS[@]}")
  bash "$ROOT/bootstrap.sh" "${args[@]}"
}

load_server_facts() {
  [[ -r /etc/pulsedeploy/pulse.conf ]] || error "The server is not provisioned (no /etc/pulsedeploy/pulse.conf). Run install without --skip-server."
  # shellcheck source=/dev/null
  source /etc/pulsedeploy/pulse.conf
  CRM_PHP_BIN="${PHP_BIN:-php}"
  APP_USER="${APP_USER:-deploy}"
  [[ -z "${INTERNAL_API_URL:-}" ]] || CRM_VARS[INTERNAL_API_URL]="$INTERNAL_API_URL"
  id "$APP_USER" &>/dev/null || error "User '$APP_USER' does not exist."
}

prepare_work() {
  install -d -m 755 "$CRM_WORK"
  install -d -o "$APP_USER" -g "$APP_USER" -m 750 "$CRM_WORK/build" "$CRM_WORK/src" "$CRM_WORK/artifacts"
  if [[ -n "$GIT_SSH_KEY" ]]; then
    install -d -o "$APP_USER" -g "$APP_USER" -m 700 "$CRM_WORK/ssh"
    install -m 600 -o "$APP_USER" -g "$APP_USER" "$GIT_SSH_KEY" "$CRM_WORK/ssh/key"
    CRM_GIT_SSH_KEY_EFFECTIVE="$CRM_WORK/ssh/key"
    crm_git_setup
  fi
}

env_mode() { if [[ "$RESET_ENV" -eq 1 ]]; then echo overwrite; else echo keep; fi; }

CRM_CLONED=0
clone_crm_once() {
  [[ "$CRM_CLONED" -eq 1 ]] && return 0
  section "Pulling the CRM"
  crm_clone "$CD_REPO" "$CD_REF" "$CRM_WORK/src/crm"
  CRM_CLONED=1
}

step_backend() {
  clone_crm_once
  section "Backend (Laravel API)"
  crm_env_apply /var/www/api/shared/.env "$(env_mode)" "${CD_BACKEND_ENV[@]}"
  local art
  art="$(crm_build_backend "$CRM_WORK/src/crm/$CD_BACKEND_DIR")"
  crm_as_app pulse deploy api --artifact "$art"
}

step_admin() {
  clone_crm_once
  section "Admin (Next.js)"
  crm_env_apply /var/www/admin/shared/.env "$(env_mode)" "${CD_ADMIN_RUNTIME_ENV[@]}"
  local -a benv=() e
  for e in "${CD_ADMIN_BUILD_ENV[@]}"; do benv+=("$(crm_expand "$e")"); done
  local art
  art="$(crm_build_next "$CRM_WORK/src/crm/$CD_ADMIN_DIR" admin "npm ci --no-audit --no-fund && npm run build" "${benv[@]}")"
  crm_as_app pulse deploy admin --artifact "$art"
}

step_storefront() {
  [[ "$SF_NAME" != "none" ]] || return 0
  section "Storefront ($SF_NAME)"
  crm_clone "$SF_REPO" "$SF_REF" "$CRM_WORK/src/storefront"
  crm_env_apply /var/www/shop/shared/.env "$(env_mode)" "${SF_RUNTIME_ENV[@]}"
  local -a benv=() e
  for e in "${SF_BUILD_ENV[@]}"; do benv+=("$(crm_expand "$e")"); done
  local art
  art="$(crm_build_next "$CRM_WORK/src/storefront/${SF_DIR}" shop "$SF_BUILD_CMD" "${benv[@]}")"
  crm_as_app pulse deploy shop --artifact "$art"
}

CREDS_FILE="/root/pulsedeploy-crm-credentials.txt"
step_store() {
  section "First store"
  local generated=0
  if [[ -z "$ADMIN_PASSWORD" ]]; then ADMIN_PASSWORD="$(generate_password 20)"; generated=1; fi
  CRM_VARS[ADMIN_PASSWORD]="$ADMIN_PASSWORD"
  local -a sargs=() a rc=0
  for a in "${CD_STORE_ARG[@]}"; do sargs+=("$(crm_expand "$a")"); done
  [[ ${#sargs[@]} -gt 0 ]] || { warn "The CRM definition has no STORE_ARG; skipping store creation."; unset 'CRM_VARS[ADMIN_PASSWORD]'; return 0; }
  crm_store_create "$CRM_PHP_BIN" "$CD_STORE_EXISTS_TEXT" "${sargs[@]}" || rc=$?
  case "$rc" in
    0)
      (umask 077; cat >"$CREDS_FILE" <<EOF
# PulseDeploy CRM credentials (root only). Change the password after first login.
store:    ${STORE_NAME} (${STORE})
admin:    ${SCHEME}://${ADMIN_HOST}
email:    ${ADMIN_EMAIL}
password: ${ADMIN_PASSWORD}
EOF
      )
      log "Store '${STORE}' created. Admin login saved to ${CREDS_FILE}"
      ;;
    2)
      info "Store '${STORE}' already exists; leaving it as it is."
      [[ "$generated" -eq 0 ]] || ADMIN_PASSWORD=""
      ;;
    *) error "Store creation failed (see output above)." ;;
  esac
}

smoke_tests() {
  section "Smoke tests"
  local fails=0 code
  check() { # check <label> <code> <ok-pattern>
    if [[ "$2" =~ $3 ]]; then log "$1: HTTP $2"; else warn "$1: HTTP $2 (expected $3)"; fails=$((fails + 1)); fi
  }
  code="$(crm_http_code "$API_HOST" /up)"; check "API" "$code" '^(2|3|4)[0-9][0-9]$'
  if component_selected admin; then
    code="$(crm_http_code "$ADMIN_HOST" /login)"; check "Admin app" "$code" '^(2|3)[0-9][0-9]$'
    if [[ -n "$ADMIN_PASSWORD" && -n "$CD_ADMIN_LOGIN_PATH" ]]; then
      local hdr
      hdr="$(crm_expand "$CD_ADMIN_LOGIN_HEADER")"
      code="$(crm_http_code "$ADMIN_HOST" "$CD_ADMIN_LOGIN_PATH" -X POST -H "$hdr" -H 'Content-Type: application/json' \
        --data "$(printf '{"email":"%s","password":"%s"}' "$ADMIN_EMAIL" "$ADMIN_PASSWORD")")"
      check "Admin login (through the app to the tenant database)" "$code" '^200$'
    fi
  fi
  if [[ "$SF_NAME" != "none" ]] && component_selected storefront; then
    code="$(crm_http_code "$SHOP_HOST" /)"; check "Storefront" "$code" '^(2|3)[0-9][0-9]$'
  fi
  return "$fails"
}

save_state() {
  install -d -m 755 /etc/pulsedeploy
  {
    echo "# Written by crm.sh; used by 'pulse-crm update'"
    printf 'CRM_ID=%s\nCRM_REPO=%s\nCRM_REF=%s\nSTORE=%s\nSTORE_NAME=%s\nDOMAIN=%s\nSCHEME=%s\n' \
      "$CRM_ID" "$CD_REPO" "$CD_REF" "$STORE" "$STORE_NAME" "$DOMAIN" "$SCHEME"
    printf 'API_HOST=%s\nADMIN_HOST=%s\nSHOP_HOST=%s\nAPP_USER=%s\n' "$API_HOST" "$ADMIN_HOST" "$SHOP_HOST" "$APP_USER"
    printf 'STOREFRONT=%s\nSTOREFRONT_REPO=%s\nSTOREFRONT_REF=%s\nSTOREFRONT_DIR=%s\nSTOREFRONT_BUILD_CMD=%s\n' \
      "$STOREFRONT" "$SF_REPO" "$SF_REF" "$SF_DIR" "$SF_BUILD_CMD"
    local e
    for e in "${SF_BUILD_ENV[@]}"; do printf 'STOREFRONT_BUILD_ENV+=%s\n' "$e"; done
    for e in "${SF_RUNTIME_ENV[@]}"; do printf 'STOREFRONT_RUNTIME_ENV+=%s\n' "$e"; done
  } >/etc/pulsedeploy/crm.conf
  chmod 644 /etc/pulsedeploy/crm.conf
  # Keep a copy of this toolkit so `pulse-crm update` works without the checkout
  if [[ "$ROOT" != "/opt/pulsedeploy" ]]; then
    install -d -m 755 /opt/pulsedeploy
    (cd "$ROOT" && tar --exclude=.git -cf - .) | (cd /opt/pulsedeploy && tar -xf -)
  fi
  ln -sfn /opt/pulsedeploy/crm.sh /usr/local/bin/pulse-crm
}

cleanup_work() {
  [[ -d "$CRM_WORK/src" ]] && rm -rf -- "${CRM_WORK:?}/src"/* "${CRM_WORK:?}/artifacts"/* 2>/dev/null
  return 0
}

print_summary() {
  section "Done"
  cat <<EOF
  API         ${CRM_VARS[API_URL]}
  Admin       ${CRM_VARS[ADMIN_URL]}
  Storefront  $([[ "$SF_NAME" == "none" ]] && echo "not installed" || echo "${CRM_VARS[SHOP_URL]}  (${SF_NAME})")
  Store       ${STORE_NAME} (slug: ${STORE})
  Admin login $([[ -f "$CREDS_FILE" ]] && echo "see ${CREDS_FILE}" || echo "${ADMIN_EMAIL}")

  Next:   point DNS A records for the three hosts at $(primary_ip)
          pulse status        pulse logs <api|admin|shop>        sudo pulse backup
  Update: sudo pulse-crm update [--only backend,admin,storefront]
EOF
}

# ── commands ──────────────────────────────────────────────────────────────────
begin_root_run() {
  [[ $EUID -eq 0 ]] || error "Run as root: sudo bash crm.sh $CMD ..."
  touch "$CRM_LOG" 2>/dev/null && chmod 600 "$CRM_LOG" && exec > >(tee -a "$CRM_LOG") 2>&1
  local lock="/run/lock/pulsedeploy-crm.pid"
  [[ -d /run/lock ]] || lock="/tmp/pulsedeploy-crm.pid"
  if ! (set -o noclobber; echo "$$" >"$lock") 2>/dev/null; then
    local pid
    pid="$(cat "$lock" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then error "Another crm.sh run is in progress (PID $pid)."; fi
    rm -f "$lock"; echo "$$" >"$lock"
  fi
  # shellcheck disable=SC2064
  trap "rm -f '$lock'" EXIT
}

cmd_install() {
  validate_options
  load_definitions
  resolve_storefront
  setup_vars
  print_plan
  [[ "$DRY_RUN" -eq 0 ]] || { info "Dry run: nothing was changed."; return 0; }
  prepare_git
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    preflight_git
    log "Checks passed."
    return 0
  fi
  begin_root_run
  if [[ "$ASSUME_YES" -eq 0 && -t 0 ]]; then
    local ans=""
    read -rp "Proceed? [y/N]: " ans || ans=""
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || error "Aborted."
  fi
  preflight_git
  [[ "$SKIP_SERVER" -eq 1 ]] || provision_server
  load_server_facts
  prepare_work
  if component_selected backend;    then step_backend; fi
  if component_selected backend;    then step_store; fi
  if component_selected admin;      then step_admin; fi
  if component_selected storefront; then step_storefront; fi
  local rc=0
  smoke_tests || rc=$?
  save_state
  cleanup_work
  print_summary
  [[ "$rc" -eq 0 ]] || warn "$rc smoke test(s) failed; run 'pulse status' and 'pulse logs <target>'."
  return 0
}

cmd_update() {
  [[ -r /etc/pulsedeploy/crm.conf ]] || error "No installation found (/etc/pulsedeploy/crm.conf). Run 'crm.sh install' first."
  registry_load /etc/pulsedeploy/crm.conf ST "$CRM_STATE_SCALARS" "$CRM_STATE_LISTS"
  CRM_ID="$ST_CRM_ID"; DOMAIN="$ST_DOMAIN"; STORE="$ST_STORE"; STORE_NAME="$ST_STORE_NAME"
  SCHEME="$ST_SCHEME"; API_HOST="$ST_API_HOST"; ADMIN_HOST="$ST_ADMIN_HOST"; SHOP_HOST="$ST_SHOP_HOST"; APP_USER="$ST_APP_USER"
  STOREFRONT="$ST_STOREFRONT"
  validate_options
  load_definitions
  CD_REPO="${CRM_REPO_OVERRIDE:-$ST_CRM_REPO}"; CD_REF="${CRM_REF_OVERRIDE:-$ST_CRM_REF}"
  SF_NAME="none"; SF_REPO=""; SF_REF="main"; SF_DIR="."; SF_BUILD_CMD="npm ci && npm run build"; SF_BUILD_ENV=(); SF_RUNTIME_ENV=()
  if [[ -n "$STOREFRONT" && "$STOREFRONT" != "none" ]]; then
    SF_NAME="$STOREFRONT"; SF_REPO="$ST_STOREFRONT_REPO"
    SF_REF="${SF_REF_OVERRIDE:-$ST_STOREFRONT_REF}"; SF_DIR="${SF_DIR_OVERRIDE:-$ST_STOREFRONT_DIR}"
    SF_BUILD_CMD="${SF_BUILD_CMD_OVERRIDE:-$ST_STOREFRONT_BUILD_CMD}"
    SF_BUILD_ENV=("${ST_STOREFRONT_BUILD_ENV[@]}"); SF_RUNTIME_ENV=("${ST_STOREFRONT_RUNTIME_ENV[@]}")
  fi
  EMAIL=""; ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
  setup_vars
  section "Updating ${CD_NAME}"
  print_plan
  [[ "$DRY_RUN" -eq 0 ]] || { info "Dry run: nothing was changed."; return 0; }
  prepare_git
  begin_root_run
  preflight_git
  load_server_facts
  prepare_work
  if component_selected backend;    then step_backend; fi
  if component_selected admin;      then step_admin; fi
  if component_selected storefront; then step_storefront; fi
  ADMIN_PASSWORD=""
  local rc=0
  smoke_tests || rc=$?
  cleanup_work
  if [[ "$rc" -eq 0 ]]; then log "Update complete."; else warn "$rc smoke test(s) failed."; fi
  return 0
}

main() {
  parse_args "$@"
  case "$CMD" in
    install)      cmd_install ;;
    update)       cmd_update ;;
    storefronts)  list_storefronts ;;
    status)       exec pulse status ;;
    version|--version) echo "crm.sh v${CRM_VERSION}" ;;
    help|-h|--help) print_help ;;
    *) error "Unknown command '$CMD' (install | update | storefronts | status | help)" ;;
  esac
}

main "$@"
