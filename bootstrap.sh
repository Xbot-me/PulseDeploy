#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - VPS & AWS Server Setup Script
# Author  : Mustafizur Rahman (@Xbot-me)
# Repo    : https://github.com/Xbot-me/PulseDeploy
# License : MIT
# =============================================================================
# -E so the ERR trap also fires inside functions.
set -Eeuo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "PulseDeploy needs bash 4 or newer (found ${BASH_VERSION})." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${PULSE_LOG_FILE:-/var/log/server-bootstrap.log}"
BOOTSTRAP_VERSION="1.2.0"

if [[ ! -f "$SCRIPT_DIR/scripts/lib/common.sh" ]]; then
  echo "PulseDeploy must be run from a full checkout (scripts/ directory not found next to bootstrap.sh)." >&2
  echo "  git clone https://github.com/Xbot-me/PulseDeploy.git && cd PulseDeploy && sudo bash bootstrap.sh" >&2
  exit 1
fi
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# ── Global error trap ─────────────────────────────────────────────────────────
# Prints what failed, where, and in which function, then exits with that code.
handle_error() {
  local exit_code="$1" file="$2" line_no="$3" last_cmd="$4"
  local func_name="${FUNCNAME[1]:-main}"
  trap - ERR
  {
    echo -e "\n${RED}${BOLD}✘ PulseDeploy failed${RESET}"
    echo -e "${RED}  Function   :${RESET} $func_name"
    echo -e "${RED}  Location   :${RESET} ${file}:${line_no}"
    echo -e "${RED}  Command    :${RESET} $last_cmd"
    echo -e "${RED}  Exit code  :${RESET} $exit_code"
    echo -e "${RED}  Log file   :${RESET} $LOG_FILE"
    echo -e "${YELLOW}  Nothing after this point ran. Fix the cause and re-run - PulseDeploy is safe to run again.${RESET}\n"
  } >&2
  exit "$exit_code"
}
trap 'handle_error $? "${BASH_SOURCE[0]##*/}" $LINENO "$BASH_COMMAND"' ERR

# ── Defaults (overridden by flags / env vars) ─────────────────────────────────
STACK="${PULSE_STACK:-}"
PHP_VER="${PULSE_PHP:-8.2}"
NODE_VER="${PULSE_NODE:-22}"
SERVICES_RAW="${PULSE_SERVICES:-}"
SWAP_SIZE="${PULSE_SWAP_SIZE:-}"
APP_PORT="${PULSE_APP_PORT:-3000}"
DOMAIN="${PULSE_DOMAIN:-}"
EMAIL="${PULSE_EMAIL:-}"
DB_NAME="${PULSE_DB_NAME:-}"
DB_USER="${PULSE_DB_USER:-}"
SSH_PORT="${PULSE_SSH_PORT:-22}"
TIMEZONE="${PULSE_TIMEZONE:-}"
HOSTNAME_VAL="${PULSE_HOSTNAME:-}"
DISABLE_ROOT_SSH="${PULSE_DISABLE_ROOT_SSH:-0}"
NON_INTERACTIVE="${PULSE_NON_INTERACTIVE:-0}"
API_HOST="${PULSE_API_HOST:-}"
ADMIN_HOST="${PULSE_ADMIN_HOST:-}"
SHOP_HOST="${PULSE_SHOP_HOST:-}"
APP_USER="${PULSE_APP_USER:-deploy}"
CLOUDFLARE="${PULSE_CLOUDFLARE:-0}"
TENANT_DB_PREFIX="${PULSE_TENANT_DB_PREFIX:-}"
SERVE_STORAGE="${PULSE_SERVE_STORAGE:-0}"
NO_QUEUE="${PULSE_NO_QUEUE:-0}"
NO_SCHEDULER="${PULSE_NO_SCHEDULER:-0}"
OPEN_PORTS="${PULSE_OPEN_PORTS:-}"
REDIS_CONN="${PULSE_REDIS_CONN:-}"

# Which values were given explicitly (so the wizard does not ask again)
PHP_SET=0;  [[ -n "${PULSE_PHP:-}" ]] && PHP_SET=1
NODE_SET=0; [[ -n "${PULSE_NODE:-}" ]] && NODE_SET=1
PORT_SET=0; [[ -n "${PULSE_APP_PORT:-}" ]] && PORT_SET=1
SWAP_SET=0; [[ -n "${PULSE_SWAP_SIZE:-}" ]] && SWAP_SET=1
REDIS_SET=0; [[ -n "${PULSE_REDIS_CONN:-}" ]] && REDIS_SET=1
PORTS_SET=0; [[ -n "${PULSE_OPEN_PORTS:-}" ]] && PORTS_SET=1

declare -A SERVICES=(
  [redis]=0 [docker]=0 [firewall]=0
  [certbot]=0 [swap]=0 [phptune]=0
)

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
  echo -e "${BOLD}${CYAN}"
  cat <<EOF
  ██████╗ ██╗   ██╗██╗     ███████╗███████╗
  ██╔══██╗██║   ██║██║     ██╔════╝██╔════╝
  ██████╔╝██║   ██║██║     ███████╗█████╗
  ██╔═══╝ ██║   ██║██║     ╚════██║██╔══╝
  ██║     ╚██████╔╝███████╗███████║███████╗
  ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚══════╝
  ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗
  ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝
  ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝
  ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝
  ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║
  ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝
  VPS & AWS Server Automation v${BOOTSTRAP_VERSION} · by @Xbot-me
EOF
  echo -e "${RESET}"
  return 0
}

# ── Help ──────────────────────────────────────────────────────────────────────
print_help() {
  cat <<EOF
${BOLD}USAGE${RESET}
  sudo bash bootstrap.sh [OPTIONS]

${BOLD}DESCRIPTION${RESET}
  PulseDeploy is a modular Bash toolkit for spinning up production-ready Linux
  servers on VPS providers and AWS EC2. Run with no flags for the interactive
  wizard, or pass flags for fully automated / CI deployments. Options may be
  written --flag value or --flag=value. Unknown flags are an error.

${BOLD}STACK OPTIONS${RESET}
  -s, --stack <stack>       Stack to install: lemp | lamp | node | laravel-next | none
                            Env: PULSE_STACK
  -P, --php <version>       PHP version: 8.1 | 8.2 | 8.3 | 8.4  (default: 8.2)
                            Env: PULSE_PHP
  -N, --node <version>      Node.js version: 18 | 20 | 22 | 24  (default: 22)
                            Env: PULSE_NODE

${BOLD}SERVICE FLAGS${RESET}
  -S, --services <list>     Comma-separated services to enable:
                            redis, docker, firewall, certbot, swap, phptune
                            Env: PULSE_SERVICES
                            Example: --services redis,firewall,swap,certbot
      --redis-conn <type>   Redis access: socket | tcp  (default: socket)
                            Env: PULSE_REDIS_CONN
      --open-ports <list>   Extra TCP ports for the firewall, e.g. 8080,9000
                            Env: PULSE_OPEN_PORTS

${BOLD}SERVER CONFIGURATION${RESET}
      --domain <domain>     Primary domain (nginx/apache server_name + Certbot)
                            Env: PULSE_DOMAIN
      --email <email>       Email for Certbot SSL notifications
                            Env: PULSE_EMAIL
      --hostname <name>     Set server hostname
                            Env: PULSE_HOSTNAME
      --timezone <tz>       Set system timezone (e.g. Asia/Dhaka, UTC)
                            Env: PULSE_TIMEZONE
      --ssh-port <port>     SSH port the firewall must keep open (default: 22;
                            the port sshd actually listens on is always kept)
                            Env: PULSE_SSH_PORT
      --disable-root-ssh    Disable root SSH login (refused unless another
                            sudo user with an SSH key exists)
                            Env: PULSE_DISABLE_ROOT_SSH=1
      --app-port <port>     Node.js app port for Nginx proxy (default: 3000)
                            Env: PULSE_APP_PORT

${BOLD}LARAVEL + NEXT.JS STACK${RESET} (--stack laravel-next; requires --domain)
      --api-host <host>     Laravel API host    (default: api.<domain>)
      --admin-host <host>   Next.js admin host  (default: admin.<domain>)
      --shop-host <host>    Next.js storefront  (default: <domain>)
      --app-user <name>     Deploy/runtime user (default: deploy)
      --cloudflare          Restore real client IPs behind Cloudflare
      --tenant-db-prefix <p> Multi-tenant apps that create one database per store:
                            let the DB user create/manage databases named <p>*
                            (for example zymerce_tenant_)
      --serve-storage       Serve /storage/* on the Next.js hosts straight from the
                            Laravel public disk (skips Node for uploaded files)
      --no-queue            Do not run a queue worker (app has no queued jobs)
      --no-scheduler        Do not run the Laravel scheduler timer
                            The Next.js apps reach the API without leaving the
                            machine at http://127.0.0.1:8081 (loopback only).
                            Env: PULSE_API_HOST, PULSE_ADMIN_HOST, PULSE_SHOP_HOST,
                            PULSE_APP_USER, PULSE_CLOUDFLARE=1, PULSE_TENANT_DB_PREFIX,
                            PULSE_SERVE_STORAGE=1, PULSE_NO_QUEUE=1, PULSE_NO_SCHEDULER=1

${BOLD}DATABASE${RESET}
      --db-name <name>      Create a database with this name (LEMP/LAMP)
                            Env: PULSE_DB_NAME
      --db-user <user>      Create a DB user for it (random password, saved to
                            /root/.my.cnf). Requires --db-name.
                            Env: PULSE_DB_USER

${BOLD}SWAP${RESET}
      --swap-size <size>    Swap file size, e.g. 512M, 2G (default: auto)
                            Env: PULSE_SWAP_SIZE

${BOLD}BEHAVIOUR${RESET}
  -y, --non-interactive     Skip all prompts; use flag values or defaults
                            (enabled automatically when stdin is not a terminal)
                            Env: PULSE_NON_INTERACTIVE=1
  -h, --help                Show this help message and exit
  -v, --version             Show version and exit

${BOLD}EXAMPLES${RESET}
  # Interactive wizard (default)
  sudo bash bootstrap.sh

  # Full automated LEMP server
  sudo bash bootstrap.sh \\
    --stack lemp --php 8.2 \\
    --services redis,firewall,swap,certbot,phptune \\
    --domain example.com --email admin@example.com \\
    --db-name myapp --db-user myuser \\
    --hostname web01 --timezone Asia/Dhaka \\
    --disable-root-ssh --non-interactive

  # Laravel API + Next.js admin + storefront on one small server
  sudo bash bootstrap.sh -s laravel-next --domain example.com --email me@example.com \\
    --services certbot --cloudflare -y

  # Node.js server, non-interactive
  sudo bash bootstrap.sh -s node -N 22 -S firewall,swap,docker -y

  # Via environment variables (AWS EC2 user-data / cloud-init)
  export PULSE_STACK=lemp
  export PULSE_PHP=8.2
  export PULSE_SERVICES=redis,firewall,swap,certbot
  export PULSE_DOMAIN=example.com
  export PULSE_EMAIL=admin@example.com
  export PULSE_NON_INTERACTIVE=1
  sudo -E bash bootstrap.sh

${BOLD}DOCS & SOURCE${RESET}
  https://github.com/Xbot-me/PulseDeploy
  https://github.com/Xbot-me/PulseDeploy/wiki

EOF
  return 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
need_value() {
  [[ $# -ge 2 && -n "$2" ]] || error "Option $1 requires a value - run --help for usage"
  return 0
}

parse_args() {
  # Accept --flag=value as well as --flag value
  local -a args=()
  local a
  for a in "$@"; do
    if [[ "$a" == --*=* ]]; then args+=("${a%%=*}" "${a#*=}"); else args+=("$a"); fi
  done
  set -- "${args[@]+"${args[@]}"}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--stack)            need_value "$@"; STACK="$2";                          shift 2 ;;
      -P|--php)              need_value "$@"; PHP_VER="$2";  PHP_SET=1;            shift 2 ;;
      -N|--node)             need_value "$@"; NODE_VER="$2"; NODE_SET=1;           shift 2 ;;
      -S|--services)         need_value "$@"; SERVICES_RAW="$2";                   shift 2 ;;
         --domain)           need_value "$@"; DOMAIN="$2";                         shift 2 ;;
         --email)            need_value "$@"; EMAIL="$2";                          shift 2 ;;
         --hostname)         need_value "$@"; HOSTNAME_VAL="$2";                   shift 2 ;;
         --timezone)         need_value "$@"; TIMEZONE="$2";                       shift 2 ;;
         --ssh-port)         need_value "$@"; SSH_PORT="$2";                       shift 2 ;;
         --disable-root-ssh) DISABLE_ROOT_SSH=1;                                   shift   ;;
         --app-port)         need_value "$@"; APP_PORT="$2"; PORT_SET=1;           shift 2 ;;
         --api-host)         need_value "$@"; API_HOST="$2";                       shift 2 ;;
         --admin-host)       need_value "$@"; ADMIN_HOST="$2";                     shift 2 ;;
         --shop-host)        need_value "$@"; SHOP_HOST="$2";                      shift 2 ;;
         --app-user)         need_value "$@"; APP_USER="$2";                       shift 2 ;;
         --cloudflare)       CLOUDFLARE=1;                                         shift   ;;
         --tenant-db-prefix) need_value "$@"; TENANT_DB_PREFIX="$2";               shift 2 ;;
         --serve-storage)    SERVE_STORAGE=1;                                      shift   ;;
         --no-queue)         NO_QUEUE=1;                                           shift   ;;
         --no-scheduler)     NO_SCHEDULER=1;                                       shift   ;;
         --db-name)          need_value "$@"; DB_NAME="$2";                        shift 2 ;;
         --db-user)          need_value "$@"; DB_USER="$2";                        shift 2 ;;
         --swap-size)        need_value "$@"; SWAP_SIZE="$2"; SWAP_SET=1;          shift 2 ;;
         --open-ports)       need_value "$@"; OPEN_PORTS="$2"; PORTS_SET=1;        shift 2 ;;
         --redis-conn)       need_value "$@"; REDIS_CONN="$2"; REDIS_SET=1;        shift 2 ;;
      -y|--non-interactive)  NON_INTERACTIVE=1;                                    shift   ;;
      -h|--help)             print_help; exit 0 ;;
      -v|--version)          echo "PulseDeploy v${BOOTSTRAP_VERSION}"; exit 0 ;;
      *) error "Unknown option: $1 - run --help for usage" ;;
    esac
  done
  STACK="${STACK,,}"
  SERVICES_RAW="${SERVICES_RAW,,}"
  REDIS_CONN="${REDIS_CONN,,}"
  SWAP_SIZE="${SWAP_SIZE^^}"
  case "${DISABLE_ROOT_SSH,,}" in 1|true|yes) DISABLE_ROOT_SSH=1 ;; *) DISABLE_ROOT_SSH=0 ;; esac
  case "${NON_INTERACTIVE,,}" in 1|true|yes) NON_INTERACTIVE=1 ;; *) NON_INTERACTIVE=0 ;; esac
  case "${CLOUDFLARE,,}" in 1|true|yes) CLOUDFLARE=1 ;; *) CLOUDFLARE=0 ;; esac
  case "${SERVE_STORAGE,,}" in 1|true|yes) SERVE_STORAGE=1 ;; *) SERVE_STORAGE=0 ;; esac
  case "${NO_QUEUE,,}" in 1|true|yes) NO_QUEUE=1 ;; *) NO_QUEUE=0 ;; esac
  case "${NO_SCHEDULER,,}" in 1|true|yes) NO_SCHEDULER=1 ;; *) NO_SCHEDULER=0 ;; esac
  return 0
}

# ── Validation ────────────────────────────────────────────────────────────────
valid_php_ver()    { [[ "$1" =~ ^8\.[1-4]$ ]]; }
valid_node_ver()   { [[ "$1" =~ ^(18|20|22|24)$ ]]; }
valid_tenant_prefix() { [[ "$1" =~ ^[A-Za-z0-9_]{2,40}$ ]]; }
valid_redis_conn() { [[ "$1" == "socket" || "$1" == "tcp" ]]; }
valid_port_list() {
  local p
  local -a items
  [[ -z "$1" ]] && return 0
  IFS=',' read -ra items <<<"$1"
  for p in "${items[@]}"; do
    p="${p// /}"
    valid_port "$p" || return 1
  done
  return 0
}

# Fail fast on bad flags/env before touching the system.
validate_inputs() {
  case "$STACK" in lemp|lamp|node|laravel-next|none|"") ;; *) error "Invalid --stack '$STACK' (lemp | lamp | node | laravel-next | none)" ;; esac
  valid_php_ver "$PHP_VER"       || error "Invalid --php '$PHP_VER' (8.1 | 8.2 | 8.3 | 8.4)"
  valid_node_ver "$NODE_VER"     || error "Invalid --node '$NODE_VER' (18 | 20 | 22 | 24)"
  valid_port "$APP_PORT"         || error "Invalid --app-port '$APP_PORT' (1-65535)"
  valid_port "$SSH_PORT"         || error "Invalid --ssh-port '$SSH_PORT' (1-65535)"
  valid_port_list "$OPEN_PORTS"  || error "Invalid --open-ports '$OPEN_PORTS' (comma-separated ports, 1-65535)"
  [[ -z "$DOMAIN" ]]       || valid_domain "$DOMAIN"       || error "Invalid --domain '$DOMAIN'"
  [[ -z "$EMAIL" ]]        || valid_email "$EMAIL"         || error "Invalid --email '$EMAIL'"
  [[ -z "$API_HOST" ]]     || valid_domain "$API_HOST"     || error "Invalid --api-host '$API_HOST'"
  [[ -z "$ADMIN_HOST" ]]   || valid_domain "$ADMIN_HOST"   || error "Invalid --admin-host '$ADMIN_HOST'"
  [[ -z "$SHOP_HOST" ]]    || valid_domain "$SHOP_HOST"    || error "Invalid --shop-host '$SHOP_HOST'"
  [[ "$APP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$APP_USER" != "root" ]] || error "Invalid --app-user '$APP_USER' (lowercase letters, digits, - and _; not root)"
  [[ -z "$HOSTNAME_VAL" ]] || valid_hostname "$HOSTNAME_VAL" || error "Invalid --hostname '$HOSTNAME_VAL'"
  [[ -z "$TIMEZONE" ]]     || valid_timezone "$TIMEZONE"   || error "Unknown --timezone '$TIMEZONE' (see: timedatectl list-timezones)"
  [[ -z "$SWAP_SIZE" ]]    || valid_swap_size "$SWAP_SIZE" || error "Invalid --swap-size '$SWAP_SIZE' (examples: 512M, 2G)"
  [[ -z "$DB_NAME" ]]      || valid_db_name "$DB_NAME"     || error "Invalid --db-name '$DB_NAME' (letters, digits, underscore; max 64)"
  [[ -z "$DB_USER" ]]      || valid_db_user "$DB_USER"     || error "Invalid --db-user '$DB_USER' (letters, digits, underscore; max 32)"
  [[ -z "$REDIS_CONN" ]]   || valid_redis_conn "$REDIS_CONN" || error "Invalid --redis-conn '$REDIS_CONN' (socket | tcp)"
  [[ -z "$DB_USER" || -n "$DB_NAME" ]] || error "--db-user requires --db-name"
  [[ -z "$TENANT_DB_PREFIX" ]] || valid_tenant_prefix "$TENANT_DB_PREFIX" || error "Invalid --tenant-db-prefix '$TENANT_DB_PREFIX' (letters, digits, underscore; 2-40 characters)"
  return 0
}

# ── Parse services list ───────────────────────────────────────────────────────
parse_services() {
  [[ -z "$SERVICES_RAW" ]] && return 0
  local svc
  local -a svc_list
  IFS=',' read -ra svc_list <<<"$SERVICES_RAW"
  for svc in "${svc_list[@]}"; do
    svc="${svc// /}"
    [[ -z "$svc" ]] && continue
    case "$svc" in
      redis|docker|firewall|certbot|swap|phptune) SERVICES[$svc]=1 ;;
      *) error "Unknown service '$svc'. Valid: redis,docker,firewall,certbot,swap,phptune" ;;
    esac
  done
  return 0
}

# ── Safe server configuration ─────────────────────────────────────────────────
set_hostname() {
  if ! { command -v hostnamectl &>/dev/null && hostnamectl set-hostname "$HOSTNAME_VAL" 2>/dev/null; }; then
    hostname "$HOSTNAME_VAL"
    echo "$HOSTNAME_VAL" >/etc/hostname
  fi
  # Keep the name resolvable locally so sudo does not complain
  local escaped="${HOSTNAME_VAL//./\\.}"
  if ! grep -Eq "^127\.0\.1\.1[[:space:]]+${escaped}([[:space:]]|\$)" /etc/hosts; then
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s|^127\.0\.1\.1.*|127.0.1.1 ${HOSTNAME_VAL}|" /etc/hosts
    else
      echo "127.0.1.1 ${HOSTNAME_VAL}" >>/etc/hosts
    fi
  fi
  log "Hostname set to: $HOSTNAME_VAL"
  return 0
}

set_timezone() {
  if ! { command -v timedatectl &>/dev/null && timedatectl set-timezone "$TIMEZONE" 2>/dev/null; }; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    [[ -f /etc/timezone ]] && echo "$TIMEZONE" >/etc/timezone
  fi
  log "Timezone set to: $TIMEZONE"
  return 0
}

# Refuses to lock the admin out: needs another sudo-capable user with an SSH key.
disable_root_ssh() {
  local u uid home shell found=""
  while IFS=: read -r u _ uid _ _ home shell; do
    ((uid >= 1000 && uid < 60000)) || continue
    [[ "$shell" =~ (nologin|false)$ ]] && continue
    [[ " $(id -nG "$u" 2>/dev/null) " =~ \ (sudo|wheel|admin)\  ]] || continue
    [[ -s "$home/.ssh/authorized_keys" ]] || continue
    found="$u"
    break
  done </etc/passwd
  if [[ -z "$found" ]]; then
    warn "NOT disabling root SSH login: no other sudo/wheel user with an ~/.ssh/authorized_keys exists."
    warn "Create one first (adduser + copy your key), then re-run with --disable-root-ssh."
    return 0
  fi

  local cfg="/etc/ssh/sshd_config" dropdir="/etc/ssh/sshd_config.d" target restore=""
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$cfg" && [[ -d "$dropdir" ]]; then
    target="$dropdir/00-pulsedeploy.conf" # first value wins, so 00- beats cloud-init's 50-
    printf 'PermitRootLogin no\n' >"$target"
    restore="rm -f $target"
  else
    target="$cfg"
    backup_file "$cfg"
    if grep -Eq '^[[:space:]]*#?[[:space:]]*PermitRootLogin' "$cfg"; then
      conf_set "$cfg" PermitRootLogin no " "
    else
      sed -i '1i PermitRootLogin no' "$cfg" # top of file: never inside a Match block
    fi
    restore="cp -a ${cfg}.pulsedeploy.bak $cfg"
  fi

  if command -v sshd &>/dev/null && ! sshd -t; then
    eval "$restore"
    warn "sshd rejected the new configuration; it was rolled back. Root login unchanged."
    return 0
  fi
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || warn "Could not reload sshd - change applies after the next restart."
  local effective=""
  effective="$(sshd -T 2>/dev/null | awk 'tolower($1) == "permitrootlogin" { print $2 }')" || true
  if [[ "$effective" == "no" || -z "$effective" ]]; then
    log "Root SSH login disabled (admin user with key: $found)"
  else
    warn "sshd still reports PermitRootLogin=$effective - another config file overrides it."
  fi
  return 0
}

apply_server_config() {
  [[ -n "$HOSTNAME_VAL" ]] && set_hostname
  [[ -n "$TIMEZONE" ]] && set_timezone
  [[ "$DISABLE_ROOT_SSH" -eq 1 ]] && disable_root_ssh
  return 0
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || error "This script must be run as root. Use: sudo bash bootstrap.sh"
  return 0
}

setup_logging() {
  if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/server-bootstrap.log"
    touch "$LOG_FILE"
  fi
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  return 0
}

# PID-file lock. flock on a descriptor is avoided on purpose: daemons started
# during the install (PM2, DB servers) would inherit it and hold the lock.
LOCK_FILE="/run/lock/pulsedeploy.pid"
release_lock() {
  if [[ -f "$LOCK_FILE" && "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
    rm -f "$LOCK_FILE"
  fi
  return 0
}

acquire_lock() {
  [[ -d /run/lock ]] || LOCK_FILE="/tmp/pulsedeploy.pid"
  local pid
  for _ in 1 2; do
    if (set -o noclobber; echo "$$" >"$LOCK_FILE") 2>/dev/null; then
      trap release_lock EXIT
      return 0
    fi
    pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
       [[ "$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" == *bootstrap.sh* ]]; then
      error "Another PulseDeploy run is already in progress (PID $pid)."
    fi
    rm -f "$LOCK_FILE" # stale lock from a crashed run
  done
  error "Could not acquire the lock file $LOCK_FILE."
}

preflight() {
  if [[ "${PULSE_SKIP_PREFLIGHT:-0}" == "1" ]]; then
    warn "Pre-flight checks skipped (PULSE_SKIP_PREFLIGHT=1)"
    return 0
  fi
  if ! has_systemd && [[ "${PULSE_ALLOW_NO_SYSTEMD:-0}" != "1" ]]; then
    error "systemd is not running as PID 1 (container or WSL1?). PulseDeploy manages services with systemctl and needs a real VM/VPS."
  fi
  local free_mb ram_mb arch
  free_mb="$(df -Pm / | awk 'NR == 2 { print $4 }')"
  ((free_mb >= 2048)) || error "Only ${free_mb}MB free on / - at least 2048MB is required."
  ram_mb="$(total_ram_mb)"
  if ((ram_mb < 900)) && [[ "${SERVICES[swap]}" -eq 0 && "$NON_INTERACTIVE" -eq 1 ]]; then
    warn "Only ${ram_mb}MB RAM and swap is not selected - package installs can be OOM-killed. Consider --services swap."
  fi
  arch="$(uname -m)"
  [[ "$arch" == "x86_64" || "$arch" == "aarch64" ]] || warn "Untested CPU architecture: $arch"
  return 0
}

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
  [[ -r /etc/os-release ]] || error "Cannot detect OS. /etc/os-release not found."
  OS_ID="$(os_release_value ID)"
  OS_VERSION="$(os_release_value VERSION_ID)"
  OS_VERSION="${OS_VERSION:-unknown}"
  local major="${OS_VERSION%%.*}" module=""

  case "$OS_ID" in
    ubuntu)
      module="ubuntu"
      [[ "$major" =~ ^[0-9]+$ && "$major" -ge 20 ]] || error "Ubuntu $OS_VERSION is too old (need 20.04+)."
      ;;
    debian)
      module="debian"
      [[ "$major" =~ ^[0-9]+$ && "$major" -ge 11 ]] || error "Debian $OS_VERSION is not supported (need 11+)."
      ;;
    amzn)
      module="amazon_linux"
      [[ "$OS_VERSION" == "2" || "$OS_VERSION" == "2023" ]] || error "Amazon Linux $OS_VERSION is not supported (2 or 2023)."
      [[ "$OS_VERSION" == "2" ]] && warn "Amazon Linux 2 is end-of-life; support is best effort. Prefer Amazon Linux 2023."
      ;;
    centos|rocky|rhel|almalinux)
      module="centos_rocky"
      [[ "$major" =~ ^[0-9]+$ && "$major" -ge 8 ]] || error "$OS_ID $OS_VERSION is not supported (need 8+)."
      ;;
    *)
      error "Unsupported OS: $OS_ID. Supported: Ubuntu, Debian, Amazon Linux, CentOS/Rocky/Alma/RHEL."
      ;;
  esac
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/scripts/os/${module}.sh"
  log "Detected OS: $OS_ID $OS_VERSION (package manager: $PKG_MANAGER)"
  return 0
}

# ── Interactive helpers ───────────────────────────────────────────────────────
# prompt <var> <label> <default> [validator]
prompt() {
  local var="$1" label="$2" def="$3" validator="${4:-}" val=""
  while true; do
    read -rp "$(echo -e "${CYAN}${label} [${def:-none}]:${RESET} ")" val ||
      error "Input closed - re-run with --non-interactive and flags."
    val="${val:-$def}"
    if [[ -z "$validator" ]] || "$validator" "$val"; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    warn "Invalid value '$val' - try again."
  done
}

ask_yes_no() {
  local ans=""
  read -rp "$(echo -e "${YELLOW}$1 [y/N]:${RESET} ")" ans || ans=""
  ans="${ans,,}"
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

# ── Interactive: Stack selection ──────────────────────────────────────────────
select_stack() {
  if [[ -n "$STACK" ]]; then
    log "Stack: $STACK"
    return 0
  fi
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    warn "No --stack given in non-interactive mode - installing core packages only (stack: none)."
    STACK="none"
    return 0
  fi

  section "Stack Selection"
  echo -e "Choose a server stack to install:\n"
  echo -e "  ${BOLD}1)${RESET} LEMP  - Nginx + PHP-FPM + MySQL"
  echo -e "  ${BOLD}2)${RESET} LAMP  - Apache + PHP + MySQL"
  echo -e "  ${BOLD}3)${RESET} Node  - Nginx + Node.js (with PM2)"
  echo -e "  ${BOLD}4)${RESET} Skip  - Core services only"
  echo -e "  ${BOLD}5)${RESET} Laravel + Next.js - API, admin dashboard and storefront on one server"
  echo ""
  local choice=""
  while [[ -z "$STACK" ]]; do
    read -rp "$(echo -e "${CYAN}Enter choice [1-5]:${RESET} ")" choice ||
      error "Input closed - re-run with --non-interactive and flags."
    case "$choice" in
      1) STACK="lemp" ;;
      2) STACK="lamp" ;;
      3) STACK="node" ;;
      4) STACK="none" ;;
      5) STACK="laravel-next" ;;
      *) warn "Please enter 1, 2, 3, 4 or 5." ;;
    esac
  done
  log "Stack selected: $STACK"
  return 0
}

# ── Interactive: versions & ports (only what was not given as a flag) ─────────
select_versions() {
  [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
  if [[ "$STACK" == "lemp" || "$STACK" == "lamp" ]] && [[ "$PHP_SET" -eq 0 ]]; then
    prompt PHP_VER "PHP version (8.1 / 8.2 / 8.3 / 8.4)" "$PHP_VER" valid_php_ver
  fi
  if [[ "$STACK" == "laravel-next" && -z "$DOMAIN" ]]; then
    prompt DOMAIN "Main domain (for example example.com)" "" valid_domain
  fi
  if [[ "$STACK" == "node" ]]; then
    [[ "$NODE_SET" -eq 0 ]] && prompt NODE_VER "Node.js version (18 / 20 / 22 / 24)" "$NODE_VER" valid_node_ver
    [[ "$PORT_SET" -eq 0 ]] && prompt APP_PORT "App port to proxy" "$APP_PORT" valid_port
  fi
  return 0
}

# ── Interactive: Service selection ────────────────────────────────────────────
select_services() {
  if [[ -n "$SERVICES_RAW" ]]; then
    parse_services
    log "Services (from flag): $SERVICES_RAW"
    return 0
  fi
  [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0

  section "Optional Services"
  if ask_yes_no "Install Redis?";                   then SERVICES[redis]=1;    fi
  if ask_yes_no "Install Docker & Compose?";        then SERVICES[docker]=1;   fi
  if ask_yes_no "Configure firewall + fail2ban?";   then SERVICES[firewall]=1; fi
  if ask_yes_no "Install Certbot (SSL)?";           then SERVICES[certbot]=1;  fi
  if ask_yes_no "Configure swap file?";             then SERVICES[swap]=1;     fi
  if [[ "$STACK" == "lemp" || "$STACK" == "lamp" ]]; then
    if ask_yes_no "Apply PHP performance tuning?";  then SERVICES[phptune]=1;  fi
  fi
  return 0
}

# Per-service details, asked only when the service is on and no flag was given.
select_service_options() {
  [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
  if [[ "${SERVICES[redis]}" -eq 1 && "$REDIS_SET" -eq 0 ]]; then
    prompt REDIS_CONN "Redis connection (socket / tcp)" "socket" valid_redis_conn
  fi
  if [[ "${SERVICES[swap]}" -eq 1 && "$SWAP_SET" -eq 0 ]]; then
    prompt SWAP_SIZE "Swap size (e.g. 1G, 2G)" "$(swap_suggest_size "$(total_ram_mb)")" valid_swap_size
    SWAP_SIZE="${SWAP_SIZE^^}"
  fi
  if [[ "${SERVICES[firewall]}" -eq 1 && "$PORTS_SET" -eq 0 ]]; then
    prompt OPEN_PORTS "Extra ports to open (comma-separated, blank for none)" "" valid_port_list
  fi
  return 0
}

# Cross-checks that depend on the final combination of choices.
check_consistency() {
  REDIS_CONN="${REDIS_CONN:-socket}"
  local web=0
  [[ "$STACK" == "lemp" || "$STACK" == "lamp" || "$STACK" == "laravel-next" ]] && web=1
  if [[ "$STACK" == "laravel-next" ]]; then
    [[ -n "$DOMAIN" ]] || error "--stack laravel-next needs --domain"
    # Redis, PHP tuning and DB tuning are built into this stack.
    SERVICES[redis]=0
    SERVICES[phptune]=0
    # Safe defaults for a production box; harmless if already chosen.
    if [[ "${SERVICES[firewall]}" -eq 0 ]]; then
      SERVICES[firewall]=1
      info "Firewall + fail2ban enabled by default for this stack"
    fi
    if [[ "${SERVICES[swap]}" -eq 0 ]] && (($(total_ram_mb) <= 4096)); then
      SERVICES[swap]=1
      info "Swap enabled by default (server has 4GB RAM or less)"
    fi
  fi
  if [[ "${SERVICES[phptune]}" -eq 1 && "$STACK" != "lemp" && "$STACK" != "lamp" ]]; then
    warn "phptune needs the lemp or lamp stack - it will be skipped."
    SERVICES[phptune]=0
  fi
  if [[ -n "$TENANT_DB_PREFIX" && "$web" -eq 0 ]]; then
    warn "--tenant-db-prefix only applies to web stacks with a database - ignored."
    TENANT_DB_PREFIX=""
  fi
  if [[ -n "$DB_NAME" && "$web" -eq 0 ]]; then
    warn "--db-name/--db-user only apply to lemp/lamp stacks - ignored."
    DB_NAME=""; DB_USER=""
  fi
  if [[ "${SERVICES[certbot]}" -eq 1 && -n "$DOMAIN" && -z "$EMAIL" ]]; then
    warn "Certbot will be installed but no certificate requested: --email is missing."
  fi
  if [[ -n "$DOMAIN" && "${SERVICES[certbot]}" -eq 0 && "$STACK" != "none" ]]; then
    info "Domain set without the certbot service - site will serve plain HTTP."
  fi
  return 0
}

# ── Confirmation ──────────────────────────────────────────────────────────────
svc_label() {
  if [[ "${SERVICES[$1]}" -eq 1 ]]; then echo -e "${GREEN}✔ Yes${RESET}"; else echo -e "${RED}✘ No${RESET}"; fi
  return 0
}

yes_no() { if [[ "$1" -eq 1 ]]; then echo Yes; else echo No; fi; }

confirm_install() {
  section "Installation Summary"
  echo -e "  OS               : ${BOLD}$OS_ID $OS_VERSION${RESET}"
  echo -e "  Stack            : ${BOLD}$STACK${RESET}"
  [[ "$STACK" == "lemp" || "$STACK" == "lamp" ]] && echo -e "  PHP version      : ${BOLD}$PHP_VER${RESET}"
  [[ "$STACK" == "node" ]] && echo -e "  Node version     : ${BOLD}$NODE_VER${RESET} (app port ${APP_PORT})"
  echo -e "  Domain           : ${BOLD}${DOMAIN:-not set}${RESET}"
  if [[ "$STACK" == "laravel-next" ]]; then
    echo -e "  API host         : ${BOLD}${API_HOST:-api.$DOMAIN}${RESET}"
    echo -e "  Admin host       : ${BOLD}${ADMIN_HOST:-admin.$DOMAIN}${RESET}"
    echo -e "  Storefront host  : ${BOLD}${SHOP_HOST:-$DOMAIN}${RESET}"
    echo -e "  Deploy user      : ${BOLD}${APP_USER}${RESET}   Cloudflare: ${BOLD}$(yes_no "$CLOUDFLARE")${RESET}"
    echo -e "  Tenant DB prefix : ${BOLD}${TENANT_DB_PREFIX:-none}${RESET}   Serve /storage: ${BOLD}$(yes_no "$SERVE_STORAGE")${RESET}"
    echo -e "  Queue worker     : ${BOLD}$(yes_no $((1 - NO_QUEUE)))${RESET}   Scheduler: ${BOLD}$(yes_no $((1 - NO_SCHEDULER)))${RESET}"
  fi
  echo -e "  Email            : ${BOLD}${EMAIL:-not set}${RESET}"
  echo -e "  Hostname         : ${BOLD}${HOSTNAME_VAL:-not set}${RESET}"
  echo -e "  Timezone         : ${BOLD}${TIMEZONE:-not set}${RESET}"
  echo -e "  SSH port         : ${BOLD}$SSH_PORT${RESET}"
  echo -e "  Disable root SSH : ${BOLD}$(yes_no "$DISABLE_ROOT_SSH")${RESET}"
  echo -e "  DB name          : ${BOLD}${DB_NAME:-not set}${RESET}"
  echo -e "  DB user          : ${BOLD}${DB_USER:-not set}${RESET}"
  echo -e "  Swap size        : ${BOLD}${SWAP_SIZE:-auto}${RESET}"
  echo -e "  Extra ports      : ${BOLD}${OPEN_PORTS:-none}${RESET}"
  echo -e "  Redis            : $(svc_label redis)"
  echo -e "  Docker           : $(svc_label docker)"
  echo -e "  Firewall         : $(svc_label firewall)"
  echo -e "  Certbot          : $(svc_label certbot)"
  echo -e "  Swap             : $(svc_label swap)"
  echo -e "  PHP Tuning       : $(svc_label phptune)"
  echo -e "  Non-interactive  : ${BOLD}$(yes_no "$NON_INTERACTIVE")${RESET}"
  echo ""

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    log "Non-interactive mode - proceeding automatically"
    return 0
  fi
  local confirm=""
  read -rp "$(echo -e "${BOLD}Proceed with installation? [y/N]:${RESET} ")" confirm || confirm=""
  confirm="${confirm,,}"
  [[ "$confirm" == "y" || "$confirm" == "yes" ]] || error "Installation aborted by user."
  return 0
}

# Checks that depend on the chosen stack - run before ANY change is made.
preflight_stack() {
  [[ "${PULSE_SKIP_PREFLIGHT:-0}" == "1" ]] && return 0
  # shellcheck source=scripts/lib/web.sh
  source "$SCRIPT_DIR/scripts/lib/web.sh"
  case "$STACK" in
    lemp|node|laravel-next) require_port_free 80 "nginx" ;;
    lamp)      require_port_free 80 "apache2|httpd" ;;
  esac
  return 0
}

# ── Run installation ──────────────────────────────────────────────────────────
run_install() {
  preflight_stack

  section "Applying Server Configuration"
  apply_server_config

  section "Updating System Packages"
  os_update

  section "Installing Core Dependencies"
  os_install_base

  # Swap first: it protects the memory-hungry installs that follow.
  # shellcheck source=/dev/null
  if [[ "${SERVICES[swap]}" -eq 1 ]]; then source "$SCRIPT_DIR/scripts/services/swap.sh"; setup_swap; fi

  # shellcheck source=/dev/null
  case "$STACK" in
    lemp) source "$SCRIPT_DIR/scripts/stacks/lemp.sh"; install_lemp ;;
    lamp) source "$SCRIPT_DIR/scripts/stacks/lamp.sh"; install_lamp ;;
    node) source "$SCRIPT_DIR/scripts/stacks/node.sh"; install_node ;;
    laravel-next) source "$SCRIPT_DIR/scripts/stacks/laravel_next.sh"; install_laravel_next ;;
    none) info "Skipping stack installation." ;;
  esac

  # shellcheck source=/dev/null
  if [[ "${SERVICES[firewall]}" -eq 1 ]]; then source "$SCRIPT_DIR/scripts/services/firewall.sh"; setup_firewall; fi
  # shellcheck source=/dev/null
  if [[ "${SERVICES[redis]}"    -eq 1 ]]; then source "$SCRIPT_DIR/scripts/services/redis.sh";    install_redis;  fi
  # shellcheck source=/dev/null
  if [[ "${SERVICES[docker]}"   -eq 1 ]]; then source "$SCRIPT_DIR/scripts/services/docker.sh";   install_docker; fi
  # shellcheck source=/dev/null
  if [[ "${SERVICES[certbot]}"  -eq 1 ]]; then source "$SCRIPT_DIR/scripts/services/certbot.sh";  install_certbot; fi
  # shellcheck source=/dev/null
  if [[ "${SERVICES[phptune]}"  -eq 1 ]]; then source "$SCRIPT_DIR/scripts/services/php_tune.sh"; tune_php_fpm;   fi

  section "PulseDeploy Complete 🎉"
  print_summary
  return 0
}

print_summary() {
  local ip
  ip="$(primary_ip)"
  echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════════╗"
  echo -e "║          PULSEDEPLOY COMPLETE  ⚡            ║"
  echo -e "╚══════════════════════════════════════════════╝${RESET}"
  case "$STACK" in
    lemp|lamp|node|laravel-next) echo -e "  ${CYAN}Server    :${RESET} http://${ip}/" ;;
  esac
  [[ -n "$DOMAIN" && "$STACK" != "none" ]] && echo -e "  ${CYAN}Domain    :${RESET} ${DOMAIN}"
  [[ -n "$DB_NAME" ]] && echo -e "  ${CYAN}Database  :${RESET} $DB_NAME (credentials in /root/.my.cnf)"
  echo -e "  ${CYAN}Log File  :${RESET} $LOG_FILE"
  if [[ "${SERVICES[certbot]}" -eq 0 && -n "$DOMAIN" && ("$STACK" == "lemp" || "$STACK" == "node") ]]; then
    echo -e "  ${CYAN}SSL       :${RESET} Run ${BOLD}certbot --nginx -d ${DOMAIN}${RESET} to issue a cert"
  fi
  echo ""
  return 0
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  validate_inputs
  parse_services # flags/env only; the wizard may add more below
  check_root
  setup_logging
  print_banner
  acquire_lock

  # Without a terminal there is nobody to answer prompts.
  if [[ "$NON_INTERACTIVE" -ne 1 && ! -t 0 ]]; then
    warn "stdin is not a terminal - switching to non-interactive mode."
    NON_INTERACTIVE=1
  fi

  detect_os
  preflight
  select_stack
  select_versions
  select_services
  select_service_options
  validate_inputs
  check_consistency
  confirm_install
  run_install
}

main "$@"
