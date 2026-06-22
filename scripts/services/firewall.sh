#!/usr/bin/env bash
# Service: UFW / firewalld + fail2ban

setup_firewall() {
  section "Configuring Firewall & fail2ban"

  # ── UFW (Debian/Ubuntu) ───────────────────────────────────────────────────
  if command -v ufw &>/dev/null; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp

    # Ask about custom ports
    read -rp "$(echo -e "${CYAN}Open any additional ports? (e.g. 8080,3306) or press Enter to skip:${RESET} ")" EXTRA_PORTS
    if [[ -n "$EXTRA_PORTS" ]]; then
      IFS=',' read -ra PORTS <<< "$EXTRA_PORTS"
      for port in "${PORTS[@]}"; do
        ufw allow "${port// /}/tcp"
        log "Opened port $port"
      done
    fi

    ufw --force enable
    ufw status verbose
    log "UFW configured: SSH + HTTP + HTTPS allowed"

  # ── firewalld (RHEL/Amazon Linux) ─────────────────────────────────────────
  elif command -v firewall-cmd &>/dev/null; then
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
    firewall-cmd --list-all
    log "firewalld configured: SSH + HTTP + HTTPS allowed"

    # AWS hint
    declare -f aws_open_sg_hint &>/dev/null && aws_open_sg_hint
  fi

  # ── fail2ban ───────────────────────────────────────────────────────────────
  info "Installing fail2ban..."
  os_pkg_install fail2ban

  cat > /etc/fail2ban/jail.local <<'F2B'
[DEFAULT]
bantime   = 3600
findtime  = 600
maxretry  = 5
backend   = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 86400

[nginx-http-auth]
enabled = true

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log

[apache-auth]
enabled = true

[apache-badbots]
enabled  = true
port     = http,https
logpath  = /var/log/apache*/*error.log /var/log/httpd/*error.log
F2B

  os_svc_enable fail2ban
  log "fail2ban installed and configured (SSH: 3 retries → 24h ban)"
}