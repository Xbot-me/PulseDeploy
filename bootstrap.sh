#!/usr/bin/env bash
# =============================================================================
# PulseDeploy — VPS & AWS Server Setup Script
# Author  : Mustafizur Rahman (@Xbot-me)
# Repo    : https://github.com/Xbot-me/PulseDeploy
# License : MIT
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/server-bootstrap.log"
# shellcheck disable=SC2034  # Used in print_banner below
BOOTSTRAP_VERSION="1.1.0"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[✔]${RESET} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[⚠]${RESET} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[✘]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }
info()    { echo -e "${CYAN}[i]${RESET} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${RESET}\n" | tee -a "$LOG_FILE"; }

# ── Defaults (overridden by flags / env vars) ─────────────────────────────────
STACK="${PULSE_STACK:-}"
PHP_VER="${PULSE_PHP:-8.2}"
NODE_VER="${PULSE_NODE:-20}"
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

declare -gA SERVICES=(
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
}

# ── Help ──────────────────────────────────────────────────────────────────────
print_help() {
  cat <<EOF
${BOLD}USAGE${RESET}
  sudo bash bootstrap.sh [OPTIONS]

${BOLD}DESCRIPTION${RESET}
  PulseDeploy is a modular Bash toolkit for spinning up production-ready Linux
  servers on VPS providers and AWS EC2. Run with no flags for the interactive
  wizard, or pass flags for fully automated / CI deployments.

${BOLD}STACK OPTIONS${RESET}
  -s, --stack <stack>       Stack to install: lemp | lamp | node | none
                            Env: PULSE_STACK
  -P, --php <version>       PHP version: 8.1 | 8.2 | 8.3  (default: 8.2)
                            Env: PULSE_PHP
  -N, --node <version>      Node.js LTS version: 18 | 20 | 22  (default: 20)
                            Env: PULSE_NODE

${BOLD}SERVICE FLAGS${RESET}
  -S, --services <list>     Comma-separated services to enable:
                            redis, docker, firewall, certbot, swap, phptune
                            Env: PULSE_SERVICES
                            Example: --services redis,firewall,swap,certbot

${BOLD}SERVER CONFIGURATION${RESET}
      --domain <domain>     Primary domain name (used by Certbot & vhost)
                            Env: PULSE_DOMAIN
      --email <email>       Email for Certbot SSL notifications
                            Env: PULSE_EMAIL
      --hostname <name>     Set server hostname
                            Env: PULSE_HOSTNAME
      --timezone <tz>       Set system timezone (e.g. Asia/Dhaka, UTC)
                            Env: PULSE_TIMEZONE
      --ssh-port <port>     SSH port to allow through firewall (default: 22)
                            Env: PULSE_SSH_PORT
      --disable-root-ssh    Disable root SSH login (PermitRootLogin no)
                            Env: PULSE_DISABLE_ROOT_SSH=1
      --app-port <port>     Node.js app port for Nginx proxy (default: 3000)
                            Env: PULSE_APP_PORT

${BOLD}DATABASE${RESET}
      --db-name <name>      Create a database with this name after MySQL install
                            Env: PULSE_DB_NAME
      --db-user <user>      Create a DB user with this name (random password)
                            Env: PULSE_DB_USER

${BOLD}SWAP${RESET}
      --swap-size <size>    Swap file size, e.g. 2G, 4G (default: auto)
                            Env: PULSE_SWAP_SIZE

${BOLD}BEHAVIOUR${RESET}
  -y, --non-interactive     Skip all prompts; use flag values or defaults
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

  # Node.js server, non-interactive
  sudo bash bootstrap.sh -s node -N 20 -S firewall,swap,docker -y

  # Via environment variables (AWS EC2 user-data / cloud-init)
  export PULSE_STACK=lemp
  export PULSE_PHP=8.2
  export PULSE_SERVICES=redis,firewall,swap,certbot
  export PULSE_DOMAIN=example.com
  export PULSE_EMAIL=admin@example.com
  export PULSE_NON_INTERACTIVE=1
  sudo -E bash bootstrap.sh

${BOLD}MAN PAGE${RESET}
  After installing the man page (docs/install-man.sh):
  man pulsedeploy

${BOLD}DOCS & SOURCE${RESET}
  https://github.com/Xbot-me/PulseDeploy
  https://github.com/Xbot-me/PulseDeploy/wiki

EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--stack)              STACK="$2";            shift 2 ;;
      -P|--php)                PHP_VER="$2";          shift 2 ;;
      -N|--node)               NODE_VER="$2";         shift 2 ;;
      -S|--services)           SERVICES_RAW="$2";     shift 2 ;;
         --domain)             DOMAIN="$2";           shift 2 ;;
         --email)              EMAIL="$2";            shift 2 ;;
         --hostname)           HOSTNAME_VAL="$2";     shift 2 ;;
         --timezone)           TIMEZONE="$2";         shift 2 ;;
         --ssh-port)           SSH_PORT="$2";         shift 2 ;;
         --disable-root-ssh)   DISABLE_ROOT_SSH=1;    shift   ;;
         --app-port)           APP_PORT="$2";         shift 2 ;;
         --db-name)            DB_NAME="$2";          shift 2 ;;
         --db-user)            DB_USER="$2";          shift 2 ;;
         --swap-size)          SWAP_SIZE="$2";        shift 2 ;;
      -y|--non-interactive)    NON_INTERACTIVE=1;     shift   ;;
      -h|--help)               print_help;            exit 0  ;;
      -v|--version)            echo "PulseDeploy v${BOOTSTRAP_VERSION}"; exit 0 ;;
      *) warn "Unknown flag: $1 — run --help for usage"; shift ;;
    esac
  done
}

# ── Parse services list ───────────────────────────────────────────────────────
parse_services() {
  [[ -z "$SERVICES_RAW" ]] && return
  IFS=',' read -ra SVC_LIST <<< "$SERVICES_RAW"
  for svc in "${SVC_LIST[@]}"; do
    svc="${svc// /}"  # trim spaces
    case "$svc" in
      redis|docker|firewall|certbot|swap|phptune) SERVICES[$svc]=1 ;;
      *) warn "Unknown service: '$svc'. Valid: redis,docker,firewall,certbot,swap,phptune" ;;
    esac
  done
}

# ── Apply server config flags ─────────────────────────────────────────────────
apply_server_config() {
  # Hostname
  if [[ -n "$HOSTNAME_VAL" ]]; then
    hostnamectl set-hostname "$HOSTNAME_VAL" 2>/dev/null || hostname "$HOSTNAME_VAL"
    log "Hostname set to: $HOSTNAME_VAL"
  fi

  # Timezone
  if [[ -n "$TIMEZONE" ]]; then
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || \
      ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    log "Timezone set to: $TIMEZONE"
  fi

  # Disable root SSH
  if [[ "$DISABLE_ROOT_SSH" -eq 1 ]]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    log "Root SSH login disabled"
    warn "Ensure you have a sudo user before your next SSH session!"
  fi
}

# ── Create DB + user after MySQL install ──────────────────────────────────────
create_database() {
  [[ -z "$DB_NAME" && -z "$DB_USER" ]] && return

  local DB_PASS
  DB_PASS=$(tr -dc 'A-Za-z0-9!@#$%' </dev/urandom | head -c 20)

  if [[ -n "$DB_NAME" ]]; then
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;" 2>/dev/null
    log "Database created: $DB_NAME"
  fi

  if [[ -n "$DB_USER" && -n "$DB_NAME" ]]; then
    mysql -u root <<SQL 2>/dev/null
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    # Save credentials
    cat >> /root/.my.cnf <<CREDS

[client_${DB_USER}]
user=${DB_USER}
password=${DB_PASS}
database=${DB_NAME}
CREDS
    log "DB user created: $DB_USER — credentials appended to /root/.my.cnf"
  fi
}

# ── Root check ────────────────────────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || error "This script must be run as root. Use: sudo bash bootstrap.sh"
}

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    error "Cannot detect OS. /etc/os-release not found."
  fi

  # shellcheck disable=SC2034  # PKG_MANAGER used by sourced OS modules
  case "$OS_ID" in
    ubuntu)
      PKG_MANAGER="apt"
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/scripts/os/ubuntu.sh"
      ;;
    debian)
      PKG_MANAGER="apt"
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/scripts/os/debian.sh"
      ;;
    amzn)
      PKG_MANAGER="dnf"
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/scripts/os/amazon_linux.sh"
      ;;
    centos|rocky|rhel|almalinux)
      PKG_MANAGER="dnf"
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/scripts/os/centos_rocky.sh"
      ;;
    *)
      error "Unsupported OS: $OS_ID. Supported: Ubuntu, Debian, Amazon Linux, CentOS/Rocky."
      ;;
  esac

  log "Detected OS: $OS_ID $OS_VERSION"
}

# ── Interactive: Stack selection ──────────────────────────────────────────────
select_stack() {
  [[ -n "$STACK" ]] && { log "Stack (from flag): $STACK"; return; }

  section "Stack Selection"
  echo -e "Choose a server stack to install:\n"
  echo -e "  ${BOLD}1)${RESET} LEMP  — Nginx + PHP-FPM + MySQL"
  echo -e "  ${BOLD}2)${RESET} LAMP  — Apache + PHP + MySQL"
  echo -e "  ${BOLD}3)${RESET} Node  — Nginx + Node.js (with PM2)"
  echo -e "  ${BOLD}4)${RESET} Skip  — Core services only"
  echo ""
  read -rp "$(echo -e "${CYAN}Enter choice [1-4]:${RESET} ")" STACK_CHOICE

  case "$STACK_CHOICE" in
    1) STACK="lemp" ;;
    2) STACK="lamp" ;;
    3) STACK="node" ;;
    4) STACK="none" ;;
    *) warn "Invalid choice. Defaulting to LEMP."; STACK="lemp" ;;
  esac

  log "Stack selected: $STACK"
}

# ── Interactive: Service selection ────────────────────────────────────────────
select_services() {
  # If services were passed via flag/env, skip interactive
  if [[ -n "$SERVICES_RAW" ]]; then
    parse_services
    log "Services (from flag): $SERVICES_RAW"
    return
  fi

  [[ "$NON_INTERACTIVE" -eq 1 ]] && return

  section "Optional Services"

  ask_yes_no "Install Redis?"                    && SERVICES[redis]=1
  ask_yes_no "Install Docker & Compose?"          && SERVICES[docker]=1
  ask_yes_no "Configure firewall + fail2ban?"     && SERVICES[firewall]=1
  ask_yes_no "Install Certbot (SSL)?"             && SERVICES[certbot]=1
  ask_yes_no "Configure swap file?"               && SERVICES[swap]=1
  [[ "$STACK" == "lemp" || "$STACK" == "lamp" ]] && \
    ask_yes_no "Apply PHP-FPM performance tuning?" && SERVICES[phptune]=1
}

ask_yes_no() {
  local prompt="$1"
  read -rp "$(echo -e "${YELLOW}${prompt} [y/N]:${RESET} ")" ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ── Confirmation ──────────────────────────────────────────────────────────────
confirm_install() {
  section "Installation Summary"
  echo -e "  OS               : ${BOLD}$OS_ID $OS_VERSION${RESET}"
  echo -e "  Stack            : ${BOLD}$STACK${RESET}"
  echo -e "  PHP version      : ${BOLD}$PHP_VER${RESET}"
  echo -e "  Node version     : ${BOLD}$NODE_VER${RESET}"
  echo -e "  Domain           : ${BOLD}${DOMAIN:-not set}${RESET}"
  echo -e "  Email            : ${BOLD}${EMAIL:-not set}${RESET}"
  echo -e "  Hostname         : ${BOLD}${HOSTNAME_VAL:-not set}${RESET}"
  echo -e "  Timezone         : ${BOLD}${TIMEZONE:-not set}${RESET}"
  echo -e "  SSH port         : ${BOLD}$SSH_PORT${RESET}"
  echo -e "  Disable root SSH : ${BOLD}$([ "$DISABLE_ROOT_SSH" -eq 1 ] && echo Yes || echo No)${RESET}"
  echo -e "  DB name          : ${BOLD}${DB_NAME:-not set}${RESET}"
  echo -e "  DB user          : ${BOLD}${DB_USER:-not set}${RESET}"
  echo -e "  Swap size        : ${BOLD}${SWAP_SIZE:-auto}${RESET}"
  echo -e "  Redis            : $(svc_label redis)"
  echo -e "  Docker           : $(svc_label docker)"
  echo -e "  Firewall         : $(svc_label firewall)"
  echo -e "  Certbot          : $(svc_label certbot)"
  echo -e "  Swap             : $(svc_label swap)"
  echo -e "  PHP Tuning       : $(svc_label phptune)"
  echo -e "  Non-interactive  : ${BOLD}$([ "$NON_INTERACTIVE" -eq 1 ] && echo Yes || echo No)${RESET}"
  echo ""

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    log "Non-interactive mode — proceeding automatically"
    return
  fi

  read -rp "$(echo -e "${BOLD}Proceed with installation? [y/N]:${RESET} ")" CONFIRM
  [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || error "Installation aborted by user."
}

svc_label() {
  [[ "${SERVICES[$1]}" -eq 1 ]] && echo -e "${GREEN}✔ Yes${RESET}" || echo -e "${RED}✘ No${RESET}"
}

# ── Export flags for use in sub-modules ───────────────────────────────────────
export_flags() {
  export PULSE_STACK="$STACK"
  export PULSE_PHP="$PHP_VER"
  export PULSE_NODE="$NODE_VER"
  export PULSE_APP_PORT="$APP_PORT"
  export PULSE_DOMAIN="$DOMAIN"
  export PULSE_EMAIL="$EMAIL"
  export PULSE_SSH_PORT="$SSH_PORT"
  export PULSE_SWAP_SIZE="$SWAP_SIZE"
}

# ── Run installation ──────────────────────────────────────────────────────────
run_install() {
  export_flags

  section "Applying Server Configuration"
  apply_server_config

  section "Updating System Packages"
  os_update

  section "Installing Core Dependencies"
  os_install_base

  # Stack
  # shellcheck disable=SC1091
  case "$STACK" in
    lemp) source "$SCRIPT_DIR/scripts/stacks/lemp.sh";  install_lemp ;;
    lamp) source "$SCRIPT_DIR/scripts/stacks/lamp.sh";  install_lamp ;;
    node) source "$SCRIPT_DIR/scripts/stacks/node.sh";  install_node ;;
    none) info "Skipping stack installation." ;;
  esac

  # Create DB if flags were set
  [[ "$STACK" == "lemp" || "$STACK" == "lamp" ]] && create_database

  # shellcheck disable=SC1091
  [[ "${SERVICES[swap]}"     -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/swap.sh";     setup_swap;     }
  [[ "${SERVICES[firewall]}" -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/firewall.sh"; setup_firewall; }
  [[ "${SERVICES[redis]}"    -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/redis.sh";    install_redis;  }
  [[ "${SERVICES[docker]}"   -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/docker.sh";   install_docker; }
  [[ "${SERVICES[certbot]}"  -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/certbot.sh";  install_certbot; }
  [[ "${SERVICES[phptune]}"  -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/php_tune.sh"; tune_php_fpm;   }

  section "PulseDeploy Complete 🎉"
  log "Log saved to: $LOG_FILE"
  print_summary
}

print_summary() {
  echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════════╗"
  echo -e "║          PULSEDEPLOY COMPLETE  ⚡            ║"
  echo -e "╚══════════════════════════════════════════════╝${RESET}"
  [[ "$STACK" == "lemp" || "$STACK" == "lamp" ]] && \
    echo -e "  ${CYAN}PHP Info  :${RESET} http://$(hostname -I | awk '{print $1}')/info.php"
  [[ -n "$DOMAIN" ]] && \
    echo -e "  ${CYAN}Domain    :${RESET} http://${DOMAIN}"
  [[ -n "$DB_NAME" ]] && \
    echo -e "  ${CYAN}Database  :${RESET} $DB_NAME (credentials in /root/.my.cnf)"
  echo -e "  ${CYAN}Log File  :${RESET} $LOG_FILE"
  [[ "${SERVICES[certbot]}" -eq 0 && -n "$DOMAIN" ]] && \
    echo -e "  ${CYAN}SSL       :${RESET} Run ${BOLD}certbot --nginx -d ${DOMAIN}${RESET} to issue cert"
  echo ""
  warn "Delete /var/www/html/info.php after verifying PHP works!"
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/server-bootstrap.log"
  parse_args "$@"
  print_banner
  check_root
  detect_os
  select_stack
  select_services
  confirm_install
  run_install
}

main "$@"