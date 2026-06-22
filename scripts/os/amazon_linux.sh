#!/usr/bin/env bash
# OS Module: Amazon Linux 2 / Amazon Linux 2023

os_update() {
  dnf update -y -q
  log "System packages updated (Amazon Linux $OS_VERSION)"
}

os_install_base() {
  dnf install -y -q \
    curl wget git unzip zip \
    ca-certificates gnupg2 \
    htop net-tools firewalld \
    logrotate cronie tar gzip

  # Amazon Linux 2023 uses firewalld; AL2 can use iptables
  systemctl enable --now firewalld 2>/dev/null || true
  log "Base dependencies installed"
}

os_get_php_repo() {
  if [[ "$OS_VERSION" == "2" ]]; then
    amazon-linux-extras enable php8.2 2>/dev/null || true
  else
    # AL2023 has PHP 8.x in default repos
    dnf module enable php:8.2 -y 2>/dev/null || true
  fi
}

os_get_mysql_repo() {
  dnf install -y -q \
    https://dev.mysql.com/get/mysql80-community-release-el9-5.noarch.rpm \
    2>/dev/null || \
  dnf install -y -q mariadb105-server  # fallback for AL2
}

os_pkg_install()  { dnf install -y -q "$@"; }
os_svc_enable()   { systemctl enable "$1" && systemctl start "$1"; }

os_firewall_cmd() {
  # Translate ufw-style calls to firewalld
  case "$1" in
    allow)   firewall-cmd --permanent --add-service="$2" 2>/dev/null || \
             firewall-cmd --permanent --add-port="$2/tcp" ;;
    enable)  systemctl enable --now firewalld ;;
    reload)  firewall-cmd --reload ;;
    *)       firewall-cmd "$@" ;;
  esac
}

# AWS-specific: detect if instance has IMDSv2 available
is_aws_instance() {
  TOKEN=$(curl -s -m 2 -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 10" 2>/dev/null) || return 1
  curl -s -m 2 \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/instance-id" &>/dev/null
}

aws_open_sg_hint() {
  if is_aws_instance; then
    warn "AWS detected: Ensure your Security Group allows ports 80/443 (HTTP/HTTPS) and 22 (SSH)."
    warn "UFW/firewalld rules apply at the OS level — AWS Security Groups are separate."
  fi
}