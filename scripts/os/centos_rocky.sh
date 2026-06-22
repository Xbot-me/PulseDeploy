#!/usr/bin/env bash
# OS Module: CentOS 7/8 / Rocky Linux 8/9 / AlmaLinux 8/9

os_update() {
  dnf update -y -q 2>/dev/null || yum update -y -q
  log "System packages updated ($OS_ID $OS_VERSION)"
}

os_install_base() {
  dnf install -y -q \
    curl wget git unzip zip \
    ca-certificates gnupg2 \
    htop net-tools firewalld \
    logrotate cronie tar gzip \
    epel-release 2>/dev/null || true

  dnf update -y -q
  systemctl enable --now firewalld
  log "Base dependencies installed"
}

os_get_php_repo() {
  # Remi repo for modern PHP on RHEL-based systems
  dnf install -y -q \
    "https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION%%.*}.rpm" \
    2>/dev/null || warn "Remi repo install failed — PHP may use default version"
  dnf module reset php -y 2>/dev/null || true
  dnf module enable php:remi-8.2 -y 2>/dev/null || true
}

os_get_mysql_repo() {
  local RPM="mysql80-community-release-el${OS_VERSION%%.*}-5.noarch.rpm"
  dnf install -y -q "https://dev.mysql.com/get/$RPM" 2>/dev/null || true
  dnf install -y -q mysql-community-server
}

os_pkg_install()  { dnf install -y -q "$@"; }
os_svc_enable()   { systemctl enable "$1" && systemctl start "$1"; }

os_firewall_cmd() {
  case "$1" in
    allow)   firewall-cmd --permanent --add-service="$2" 2>/dev/null || \
             firewall-cmd --permanent --add-port="$2/tcp" ;;
    enable)  systemctl enable --now firewalld ;;
    reload)  firewall-cmd --reload ;;
    *)       firewall-cmd "$@" ;;
  esac
}

# SELinux awareness
check_selinux() {
  if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
    warn "SELinux is Enforcing. Nginx/Apache may need boolean adjustments."
    info "Run: setsebool -P httpd_can_network_connect 1"
    info "Run: setsebool -P httpd_execmem 1"
  fi
}