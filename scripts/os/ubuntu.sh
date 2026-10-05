#!/usr/bin/env bash
# OS Module: Ubuntu 20.04 / 22.04 / 24.04
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
PKG_MANAGER="apt"

os_update() {
  retry 3 10 apt_get update
  apt_get upgrade
  log "System packages updated (Ubuntu $OS_VERSION)"
  return 0
}

os_install_base() {
  retry 3 5 apt_get install \
    curl wget git unzip zip jq \
    ca-certificates gnupg lsb-release \
    software-properties-common apt-transport-https \
    htop net-tools build-essential \
    logrotate cron
  log "Base dependencies installed"
  return 0
}

# Ondřej Surý's PPA - only needed when Ubuntu's own archive lacks the version.
os_get_php_repo() {
  add-apt-repository -y ppa:ondrej/php
  retry 3 10 apt_get update
}

os_pkg_install()  { retry 3 5 apt_get install "$@"; }
os_firewall_cmd() { ufw "$@"; }
