#!/usr/bin/env bash
# OS Module: Debian 11 (Bullseye) / 12 (Bookworm)

os_update() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  log "System packages updated (Debian $OS_VERSION)"
}

os_install_base() {
  apt-get install -y -qq \
    curl wget git unzip zip \
    ca-certificates gnupg lsb-release \
    software-properties-common apt-transport-https \
    htop net-tools ufw build-essential \
    logrotate cron
  log "Base dependencies installed"
}

os_get_php_repo() {
  curl -sSLo /tmp/debsuryorg-archive-keyring.deb \
    https://packages.sury.org/php/debsuryorg-archive-keyring.deb
  dpkg -i /tmp/debsuryorg-archive-keyring.deb
  echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] \
    https://packages.sury.org/php/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/php.list
  apt-get update -qq
}

os_get_mysql_repo() {
  local DEB_PKG="mysql-apt-config_0.8.29-1_all.deb"
  wget -qO "/tmp/$DEB_PKG" "https://dev.mysql.com/get/$DEB_PKG"
  DEBIAN_FRONTEND=noninteractive dpkg -i "/tmp/$DEB_PKG"
  apt-get update -qq
}

os_pkg_install()  { apt-get install -y -qq "$@"; }
os_svc_enable()   { systemctl enable "$1" && systemctl start "$1"; }
os_firewall_cmd() { ufw "$@"; }