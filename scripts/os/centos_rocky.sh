#!/usr/bin/env bash
# OS Module: CentOS Stream / Rocky Linux / AlmaLinux / RHEL 8 & 9
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
PKG_MANAGER="dnf"

os_update() {
  retry 3 10 pm_rpm update -y -q
  log "System packages updated ($OS_ID $OS_VERSION)"
  return 0
}

os_install_base() {
  # EPEL first: some packages below (htop) only exist there.
  retry 3 5 pm_rpm install -y -q epel-release || warn "epel-release unavailable - some optional packages will be skipped"

  local pkgs=(wget git unzip zip ca-certificates gnupg2 net-tools logrotate cronie tar gzip)
  command -v curl &>/dev/null || pkgs+=(curl)
  retry 3 5 pm_rpm install -y -q "${pkgs[@]}"
  pkg_install_optional htop
  systemctl enable --now crond || warn "Could not start crond - cron jobs will not run."
  log "Base dependencies installed"
  return 0
}

# Remi repository for the requested PHP version on RHEL-family systems.
os_get_php_repo() {
  local major="${OS_VERSION%%.*}"
  pm_rpm install -y -q dnf-plugins-core || true
  pm_rpm config-manager --set-enabled crb 2>/dev/null ||
    pm_rpm config-manager --set-enabled powertools 2>/dev/null || true
  if retry 2 5 pm_rpm install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${major}.rpm"; then
    pm_rpm module reset php -y || true
    pm_rpm module enable "php:remi-${PHP_VER:-8.2}" -y ||
      warn "Remi has no php:remi-${PHP_VER:-8.2} module - using the distribution default PHP."
  else
    warn "Remi repo install failed - PHP will come from the distribution's default repos."
  fi
  return 0
}

os_pkg_install() { retry 3 5 pm_rpm install -y -q "$@"; }

os_firewall_cmd() {
  # Translate ufw-style calls to firewalld
  case "$1" in
    allow)
      local spec="$2"
      [[ "$spec" =~ ^[0-9]+$ ]] && spec="$spec/tcp"
      if [[ "$spec" =~ ^[0-9]+/(tcp|udp)$ ]]; then
        firewall-cmd --permanent --add-port="$spec"
      else
        firewall-cmd --permanent --add-service="$2"
      fi
      ;;
    enable) systemctl enable --now firewalld ;;
    reload) firewall-cmd --reload ;;
    *)      firewall-cmd "$@" ;;
  esac
}

# SELinux awareness - returns 0 when Enforcing
selinux_enforcing() {
  command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]
}

check_selinux() {
  if selinux_enforcing; then
    warn "SELinux is Enforcing. Nginx/Apache may need boolean adjustments."
    info "Run: setsebool -P httpd_can_network_connect 1"
    info "Run: setsebool -P httpd_execmem 1"
  fi
  return 0
}
