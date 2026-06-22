#!/usr/bin/env bash
# =============================================================================
# server-bootstrap — VPS & AWS Server Setup Script
# Author  : Mustafizur Rahman (@Xbot-me)
# Repo    : https://github.com/Xbot-me/server-bootstrap
# License : MIT
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/server-bootstrap.log"
BOOTSTRAP_VERSION="1.0.0"
# shellcheck disable=SC2034  # Used in print_banner heredoc

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[✔]${RESET} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[⚠]${RESET} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[✘]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }
info()    { echo -e "${CYAN}[i]${RESET} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${RESET}\n" | tee -a "$LOG_FILE"; }

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
  echo -e "${BOLD}${CYAN}"
  cat <<'EOF'
  ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗
  ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗
  ███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝
  ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗
  ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║
  ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝
  BOOTSTRAP — VPS & AWS Setup Automation v${BOOTSTRAP_VERSION}
  by @Xbot-me · github.com/Xbot-me/server-bootstrap
EOF
  echo -e "${RESET}"
}

# ── Root check ────────────────────────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || error "This script must be run as root. Use: sudo bash bootstrap.sh"
}

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    error "Cannot detect OS. /etc/os-release not found."
  fi

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

# ── Stack selection ───────────────────────────────────────────────────────────
select_stack() {
  section "Stack Selection"
  echo -e "Choose a server stack to install:\n"
  echo -e "  ${BOLD}1)${RESET} LEMP  — Nginx + PHP-FPM + MySQL"
  echo -e "  ${BOLD}2)${RESET} LAMP  — Apache + PHP + MySQL"
  echo -e "  ${BOLD}3)${RESET} Node  — Nginx + Node.js (with PM2)"
  echo -e "  ${BOLD}4)${RESET} Skip  — Core services only (firewall, swap, Docker)"
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

# ── Service selection ─────────────────────────────────────────────────────────
select_services() {
  section "Optional Services"
  declare -gA SERVICES=(
    [redis]=0 [docker]=0 [firewall]=0
    [certbot]=0 [swap]=0 [phptune]=0
  )

  ask_yes_no "Install Redis?"           && SERVICES[redis]=1
  ask_yes_no "Install Docker & Compose?" && SERVICES[docker]=1
  ask_yes_no "Configure UFW/firewall + fail2ban?" && SERVICES[firewall]=1
  ask_yes_no "Install Certbot (SSL)?"   && SERVICES[certbot]=1
  ask_yes_no "Configure swap file?"     && SERVICES[swap]=1
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
  echo -e "  OS           : ${BOLD}$OS_ID $OS_VERSION${RESET}"
  echo -e "  Stack        : ${BOLD}$STACK${RESET}"
  echo -e "  Redis        : $(svc_label redis)"
  echo -e "  Docker       : $(svc_label docker)"
  echo -e "  Firewall     : $(svc_label firewall)"
  echo -e "  Certbot      : $(svc_label certbot)"
  echo -e "  Swap         : $(svc_label swap)"
  echo -e "  PHP Tuning   : $(svc_label phptune)"
  echo ""
  read -rp "$(echo -e "${BOLD}Proceed with installation? [y/N]:${RESET} ")" CONFIRM
  [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || error "Installation aborted by user."
}

svc_label() {
  [[ "${SERVICES[$1]}" -eq 1 ]] && echo -e "${GREEN}✔ Yes${RESET}" || echo -e "${RED}✘ No${RESET}"
}

# ── Run installation ──────────────────────────────────────────────────────────
run_install() {
  section "Updating System Packages"
  os_update

  section "Installing Core Dependencies"
  os_install_base

  # Stack
  # shellcheck disable=SC1091
  case "$STACK" in
    lemp) source "$SCRIPT_DIR/scripts/stacks/lemp.sh";  install_lemp  ;;
    lamp) source "$SCRIPT_DIR/scripts/stacks/lamp.sh";  install_lamp  ;;
    node) source "$SCRIPT_DIR/scripts/stacks/node.sh";  install_node  ;;
    none) info "Skipping stack installation." ;;
  esac

  # shellcheck disable=SC1091
  # Services
  [[ "${SERVICES[swap]}"     -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/swap.sh";     setup_swap;    }
  [[ "${SERVICES[firewall]}" -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/firewall.sh"; setup_firewall; }
  [[ "${SERVICES[redis]}"    -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/redis.sh";    install_redis; }
  [[ "${SERVICES[docker]}"   -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/docker.sh";   install_docker; }
  [[ "${SERVICES[certbot]}"  -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/certbot.sh";  install_certbot; }
  [[ "${SERVICES[phptune]}"  -eq 1 ]] && { source "$SCRIPT_DIR/scripts/services/php_tune.sh"; tune_php_fpm;  }

  section "Bootstrap Complete 🎉"
  log "Log saved to: $LOG_FILE"
  print_summary
}

print_summary() {
  echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════╗"
  echo -e "║        SERVER BOOTSTRAP COMPLETE         ║"
  echo -e "╚══════════════════════════════════════════╝${RESET}"
  [[ "$STACK" == "lemp" || "$STACK" == "lamp" ]] && \
    echo -e "  ${CYAN}PHP Info  :${RESET} http://$(hostname -I | awk '{print $1}')/info.php"
  echo -e "  ${CYAN}Log File  :${RESET} $LOG_FILE"
  echo -e "  ${CYAN}Next step :${RESET} Run ${BOLD}certbot --nginx${RESET} to issue SSL certs"
  echo ""
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/server-bootstrap.log"
  print_banner
  check_root
  detect_os
  select_stack
  select_services
  confirm_install
  run_install
}

main "$@"