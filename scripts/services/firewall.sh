#!/usr/bin/env bash
# Service: UFW / firewalld + fail2ban
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Validate the comma-separated OPEN_PORTS list into the array named by $1.
_parse_open_ports() {
  local -n _out="$1"
  local raw="${OPEN_PORTS:-}" p
  _out=()
  [[ -z "$raw" ]] && return 0
  local -a items
  IFS=',' read -ra items <<<"$raw"
  for p in "${items[@]}"; do
    p="${p// /}"
    [[ -z "$p" ]] && continue
    if valid_port "$p"; then _out+=("$p"); else warn "Ignoring invalid port '$p'"; fi
  done
  return 0
}

setup_firewall() {
  section "Configuring Firewall & fail2ban"

  # shellcheck disable=SC2034  # extra is filled through a nameref
  local -a ssh_list extra=()
  mapfile -t ssh_list < <(ssh_ports)
  _parse_open_ports extra
  info "SSH port(s) that will stay reachable: ${ssh_list[*]}"

  case "$PKG_MANAGER" in
    apt) _firewall_ufw ssh_list extra ;;
    dnf) _firewall_firewalld ssh_list extra ;;
  esac

  _setup_fail2ban "${ssh_list[*]}"
  return 0
}

_firewall_ufw() {
  local -n _ssh="$1" _extra="$2"
  local p
  pkg_installed ufw || os_pkg_install ufw

  # Additive: existing custom rules are kept (no `ufw reset`).
  ufw default deny incoming
  ufw default allow outgoing
  # Allow SSH BEFORE enabling, or the running session gets cut off.
  for p in "${_ssh[@]}"; do ufw allow "${p}/tcp"; done
  ufw allow 80/tcp
  ufw allow 443/tcp
  for p in "${_extra[@]}"; do
    ufw allow "${p}/tcp"
    log "Opened port $p"
  done
  ufw --force enable
  ufw status verbose
  log "UFW active: SSH (${_ssh[*]}) + HTTP + HTTPS allowed"
  return 0
}

_firewall_firewalld() {
  local -n _ssh="$1" _extra="$2"
  local p
  pkg_installed firewalld || os_pkg_install firewalld
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=ssh
  for p in "${_ssh[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp"; done
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  for p in "${_extra[@]}"; do
    firewall-cmd --permanent --add-port="${p}/tcp"
    log "Opened port $p"
  done
  firewall-cmd --reload
  firewall-cmd --list-all
  log "firewalld active: SSH (${_ssh[*]}) + HTTP + HTTPS allowed"
  if declare -f aws_open_sg_hint &>/dev/null; then aws_open_sg_hint; fi
  return 0
}

_setup_fail2ban() {
  local ssh_port_csv="${1// /,}"
  info "Installing fail2ban..."
  pkg_install_required fail2ban
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    pkg_install_optional python3-systemd
  else
    pkg_install_optional fail2ban-firewalld fail2ban-systemd
  fi

  # sshd log source. The distribution default for the sshd jail is usually the
  # systemd journal; if fail2ban's own Python cannot load that binding, the jail
  # (and with it the whole service) would fail to start — so fall back to a
  # plain log file and make sure one exists.
  local f2b_py ssh_backend="" ssh_logpath="" logf
  f2b_py="$(head -n 1 "$(command -v fail2ban-server)" 2>/dev/null | sed 's/^#! *//; s/ .*//')" || f2b_py=""
  [[ -x "$f2b_py" ]] || f2b_py="python3"
  if "$f2b_py" -c 'import systemd.journal' &>/dev/null; then
    ssh_backend="backend  = systemd"
  else
    logf="/var/log/auth.log"
    [[ "$PKG_MANAGER" == "dnf" ]] && logf="/var/log/secure"
    if [[ ! -e "$logf" && "$PKG_MANAGER" == "apt" ]]; then
      pkg_install_optional rsyslog
      systemctl enable --now rsyslog &>/dev/null || true
      logger -p auth.info "PulseDeploy: initialising auth log" 2>/dev/null || true
      sleep 1
    fi
    if [[ ! -e "$logf" ]]; then
      # Empty file is enough for fail2ban to start; rsyslog appends to it later.
      if id syslog &>/dev/null; then install -m 640 -o syslog -g adm /dev/null "$logf"
      else install -m 640 /dev/null "$logf"; fi
      warn "No SSH log existed; created empty $logf (install rsyslog or python3-systemd for full SSH protection)."
    fi
    ssh_backend="backend  = auto"
    ssh_logpath="logpath  = $logf"
  fi

  local jail="/etc/fail2ban/jail.d/zz-pulsedeploy.conf"
  mkdir -p /etc/fail2ban/jail.d
  # Retire the file old versions of PulseDeploy wrote (enabled jails whose log
  # files might not exist, which crashes fail2ban).
  if [[ -f /etc/fail2ban/jail.local ]] && grep -q 'nginx-limit-req' /etc/fail2ban/jail.local &&
     grep -q 'apache-badbots' /etc/fail2ban/jail.local; then
    mv /etc/fail2ban/jail.local /etc/fail2ban/jail.local.pulsedeploy.bak
    info "Moved legacy PulseDeploy jail.local to jail.local.pulsedeploy.bak"
  fi

  {
    cat <<F2B
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ${ssh_port_csv}
maxretry = 3
bantime  = 86400
${ssh_backend}
${ssh_logpath}
F2B
    # Web jails only when the server and its log actually exist.
    if command -v nginx &>/dev/null && [[ -e /var/log/nginx/error.log ]]; then
      printf '\n[nginx-http-auth]\nenabled = true\nbackend = auto\n'
      printf '\n[nginx-limit-req]\nenabled = true\nbackend = auto\n'
    fi
    if compgen -G '/var/log/apache2/*error.log' >/dev/null || compgen -G '/var/log/httpd/*error_log' >/dev/null; then
      printf '\n[apache-auth]\nenabled = true\nbackend = auto\n'
    fi
  } >"$jail"

  if ! fail2ban-client -t &>/dev/null; then
    warn "fail2ban rejected the extended jail set — retrying with SSH protection only"
    printf '[sshd]\nenabled  = true\nport     = %s\nmaxretry = 3\nbantime  = 86400\n%s\n%s\n' \
      "$ssh_port_csv" "$ssh_backend" "$ssh_logpath" >"$jail"
  fi
  if ! fail2ban-client -t &>/dev/null; then
    rm -f "$jail"
    warn "fail2ban configuration test still failing — leaving fail2ban with distribution defaults."
    fail2ban-client -t 2>&1 | tail -n 5 >&2 || true
  fi

  if ! svc_restart fail2ban; then
    warn "fail2ban would not start with PulseDeploy's jails — retrying with the distribution defaults"
    rm -f "$jail"
    svc_restart fail2ban || error "fail2ban does not start even with default settings; see the status output above."
    warn "fail2ban is running with distribution defaults only (PulseDeploy jails removed)."
    return 0
  fi
  log "fail2ban active (SSH: 3 retries → 24h ban)"
  return 0
}
