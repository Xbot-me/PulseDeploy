#!/usr/bin/env bash
# OS Module: Debian 11 (Bullseye) / 12 (Bookworm) / 13 (Trixie)
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
PKG_MANAGER="apt"

os_update() {
  retry 3 10 apt_get update
  apt_get upgrade
  log "System packages updated (Debian $OS_VERSION)"
  return 0
}

os_install_base() {
  # software-properties-common was removed from Debian 13 (Trixie) and nothing
  # here calls add-apt-repository, so it is only installed on Debian 11/12.
  local base_pkgs=(
    curl wget git unzip zip
    ca-certificates gnupg lsb-release
    apt-transport-https
    htop net-tools build-essential
    logrotate cron
  )
  local major="${OS_VERSION%%.*}"
  if [[ "$major" =~ ^[0-9]+$ && "$major" -lt 13 ]]; then
    base_pkgs+=(software-properties-common)
  else
    info "Skipping software-properties-common (unavailable on Debian $OS_VERSION / Trixie+)"
  fi
  retry 3 5 apt_get install "${base_pkgs[@]}"
  log "Base dependencies installed"
  return 0
}

# Sury PHP repository - only needed when Debian's archive lacks the version.
os_get_php_repo() {
  local codename tmp key="/usr/share/keyrings/deb.sury.org-php.gpg"
  codename="$(os_release_value VERSION_CODENAME)"
  [[ -n "$codename" ]] || error "Cannot determine the Debian codename for the Sury repository."
  tmp="$(mktemp)"

  # The official keyring .deb installs $key; fall back to the raw signing key.
  if download "https://packages.sury.org/debsuryorg-archive-keyring.deb" "$tmp" 2>/dev/null ||
     download "https://packages.sury.org/php/debsuryorg-archive-keyring.deb" "$tmp" 2>/dev/null; then
    dpkg -i "$tmp"
  else
    download "https://packages.sury.org/php/apt.gpg" "$tmp"
    gpg --dearmor --yes -o "$key" <"$tmp"
  fi
  rm -f "$tmp"
  [[ -s "$key" ]] || error "Sury signing key was not installed at $key."

  echo "deb [signed-by=$key] https://packages.sury.org/php/ $codename main" \
    >/etc/apt/sources.list.d/php.list
  retry 3 10 apt_get update
}

os_pkg_install()  { retry 3 5 apt_get install "$@"; }
os_firewall_cmd() { ufw "$@"; }
