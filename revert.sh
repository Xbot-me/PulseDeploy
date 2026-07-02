#!/usr/bin/env bash
# =============================================================================
# PulseDeploy — revert.sh
# Rolls back changes made by bootstrap.sh, component by component.
# Detection-based (checks what's actually present), NOT log-based, since
# bootstrap.sh doesn't currently write a machine-readable install manifest.
# Repo    : https://github.com/Xbot-me/PulseDeploy
# License : MIT
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/server-revert.log"
REVERT_VERSION="0.1.0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${GREEN}[✔]${RESET} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[⚠]${RESET} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[✘]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }
info()    { echo -e "${CYAN}[i]${RESET} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${RESET}\n" | tee -a "$LOG_FILE"; }

handle_error() {
  local exit_code="$1" line_no="$2" last_cmd="$3"
  local func_name="${FUNCNAME[2]:-main}"
  echo -e "\n${RED}${BOLD}✘ revert.sh failed${RESET}" | tee -a "$LOG_FILE"
  echo -e "${RED}  Function   :${RESET} $func_name"    | tee -a "$LOG_FILE"
  echo -e "${RED}  Line       :${RESET} $line_no"      | tee -a "$LOG_FILE"
  echo -e "${RED}  Command    :${RESET} $last_cmd"      | tee -a "$LOG_FILE"
  echo -e "${RED}  Exit code  :${RESET} $exit_code"     | tee -a "$LOG_FILE"
  exit "$exit_code"
}
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR

DRY_RUN=1
ASSUME_YES=0
PURGE_CERTS=0
declare -A DO=( [docker]=0 [redis]=0 [firewall]=0 [certbot]=0 [swap]=0 [stack]=0 [phptune]=0 )
ANY_SELECTED=0

print_help() {
  cat <<EOF
${BOLD}USAGE${RESET}
  sudo bash revert.sh [OPTIONS]

${BOLD}DESCRIPTION${RESET}
  Reverts changes made by bootstrap.sh. Detects what's actually installed
  on this box (not log-based) and removes it. Defaults to a DRY RUN — no
  changes are made unless you pass --yes.

${BOLD}COMPONENT FLAGS${RESET} (omit all to target everything detected)
  --docker         Remove Docker, Compose, its repo + GPG key
  --redis          Remove Redis
  --firewall       Disable ufw, remove fail2ban
  --certbot        Remove Certbot (certs kept unless --purge-certs)
  --swap           Remove /swapfile and its fstab entry
  --stack          Remove LEMP/LAMP/Node packages (nginx/apache/php/mysql/node)
  --phptune        Restore PHP-FPM pool/php.ini from .bak (undo php_tune.sh)
  --all            Target every component above

${BOLD}BEHAVIOUR${RESET}
  --yes            Actually apply changes (required — default is dry-run)
  --purge-certs    Also delete Certbot certificates (irreversible)
  --list           Just show what's currently detected as installed, then exit
  -h, --help       Show this help

${BOLD}EXAMPLES${RESET}
  sudo bash revert.sh --list
  sudo bash revert.sh --docker --redis --yes
  sudo bash revert.sh --all --yes

${BOLD}WARNING${RESET}
  --firewall disables ufw entirely. If you're connected over SSH and rely on
  ufw rules rather than your cloud provider's own firewall, make sure you
  have console/serial access as a fallback before running this.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --docker)       DO[docker]=1;    ANY_SELECTED=1; shift ;;
      --redis)        DO[redis]=1;     ANY_SELECTED=1; shift ;;
      --firewall)     DO[firewall]=1;  ANY_SELECTED=1; shift ;;
      --certbot)      DO[certbot]=1;   ANY_SELECTED=1; shift ;;
      --swap)         DO[swap]=1;      ANY_SELECTED=1; shift ;;
      --stack)        DO[stack]=1;     ANY_SELECTED=1; shift ;;
      --phptune)      DO[phptune]=1;   ANY_SELECTED=1; shift ;;
      --all)          for k in "${!DO[@]}"; do DO[$k]=1; done; ANY_SELECTED=1; shift ;;
      --yes)          DRY_RUN=0; shift ;;
      --purge-certs)  PURGE_CERTS=1; shift ;;
      --list)         LIST_ONLY=1; shift ;;
      -h|--help)      print_help; exit 0 ;;
      *) warn "Unknown flag: $1 — run --help for usage"; shift ;;
    esac
  done
  # No components explicitly picked -> target everything detected
  if [[ "$ANY_SELECTED" -eq 0 ]]; then
    for k in "${!DO[@]}"; do DO[$k]=1; done
  fi
  return 0
}

check_root() {
  [[ $EUID -eq 0 ]] || error "This script must be run as root. Use: sudo bash revert.sh"
  return 0
}

# ── Detection ──────────────────────────────────────────────────────────────
detected_docker()   { command -v docker &>/dev/null || dpkg -l 2>/dev/null | grep -q '^ii  docker-ce '; }
detected_redis()    { dpkg -l 2>/dev/null | grep -q '^ii  redis-server '; }
detected_firewall() { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi active; }
detected_fail2ban() { dpkg -l 2>/dev/null | grep -q '^ii  fail2ban '; }
detected_certbot()  { command -v certbot &>/dev/null; }
detected_swap()     { [[ -f /swapfile ]] || swapon --show 2>/dev/null | grep -q .; }
detected_nginx()    { dpkg -l 2>/dev/null | grep -q '^ii  nginx'; }
detected_apache()   { dpkg -l 2>/dev/null | grep -q '^ii  apache2 '; }
detected_php()      { dpkg -l 2>/dev/null | grep -q '^ii  php[0-9.]*-fpm'; }
detected_mysql()    { dpkg -l 2>/dev/null | grep -qE '^ii  (mysql|mariadb)-server'; }
detected_node()     { command -v node &>/dev/null; }
detected_phptune()  { find /etc/php -name "*.bak" 2>/dev/null | grep -q .; }

show_status() {
  section "Detected Components"
  printf "  %-12s %s\n" "Docker:"   "$(detected_docker   && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "Redis:"    "$(detected_redis    && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "UFW:"      "$(detected_firewall && echo -e "${GREEN}active${RESET}"  || echo -e "${RED}inactive${RESET}")"
  printf "  %-12s %s\n" "fail2ban:" "$(detected_fail2ban && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "Certbot:"  "$(detected_certbot  && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "Swap:"     "$(detected_swap     && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "Nginx:"    "$(detected_nginx    && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "Apache:"   "$(detected_apache   && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "PHP-FPM:"  "$(detected_php      && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "MySQL:"    "$(detected_mysql    && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "Node.js:"  "$(detected_node     && echo -e "${GREEN}present${RESET}" || echo -e "${RED}absent${RESET}")"
  printf "  %-12s %s\n" "PHP tune:" "$(detected_phptune  && echo -e "${GREEN}applied${RESET}" || echo -e "${RED}not applied${RESET}")"
  echo ""
  return 0
}

run_or_echo() {
  # In dry-run mode, print the command instead of running it.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${YELLOW}  [dry-run]${RESET} $*"
  else
    "$@"
  fi
  return 0
}

# ── Revert functions ──────────────────────────────────────────────────────
revert_docker() {
  if ! detected_docker; then info "Docker not detected — skipping"; return 0; fi
  section "Reverting Docker"
  run_or_echo systemctl stop docker
  run_or_echo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_or_echo dnf remove -y docker docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_or_echo rm -rf /var/lib/docker /var/lib/containerd
  run_or_echo rm -f /etc/apt/sources.list.d/docker.list
  # NOTE: install_docker() writes the GPG key to /etc/apt/keyrings/docker.gpg
  run_or_echo rm -f /etc/apt/keyrings/docker.gpg
  run_or_echo rm -f /usr/local/bin/docker-compose
  run_or_echo rm -f /etc/docker/daemon.json
  run_or_echo rm -f /etc/cron.d/docker-weekly-prune
  run_or_echo rm -f /var/log/docker-prune.log
  run_or_echo groupdel docker
  [[ "$DRY_RUN" -eq 0 ]] && log "Docker removed" || info "(dry-run) would remove Docker"
  return 0
}

revert_redis() {
  if ! detected_redis; then info "Redis not detected — skipping"; return 0; fi
  section "Reverting Redis"
  local svc="redis-server"
  command -v redis-server &>/dev/null || svc="redis"
  run_or_echo systemctl stop "$svc"
  run_or_echo apt-get purge -y redis-server redis-tools
  run_or_echo dnf remove -y redis
  run_or_echo rm -rf /etc/redis /var/lib/redis
  [[ "$DRY_RUN" -eq 0 ]] && log "Redis removed" || info "(dry-run) would remove Redis"
  return 0
}

revert_firewall() {
  local have_ufw=0 have_firewalld=0 have_f2b=0
  detected_firewall && have_ufw=1
  { command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; } && have_firewalld=1
  detected_fail2ban && have_f2b=1
  if [[ "$have_ufw" -eq 0 && "$have_firewalld" -eq 0 && "$have_f2b" -eq 0 ]]; then
    info "No active ufw/firewalld/fail2ban detected — skipping"; return 0
  fi
  section "Reverting Firewall"
  warn "This disables your firewall entirely. Make sure you have console/serial"
  warn "access as a fallback in case your cloud provider's own firewall isn't set up."
  if [[ "$DRY_RUN" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
    read -rp "$(echo -e "${YELLOW}Type YES to confirm disabling the firewall:${RESET} ")" CONF
    [[ "$CONF" == "YES" ]] || { warn "Skipped firewall revert (not confirmed)"; return 0; }
  fi
  [[ "$have_ufw" -eq 1 ]] && run_or_echo ufw --force disable
  [[ "$have_firewalld" -eq 1 ]] && run_or_echo systemctl disable --now firewalld
  run_or_echo apt-get purge -y fail2ban
  run_or_echo dnf remove -y fail2ban
  run_or_echo rm -f /etc/fail2ban/jail.local
  [[ "$DRY_RUN" -eq 0 ]] && log "Firewall reverted" || info "(dry-run) would disable firewall + remove fail2ban"
  return 0
}

revert_certbot() {
  if ! detected_certbot; then info "Certbot not detected — skipping"; return 0; fi
  section "Reverting Certbot"
  # install_certbot() prefers snap (--classic certbot), falling back to apt
  # only if snap fails. Try both removal paths.
  if command -v snap &>/dev/null && snap list certbot &>/dev/null; then
    run_or_echo snap remove --purge certbot
  fi
  run_or_echo apt-get purge -y certbot python3-certbot-nginx python3-certbot-apache
  run_or_echo rm -f /usr/local/bin/certbot
  # install_certbot() adds a renewal job to root's crontab, NOT /etc/cron.d
  if [[ "$DRY_RUN" -eq 0 ]]; then
    crontab -l 2>/dev/null | grep -v 'certbot renew' | crontab - 2>/dev/null || true
  else
    echo -e "${YELLOW}  [dry-run]${RESET} remove certbot renew line from root's crontab"
  fi
  if [[ "$PURGE_CERTS" -eq 1 ]]; then
    warn "Deleting certificates in /etc/letsencrypt — this is irreversible"
    run_or_echo rm -rf /etc/letsencrypt
  else
    info "Certificates left in place — pass --purge-certs to also delete them"
  fi
  [[ "$DRY_RUN" -eq 0 ]] && log "Certbot removed" || info "(dry-run) would remove Certbot"
  return 0
}

revert_swap() {
  if ! detected_swap; then info "No swap detected — skipping"; return 0; fi
  section "Reverting Swap"
  run_or_echo swapoff /swapfile
  if [[ "$DRY_RUN" -eq 0 ]]; then
    sed -i '\#/swapfile#d' /etc/fstab
  else
    echo -e "${YELLOW}  [dry-run]${RESET} remove /swapfile line from /etc/fstab"
  fi
  run_or_echo rm -f /swapfile
  # setup_swap() writes vm.swappiness/vfs_cache_pressure tuning here
  run_or_echo rm -f /etc/sysctl.d/99-swap.conf
  run_or_echo sysctl -w vm.swappiness=60
  run_or_echo sysctl -w vm.vfs_cache_pressure=100
  [[ "$DRY_RUN" -eq 0 ]] && log "Swap removed" || info "(dry-run) would remove swap"
  return 0
}

revert_phptune() {
  if ! detected_phptune; then info "No php_tune.sh backups detected — skipping"; return 0; fi
  section "Reverting PHP-FPM Tuning"
  local restored=0
  while IFS= read -r bak; do
    local orig="${bak%.bak}"
    info "Restoring $orig from backup"
    run_or_echo cp "$bak" "$orig"
    restored=1
  done < <(find /etc/php -name "*.bak" 2>/dev/null)
  if [[ "$restored" -eq 1 ]]; then
    run_or_echo systemctl restart php-fpm
    for f in /etc/init.d/php*-fpm; do
      [[ -e "$f" ]] && run_or_echo systemctl restart "$(basename "$f")"
    done
  fi
  [[ "$DRY_RUN" -eq 0 ]] && log "PHP-FPM config restored from backup" || info "(dry-run) would restore PHP-FPM config from .bak files"
  return 0
}

revert_stack() {
  local any=0
  detected_nginx  && any=1
  detected_apache && any=1
  detected_php    && any=1
  detected_mysql  && any=1
  detected_node   && any=1
  if [[ "$any" -eq 0 ]]; then info "No stack packages detected — skipping"; return 0; fi

  section "Reverting Stack Packages"
  warn "This removes web server / DB / runtime packages. Site content in"
  warn "/var/www is NOT deleted, only the packages that serve it."
  if [[ "$DRY_RUN" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
    read -rp "$(echo -e "${YELLOW}Type YES to confirm removing stack packages:${RESET} ")" CONF
    [[ "$CONF" == "YES" ]] || { warn "Skipped stack revert (not confirmed)"; return 0; }
  fi

  detected_nginx  && run_or_echo apt-get purge -y nginx nginx-common
  detected_apache && run_or_echo apt-get purge -y apache2
  detected_php    && run_or_echo bash -c "apt-get purge -y 'php*'"
  detected_mysql  && run_or_echo apt-get purge -y mysql-server mariadb-server
  detected_node   && info "Node.js left in place (installed via nvm/tarball in most setups — remove manually if needed)"

  [[ "$DRY_RUN" -eq 0 ]] && log "Stack packages reverted" || info "(dry-run) would remove stack packages"
  return 0
}

cleanup_apt() {
  section "Cleaning Up"
  run_or_echo apt-get autoremove -y
  run_or_echo apt-get autoclean -y
  [[ "$DRY_RUN" -eq 0 ]] && log "apt cache cleaned" || info "(dry-run) would run apt-get autoremove/autoclean"
  return 0
}

main() {
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/server-revert.log"
  parse_args "$@"
  check_root

  echo -e "${BOLD}${CYAN}PulseDeploy revert.sh v${REVERT_VERSION}${RESET}"

  show_status
  [[ "${LIST_ONLY:-0}" -eq 1 ]] && exit 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN — no changes will be made. Re-run with --yes to actually apply."
  fi

  [[ "${DO[docker]}"   -eq 1 ]] && revert_docker
  [[ "${DO[redis]}"    -eq 1 ]] && revert_redis
  [[ "${DO[certbot]}"  -eq 1 ]] && revert_certbot
  [[ "${DO[stack]}"    -eq 1 ]] && revert_stack
  [[ "${DO[phptune]}"  -eq 1 ]] && revert_phptune
  [[ "${DO[swap]}"     -eq 1 ]] && revert_swap
  [[ "${DO[firewall]}" -eq 1 ]] && revert_firewall

  if [[ "$DRY_RUN" -eq 0 ]]; then
    cleanup_apt
    section "Revert Complete"
    log "Log saved to: $LOG_FILE"
  else
    echo ""
    info "This was a dry run. Nothing was changed. Add --yes to apply."
  fi
}

main "$@"