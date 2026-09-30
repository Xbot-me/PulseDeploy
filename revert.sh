#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - revert.sh
# Rolls back changes made by bootstrap.sh, component by component.
# Detection-based (checks what's actually present), works on apt and dnf/yum
# systems. Defaults to a DRY RUN; databases, Redis dumps and Docker data are
# kept unless --purge-data is given.
# Repo    : https://github.com/Xbot-me/PulseDeploy
# License : MIT
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${PULSE_REVERT_LOG_FILE:-/var/log/server-revert.log}"
REVERT_VERSION="0.2.0"

if [[ ! -f "$SCRIPT_DIR/scripts/lib/common.sh" ]]; then
  echo "revert.sh must be run from a full PulseDeploy checkout." >&2
  exit 1
fi
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

if command -v apt-get &>/dev/null; then PKG_MANAGER="apt"
elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then PKG_MANAGER="dnf"
else PKG_MANAGER="unknown"; fi

handle_error() {
  local exit_code="$1" file="$2" line_no="$3" last_cmd="$4"
  trap - ERR
  {
    echo -e "\n${RED}${BOLD}✘ revert.sh failed${RESET}"
    echo -e "${RED}  Function   :${RESET} ${FUNCNAME[1]:-main}"
    echo -e "${RED}  Location   :${RESET} ${file}:${line_no}"
    echo -e "${RED}  Command    :${RESET} $last_cmd"
    echo -e "${RED}  Exit code  :${RESET} $exit_code"
  } >&2
  exit "$exit_code"
}
trap 'handle_error $? "${BASH_SOURCE[0]##*/}" $LINENO "$BASH_COMMAND"' ERR

DRY_RUN=1
ASSUME_YES=0
PURGE_CERTS=0
PURGE_DATA=0
LIST_ONLY=0
declare -A TARGET=( [docker]=0 [redis]=0 [firewall]=0 [certbot]=0 [swap]=0 [stack]=0 [phptune]=0 )
ANY_SELECTED=0

print_help() {
  cat <<EOF
${BOLD}USAGE${RESET}
  sudo bash revert.sh [OPTIONS]

${BOLD}DESCRIPTION${RESET}
  Reverts changes made by bootstrap.sh. Detects what's actually installed
  on this box (not log-based) and removes it. Defaults to a DRY RUN - no
  changes are made unless you pass --yes.

${BOLD}COMPONENT FLAGS${RESET} (omit all to target everything detected)
  --docker         Remove Docker, Compose, its repo + GPG key
  --redis          Remove Redis
  --firewall       Disable ufw/firewalld, remove fail2ban
  --certbot        Remove Certbot (certs kept unless --purge-certs)
  --swap           Remove /swapfile and its fstab entry
  --stack          Remove LEMP/LAMP/Node packages (nginx/apache/php/mysql/node)
  --phptune        Undo PHP tuning (drop-in ini files, restore pool config)
  --all            Target every component above

${BOLD}BEHAVIOUR${RESET}
  --yes            Actually apply changes (required - default is dry-run)
  --no-confirm     Skip the typed-YES prompts for firewall/stack (automation)
  --purge-data     ALSO delete data: /var/lib/mysql, /var/lib/redis,
                   /var/lib/docker, /var/lib/containerd  (irreversible)
  --purge-certs    ALSO delete Certbot certificates (irreversible)
  --list           Just show what's currently detected as installed, then exit
  -h, --help       Show this help

${BOLD}EXAMPLES${RESET}
  sudo bash revert.sh --list
  sudo bash revert.sh --docker --redis --yes
  sudo bash revert.sh --all --yes --no-confirm

${BOLD}WARNING${RESET}
  --firewall disables your OS firewall entirely. If you're connected over SSH
  and rely on it rather than your cloud provider's firewall, make sure you
  have console/serial access as a fallback before running this.
EOF
  return 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --docker)       TARGET[docker]=1;    ANY_SELECTED=1; shift ;;
      --redis)        TARGET[redis]=1;     ANY_SELECTED=1; shift ;;
      --firewall)     TARGET[firewall]=1;  ANY_SELECTED=1; shift ;;
      --certbot)      TARGET[certbot]=1;   ANY_SELECTED=1; shift ;;
      --swap)         TARGET[swap]=1;      ANY_SELECTED=1; shift ;;
      --stack)        TARGET[stack]=1;     ANY_SELECTED=1; shift ;;
      --phptune)      TARGET[phptune]=1;   ANY_SELECTED=1; shift ;;
      --all)          local k; for k in "${!TARGET[@]}"; do TARGET[$k]=1; done; ANY_SELECTED=1; shift ;;
      --yes)          DRY_RUN=0; shift ;;
      --no-confirm)   ASSUME_YES=1; shift ;;
      --purge-data)   PURGE_DATA=1; shift ;;
      --purge-certs)  PURGE_CERTS=1; shift ;;
      --list)         LIST_ONLY=1; shift ;;
      -h|--help)      print_help; exit 0 ;;
      *) error "Unknown option: $1 - run --help for usage" ;;
    esac
  done
  # No components explicitly picked -> target everything detected
  if [[ "$ANY_SELECTED" -eq 0 ]]; then
    local k
    for k in "${!TARGET[@]}"; do TARGET[$k]=1; done
  fi
  return 0
}

check_root() {
  [[ $EUID -eq 0 ]] || error "This script must be run as root. Use: sudo bash revert.sh"
  return 0
}

# ── Helpers ────────────────────────────────────────────────────────────────
# Run a command, or just print it in dry-run mode. A failing step is reported
# and skipped so one missing service never aborts the rest of the revert.
run_or_echo() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${YELLOW}  [dry-run]${RESET} $*"
  elif ! "$@"; then
    warn "Step failed (continuing): $*"
  fi
  return 0
}

applied() { [[ "$DRY_RUN" -eq 0 ]]; }

# installed_matching <pattern>... - names of installed packages matching globs
installed_matching() {
  case "$PKG_MANAGER" in
    apt)
      dpkg-query -W -f='${Package}\t${Status}\n' "$@" 2>/dev/null |
        awk -F'\t' '$2 ~ /install ok installed/ { print $1 }' || true
      ;;
    dnf)
      local pat
      for pat in "$@"; do rpm -qa --qf '%{NAME}\n' "$pat" 2>/dev/null || true; done | sort -u
      ;;
  esac
}

any_installed() { [[ -n "$(installed_matching "$@")" ]]; }

# remove_matching <purge|keep> <pattern>...
# purge → also drops package config (apt purge); keep → leaves data/config.
remove_matching() {
  local mode="$1"
  shift
  local -a pkgs
  mapfile -t pkgs < <(installed_matching "$@")
  ((${#pkgs[@]})) || return 0
  case "$PKG_MANAGER" in
    apt)
      if [[ "$mode" == "purge" ]]; then run_or_echo apt_get purge "${pkgs[@]}"
      else run_or_echo apt_get remove "${pkgs[@]}"; fi
      ;;
    dnf) run_or_echo pm_rpm remove -y "${pkgs[@]}" ;;
  esac
  return 0
}

stop_units() {
  local u
  for u in "$@"; do
    if svc_exists "$u" 2>/dev/null; then
      run_or_echo systemctl disable --now "$u"
    fi
  done
  return 0
}

confirm_typed() {
  [[ "$DRY_RUN" -eq 0 && "$ASSUME_YES" -eq 0 ]] || return 0
  local conf=""
  read -rp "$(echo -e "${YELLOW}$1 Type YES to confirm:${RESET} ")" conf || conf=""
  [[ "$conf" == "YES" ]]
}

# ── Detection ──────────────────────────────────────────────────────────────
detected_docker()   { command -v docker &>/dev/null || any_installed docker-ce docker.io docker; }
detected_redis()    { any_installed redis-server redis redis6 redis7; }
detected_firewall() {
  { command -v ufw &>/dev/null && [[ "$(ufw status 2>/dev/null | head -n 1)" == "Status: active" ]]; } ||
    { command -v firewall-cmd &>/dev/null && svc_active firewalld; }
}
detected_fail2ban() { any_installed fail2ban; }
detected_certbot()  { command -v certbot &>/dev/null; }
# Only swap created by PulseDeploy: its sysctl file is the marker (early
# versions wrote the same values without the comment line).
detected_swap() {
  [[ -f /swapfile && -f /etc/sysctl.d/99-swap.conf ]] &&
    grep -Eq 'Managed by PulseDeploy|vm\.vfs_cache_pressure=50' /etc/sysctl.d/99-swap.conf
}
detected_nginx()    { any_installed nginx; }
detected_apache()   { any_installed apache2 httpd; }
detected_php()      { [[ -n "$(installed_matching 'php*')" ]]; }
detected_mysql()    { any_installed 'mysql-server*' 'mariadb-server*' 'mysql-community-server*' 'mariadb*-server'; }
detected_node()     { command -v node &>/dev/null; }
detected_phptune()  {
  compgen -G '/etc/php/*/*/conf.d/99-pulsedeploy.ini' >/dev/null ||
    [[ -f /etc/php.d/99-pulsedeploy.ini ]] ||
    compgen -G '/etc/php/*/fpm/pool.d/*.pulsedeploy.bak' >/dev/null ||
    [[ -f /etc/php-fpm.d/www.conf.pulsedeploy.bak ]]
}

show_status() {
  section "Detected Components"
  local present="${GREEN}present${RESET}" absent="${RED}absent${RESET}"
  status_line() { if "$2"; then printf "  %-12s %s\n" "$1" "$present"; else printf "  %-12s %s\n" "$1" "$absent"; fi; }
  status_line "Docker:"   detected_docker
  status_line "Redis:"    detected_redis
  status_line "Firewall:" detected_firewall
  status_line "fail2ban:" detected_fail2ban
  status_line "Certbot:"  detected_certbot
  status_line "Swap:"     detected_swap
  status_line "Nginx:"    detected_nginx
  status_line "Apache:"   detected_apache
  status_line "PHP:"      detected_php
  status_line "Database:" detected_mysql
  status_line "Node.js:"  detected_node
  status_line "PHP tune:" detected_phptune
  echo ""
  return 0
}

# ── Revert functions ──────────────────────────────────────────────────────
revert_docker() {
  if ! detected_docker; then info "Docker not detected - skipping"; return 0; fi
  section "Reverting Docker"
  stop_units docker.socket docker containerd
  remove_matching purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin docker-ce-rootless-extras docker.io docker
  run_or_echo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
  run_or_echo rm -f /etc/yum.repos.d/docker-ce.repo
  run_or_echo rm -f /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
  if [[ -f /etc/docker/daemon.json ]] && grep -q '"userland-proxy": false' /etc/docker/daemon.json; then
    run_or_echo rm -f /etc/docker/daemon.json
  fi
  run_or_echo rm -f /etc/cron.d/docker-weekly-prune /var/log/docker-prune.log
  if [[ "$PURGE_DATA" -eq 1 ]]; then
    warn "--purge-data: deleting ALL Docker images, containers and volumes"
    run_or_echo rm -rf /var/lib/docker /var/lib/containerd
  else
    info "Docker data kept in /var/lib/docker (pass --purge-data to delete images/volumes)"
  fi
  if applied; then log "Docker removed"; else info "(dry-run) would remove Docker"; fi
  return 0
}

revert_redis() {
  if ! detected_redis; then info "Redis not detected - skipping"; return 0; fi
  section "Reverting Redis"
  stop_units redis-server redis
  remove_matching purge redis-server redis-tools redis redis6 redis7
  if [[ "$PURGE_DATA" -eq 1 ]]; then
    run_or_echo rm -rf /var/lib/redis
  else
    info "Redis data kept in /var/lib/redis (pass --purge-data to delete)"
  fi
  if [[ -f /etc/sysctl.d/99-pulsedeploy-redis.conf ]]; then
    run_or_echo rm -f /etc/sysctl.d/99-pulsedeploy-redis.conf
    run_or_echo sysctl -w vm.overcommit_memory=0
  fi
  if applied; then log "Redis removed"; else info "(dry-run) would remove Redis"; fi
  return 0
}

revert_firewall() {
  local have_ufw=0 have_firewalld=0 have_f2b=0
  if command -v ufw &>/dev/null && [[ "$(ufw status 2>/dev/null | head -n 1)" == "Status: active" ]]; then have_ufw=1; fi
  if command -v firewall-cmd &>/dev/null && svc_active firewalld; then have_firewalld=1; fi
  detected_fail2ban && have_f2b=1
  if [[ "$have_ufw" -eq 0 && "$have_firewalld" -eq 0 && "$have_f2b" -eq 0 ]]; then
    info "No active ufw/firewalld/fail2ban detected - skipping"
    return 0
  fi
  section "Reverting Firewall"
  warn "This disables your firewall entirely. Make sure you have console/serial"
  warn "access as a fallback in case your cloud provider's own firewall isn't set up."
  if ! confirm_typed "Disable the firewall?"; then
    warn "Skipped firewall revert (not confirmed)"
    return 0
  fi
  [[ "$have_ufw" -eq 1 ]] && run_or_echo ufw --force disable
  [[ "$have_firewalld" -eq 1 ]] && run_or_echo systemctl disable --now firewalld
  stop_units fail2ban
  remove_matching purge fail2ban fail2ban-firewalld fail2ban-systemd
  run_or_echo rm -f /etc/fail2ban/jail.d/zz-pulsedeploy.conf
  if [[ -f /etc/fail2ban/jail.local.pulsedeploy.bak ]]; then
    run_or_echo mv /etc/fail2ban/jail.local.pulsedeploy.bak /etc/fail2ban/jail.local
  fi
  if applied; then log "Firewall reverted"; else info "(dry-run) would disable firewall + remove fail2ban"; fi
  return 0
}

revert_certbot() {
  if ! detected_certbot; then info "Certbot not detected - skipping"; return 0; fi
  section "Reverting Certbot"
  stop_units certbot.timer certbot-renew.timer
  if command -v snap &>/dev/null && snap list certbot &>/dev/null; then
    run_or_echo snap remove --purge certbot
  fi
  remove_matching purge certbot python3-certbot-nginx python3-certbot-apache
  [[ -L /usr/local/bin/certbot ]] && run_or_echo rm -f /usr/local/bin/certbot
  run_or_echo rm -f /etc/cron.d/pulsedeploy-certbot /etc/letsencrypt/renewal-hooks/deploy/pulsedeploy-reload.sh
  # Older versions added a line to root's crontab instead
  if crontab -l 2>/dev/null | grep -q 'certbot renew'; then
    if applied; then
      crontab -l 2>/dev/null | grep -v 'certbot renew' | crontab - || true
    else
      echo -e "${YELLOW}  [dry-run]${RESET} remove certbot renew line from root's crontab"
    fi
  fi
  if [[ "$PURGE_CERTS" -eq 1 ]]; then
    warn "Deleting certificates in /etc/letsencrypt - this is irreversible"
    run_or_echo rm -rf /etc/letsencrypt
  else
    info "Certificates left in place - pass --purge-certs to also delete them"
  fi
  if applied; then log "Certbot removed"; else info "(dry-run) would remove Certbot"; fi
  return 0
}

revert_swap() {
  if ! detected_swap; then info "No PulseDeploy-created swap file detected - skipping"; return 0; fi
  section "Reverting Swap"
  if [[ -n "$(swapon --show=NAME --noheadings 2>/dev/null | grep -x '/swapfile' || true)" ]]; then
    run_or_echo swapoff /swapfile
  fi
  if applied; then
    sed -i '\#^/swapfile[[:space:]]#d' /etc/fstab
  else
    echo -e "${YELLOW}  [dry-run]${RESET} remove /swapfile line from /etc/fstab"
  fi
  run_or_echo rm -f /swapfile /etc/sysctl.d/99-swap.conf
  run_or_echo sysctl -w vm.swappiness=60
  run_or_echo sysctl -w vm.vfs_cache_pressure=100
  if applied; then log "Swap removed"; else info "(dry-run) would remove swap"; fi
  return 0
}

revert_phptune() {
  if ! detected_phptune; then info "No PHP tuning detected - skipping"; return 0; fi
  section "Reverting PHP Tuning"
  local f
  for f in /etc/php/*/*/conf.d/99-pulsedeploy.ini /etc/php.d/99-pulsedeploy.ini; do
    [[ -e "$f" ]] && run_or_echo rm -f "$f"
  done
  for f in /etc/php/*/fpm/pool.d/*.pulsedeploy.bak /etc/php-fpm.d/*.pulsedeploy.bak; do
    [[ -e "$f" ]] || continue
    info "Restoring ${f%.pulsedeploy.bak} from backup"
    run_or_echo cp -a "$f" "${f%.pulsedeploy.bak}"
    run_or_echo rm -f "$f"
  done
  local svc
  for svc in $(systemctl list-units --type=service --state=active --no-legend 'php*-fpm.service' 2>/dev/null | awk '{ print $1 }'); do
    run_or_echo systemctl restart "$svc"
  done
  if applied; then log "PHP tuning reverted"; else info "(dry-run) would revert PHP tuning"; fi
  return 0
}

detected_laravel_next() {
  [[ -f /etc/pulsedeploy/pulse.conf || -x /usr/local/bin/pulse || -f /etc/systemd/system/pulse-next@.service ]]
}

# Undo the Laravel + Next.js profile: services, tooling and tuning files.
# Application code, uploads and backups stay unless --purge-data is given.
revert_laravel_next() {
  detected_laravel_next || return 0
  info "Removing the Laravel + Next.js profile"
  local u f
  for u in pulse-scheduler.timer pulse-scheduler.service pulse-queue.service \
           pulse-next@shop.service pulse-next@admin.service; do
    if systemctl cat "$u" &>/dev/null; then run_or_echo systemctl disable --now "$u"; fi
  done
  run_or_echo rm -rf /etc/systemd/system/pulse-next@shop.service.d /etc/systemd/system/pulse-next@admin.service.d
  run_or_echo rm -f /etc/systemd/system/pulse-next@.service /etc/systemd/system/pulse-queue.service \
    /etc/systemd/system/pulse-scheduler.service /etc/systemd/system/pulse-scheduler.timer
  run_or_echo systemctl daemon-reload
  run_or_echo rm -f /usr/local/bin/pulse /etc/sudoers.d/pulsedeploy /etc/cron.d/pulsedeploy-backup \
    /etc/logrotate.d/pulsedeploy /etc/sysctl.d/99-pulsedeploy-app.conf \
    /etc/systemd/journald.conf.d/pulsedeploy.conf
  run_or_echo rm -rf /etc/pulsedeploy /etc/nginx/pulsedeploy
  # crm.sh leftovers: build workspace, the toolkit copy and its command, git helper
  run_or_echo rm -rf /var/lib/pulsedeploy /opt/pulsedeploy
  run_or_echo rm -f /usr/local/bin/pulse-crm /usr/local/lib/pulsedeploy-git-askpass
  for f in /etc/nginx/conf.d/00-pulsedeploy-http.conf /etc/nginx/conf.d/01-pulsedeploy-cloudflare.conf \
           /etc/nginx/conf.d/pulsedeploy-api.conf /etc/nginx/conf.d/pulsedeploy-shop.conf \
           /etc/nginx/conf.d/pulsedeploy-admin.conf /etc/nginx/conf.d/pulsedeploy-redirect.conf \
           /etc/mysql/conf.d/zz-pulsedeploy.cnf /etc/my.cnf.d/zz-pulsedeploy.cnf; do
    [[ -e "$f" ]] && run_or_echo rm -f "$f"
  done
  for f in /etc/php/*/fpm/pool.d/pulse-laravel.conf /etc/php-fpm.d/pulse-laravel.conf \
           /etc/php/*/*/conf.d/99-pulsedeploy.ini /etc/php.d/99-pulsedeploy.ini; do
    [[ -e "$f" ]] && run_or_echo rm -f "$f"
  done
  if [[ "$PURGE_DATA" -eq 1 ]]; then
    warn "--purge-data: deleting the applications, uploads and backups"
    run_or_echo rm -rf /var/www/api /var/www/admin /var/www/shop /var/backups/pulsedeploy
    run_or_echo rm -f /root/pulsedeploy-crm-credentials.txt
  else
    info "Kept: /var/www/{api,admin,shop} (code, .env, uploads), /var/backups/pulsedeploy, the deploy user, automatic security updates"
  fi
  return 0
}

revert_stack() {
  local any=0
  detected_laravel_next && any=1
  detected_nginx  && any=1
  detected_apache && any=1
  detected_php    && any=1
  detected_mysql  && any=1
  detected_node   && any=1
  if [[ "$any" -eq 0 ]]; then info "No stack packages detected - skipping"; return 0; fi

  section "Reverting Stack Packages"
  warn "This removes web server / DB / runtime packages. Site content in"
  warn "/var/www is NOT deleted. Databases are kept unless --purge-data is given."
  warn "ALL installed PHP packages are removed, including ones PulseDeploy did not install."
  if ! confirm_typed "Remove stack packages?"; then
    warn "Skipped stack revert (not confirmed)"
    return 0
  fi

  revert_laravel_next
  if detected_nginx; then
    stop_units nginx
    remove_matching purge nginx 'nginx-*' 'libnginx-mod-*'
    run_or_echo rm -f /etc/nginx/conf.d/pulsedeploy.conf
  fi
  if detected_apache; then
    stop_units apache2 httpd
    remove_matching purge apache2 'apache2-*' 'libapache2-mod-*' httpd 'httpd-*' mod_ssl
    run_or_echo rm -f /etc/httpd/conf.d/pulsedeploy.conf
  fi
  if detected_php; then
    stop_units php-fpm 'php8.1-fpm' 'php8.2-fpm' 'php8.3-fpm' 'php8.4-fpm'
    remove_matching purge 'php*'
  fi
  if detected_mysql; then
    stop_units mysql mysqld mariadb
    # keep → apt remove: database files and config stay on disk
    remove_matching keep 'mysql-server*' 'mariadb-server*' 'mysql-community-server*' 'mariadb*-server'
    if [[ "$PURGE_DATA" -eq 1 ]]; then
      warn "--purge-data: deleting ALL databases in /var/lib/mysql"
      run_or_echo rm -rf /var/lib/mysql
      run_or_echo rm -f /root/.my.cnf
    else
      info "Databases kept in /var/lib/mysql; credentials kept in /root/.my.cnf (pass --purge-data to delete)"
    fi
  fi
  if detected_node; then
    if command -v pm2 &>/dev/null; then
      run_or_echo pm2 unstartup systemd
      run_or_echo pm2 kill
      command -v npm &>/dev/null && run_or_echo npm rm -g pm2
    fi
    remove_matching purge nodejs
    run_or_echo rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/keyrings/nodesource.gpg \
      /etc/yum.repos.d/nodesource-nodejs.repo
  fi
  # RHEL: put the stock nginx.conf back if we edited it
  if [[ -f /etc/nginx/nginx.conf.pulsedeploy.bak ]]; then
    run_or_echo cp -a /etc/nginx/nginx.conf.pulsedeploy.bak /etc/nginx/nginx.conf
  fi
  if applied; then log "Stack packages reverted"; else info "(dry-run) would remove stack packages"; fi
  return 0
}

cleanup_pkgs() {
  section "Cleaning Up"
  case "$PKG_MANAGER" in
    apt)
      run_or_echo apt_get autoremove
      run_or_echo apt-get autoclean -y
      ;;
    dnf) run_or_echo pm_rpm autoremove -y ;;
  esac
  if applied; then log "Package cache cleaned"; else info "(dry-run) would clean unused packages"; fi
  return 0
}

main() {
  parse_args "$@"
  check_root
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/server-revert.log"
  exec > >(tee -a "$LOG_FILE") 2>&1

  echo -e "${BOLD}${CYAN}PulseDeploy revert.sh v${REVERT_VERSION}${RESET}"
  [[ "$PKG_MANAGER" != "unknown" ]] || error "Neither apt nor dnf/yum found - unsupported system."

  show_status
  [[ "$LIST_ONLY" -eq 1 ]] && exit 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN - no changes will be made. Re-run with --yes to actually apply."
  fi

  [[ "${TARGET[docker]}"   -eq 1 ]] && revert_docker
  [[ "${TARGET[redis]}"    -eq 1 ]] && revert_redis
  [[ "${TARGET[certbot]}"  -eq 1 ]] && revert_certbot
  [[ "${TARGET[phptune]}"  -eq 1 ]] && revert_phptune
  [[ "${TARGET[stack]}"    -eq 1 ]] && revert_stack
  [[ "${TARGET[swap]}"     -eq 1 ]] && revert_swap
  [[ "${TARGET[firewall]}" -eq 1 ]] && revert_firewall

  if [[ "$DRY_RUN" -eq 0 ]]; then
    cleanup_pkgs
    section "Revert Complete"
    log "Log saved to: $LOG_FILE"
  else
    echo ""
    info "This was a dry run. Nothing was changed. Add --yes to apply."
  fi
  return 0
}

main "$@"
