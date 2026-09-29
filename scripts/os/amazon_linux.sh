#!/usr/bin/env bash
# OS Module: Amazon Linux 2 (EOL, best effort) / Amazon Linux 2023
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
PKG_MANAGER="dnf"

os_update() {
  retry 3 10 pm_rpm update -y -q
  log "System packages updated (Amazon Linux $OS_VERSION)"
  return 0
}

os_install_base() {
  local pkgs=(wget git unzip zip ca-certificates gnupg2 net-tools logrotate cronie tar gzip)
  # AL2023 ships curl-minimal, which conflicts with the full curl package.
  command -v curl &>/dev/null || pkgs+=(curl)
  retry 3 5 pm_rpm install -y -q "${pkgs[@]}"
  pkg_install_optional htop
  systemctl enable --now crond || warn "Could not start crond — cron jobs will not run."
  log "Base dependencies installed"
  return 0
}

os_get_php_repo() {
  if [[ "$OS_VERSION" == "2" ]]; then
    amazon-linux-extras enable "php${PHP_VER:-8.2}" || warn "amazon-linux-extras has no php${PHP_VER:-8.2}"
  fi
  # AL2023 ships versioned packages (php8.2-fpm, …) in the default repos.
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

# AWS-specific: detect an EC2 instance through IMDSv2
is_aws_instance() {
  local token
  token="$(curl -s -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 10" 2>/dev/null)" || return 1
  curl -s -m 2 -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/instance-id" &>/dev/null
}

aws_open_sg_hint() {
  if is_aws_instance; then
    warn "AWS detected: ensure your Security Group allows ports 80/443 (HTTP/HTTPS) and your SSH port."
    warn "OS firewall rules apply on the instance only — AWS Security Groups are separate."
  fi
  return 0
}
