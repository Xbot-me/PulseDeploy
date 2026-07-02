#!/usr/bin/env bash
# OS Module: Debian 11 (Bullseye) / 12 (Bookworm) / 13 (Trixie)

os_update() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  log "System packages updated (Debian $OS_VERSION)"
  return 0
}

os_install_base() {
  # software-properties-common (add-apt-repository) was removed from Debian
  # Trixie (13) and has no replacement package — see
  # https://tracker.debian.org/news/1579223/software-properties-removed-from-testing/
  # Nothing else in PulseDeploy calls add-apt-repository (PHP/MySQL repos are
  # added manually via curl+dpkg keyring), so it's only installed on Debian
  # 11/12 where it's still available, and skipped on 13+.
  local base_pkgs=(
    curl wget git unzip zip
    ca-certificates gnupg lsb-release
    apt-transport-https
    htop net-tools ufw build-essential
    logrotate cron
  )

  local major="${OS_VERSION%%.*}"
  if [[ "$major" =~ ^[0-9]+$ && "$major" -lt 13 ]]; then
    base_pkgs+=(software-properties-common)
  else
    info "Skipping software-properties-common (unavailable on Debian $OS_VERSION / Trixie+)"
  fi

  apt-get install -y -qq "${base_pkgs[@]}"
  log "Base dependencies installed"
  return 0
}

os_get_php_repo() {
  curl -sSLo /tmp/debsuryorg-archive-keyring.deb \
    https://packages.sury.org/php/debsuryorg-archive-keyring.deb
  dpkg -i /tmp/debsuryorg-archive-keyring.deb
  echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] \
    https://packages.sury.org/php/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/php.list
  apt-get update -qq
  return 0
}

os_get_mysql_repo() {
  local DEB_PKG="mysql-apt-config_0.8.29-1_all.deb"
  wget -qO "/tmp/$DEB_PKG" "https://dev.mysql.com/get/$DEB_PKG"
  DEBIAN_FRONTEND=noninteractive dpkg -i "/tmp/$DEB_PKG"
  apt-get update -qq
  return 0
}

os_pkg_install()  { apt-get install -y -qq "$@"; }
os_svc_enable()   { systemctl enable "$1" && systemctl start "$1"; }
os_firewall_cmd() { ufw "$@"; }