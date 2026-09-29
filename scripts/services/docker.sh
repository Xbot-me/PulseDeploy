#!/usr/bin/env bash
# Service: Docker & Docker Compose v2
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Write /etc/docker/daemon.json only if the admin has not got one already.
_docker_write_daemon_json() {
  mkdir -p /etc/docker
  if [[ -f /etc/docker/daemon.json ]]; then
    info "Existing /etc/docker/daemon.json kept unchanged"
    return 1
  fi
  cat >/etc/docker/daemon.json <<'DAEMON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "userland-proxy": false
}
DAEMON
  return 0
}

_docker_install_engine() {
  info "Adding Docker repository..."
  local codename tmp
  case "$OS_ID" in
    ubuntu|debian)
      # Remove distro-packaged alternatives that conflict with docker-ce.
      local -a old=() pkg
      for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        pkg_installed "$pkg" && old+=("$pkg")
      done
      if ((${#old[@]})); then apt_get remove "${old[@]}"; fi

      install -m 0755 -d /etc/apt/keyrings
      tmp="$(mktemp)"
      download "https://download.docker.com/linux/${OS_ID}/gpg" "$tmp"
      gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg <"$tmp"
      rm -f "$tmp"
      chmod a+r /etc/apt/keyrings/docker.gpg
      codename="$(os_release_value UBUNTU_CODENAME)"
      [[ -n "$codename" ]] || codename="$(os_release_value VERSION_CODENAME)"
      [[ -n "$codename" ]] || error "Cannot determine the release codename for the Docker repository."
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${codename} stable" \
        >/etc/apt/sources.list.d/docker.list
      retry 3 10 apt_get update
      os_pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    amzn)
      os_pkg_install docker
      _docker_install_compose_plugin
      ;;
    centos|rocky|rhel|almalinux)
      os_pkg_install dnf-plugins-core
      pm_rpm config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      os_pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    *) error "Docker installation is not supported on $OS_ID." ;;
  esac
  return 0
}

# Amazon Linux has no docker-compose-plugin package: fetch the official
# release binary as a CLI plugin and verify its published checksum.
_docker_install_compose_plugin() {
  local arch dest_dir="/usr/local/lib/docker/cli-plugins" base bin sums
  arch="$(uname -m)"
  base="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
  bin="$(mktemp)"; sums="$(mktemp)"
  download "$base" "$bin"
  download "${base}.sha256" "$sums"
  local want got
  want="$(awk '{ print $1; exit }' "$sums")"
  got="$(sha256sum "$bin" | awk '{ print $1 }')"
  [[ -n "$want" && "$want" == "$got" ]] || error "Docker Compose checksum mismatch - refusing to install."
  mkdir -p "$dest_dir"
  install -m 0755 "$bin" "$dest_dir/docker-compose"
  rm -f "$bin" "$sums"
  log "Docker Compose plugin installed to $dest_dir"
  return 0
}

install_docker() {
  section "Installing Docker & Docker Compose"

  local fresh=0 wrote_config=0
  if command -v docker &>/dev/null; then
    info "Docker already installed: $(docker --version)"
    _docker_write_daemon_json && wrote_config=1
  else
    fresh=1
    _docker_write_daemon_json || true # written BEFORE first start so it applies
    _docker_install_engine
  fi

  os_svc_enable docker
  if [[ "$fresh" -eq 0 && "$wrote_config" -eq 1 ]]; then
    systemctl reload docker 2>/dev/null || true
    info "daemon.json written; run 'systemctl restart docker' at a quiet moment to apply log rotation."
  fi

  # ── Verify the daemon really works ─────────────────────────────────────────
  local i ok=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker info &>/dev/null; then ok=1; break; fi
    sleep 2
  done
  [[ "$ok" -eq 1 ]] || error "Docker daemon is not responding. Check: systemctl status docker"
  log "Docker running: $(docker --version)"
  if docker compose version &>/dev/null; then
    log "Docker Compose: $(docker compose version)"
  else
    warn "Docker Compose v2 plugin not found (docker compose)."
  fi

  # ── Let the invoking sudo user run docker ──────────────────────────────────
  local user="${SUDO_USER:-}"
  if [[ -n "$user" && "$user" != "root" ]] && id "$user" &>/dev/null; then
    usermod -aG docker "$user"
    log "Added $user to docker group (re-login required)"
  fi

  # ── Weekly cleanup: unused items older than 7 days, never volumes ──────────
  cat >/etc/cron.d/docker-weekly-prune <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * 0 root docker system prune -f --filter "until=168h" >> /var/log/docker-prune.log 2>&1
CRON
  chmod 644 /etc/cron.d/docker-weekly-prune
  log "Weekly Docker cleanup cron installed (Sundays 3am; volumes are never pruned)"
  return 0
}
