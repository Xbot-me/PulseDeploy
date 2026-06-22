#!/usr/bin/env bash
# Service: Docker & Docker Compose v2

install_docker() {
  section "Installing Docker & Docker Compose"

  # ── Remove old versions ────────────────────────────────────────────────────
  case "$PKG_MANAGER" in
    apt)
      for pkg in docker docker-engine docker.io containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
      done
      ;;
    dnf)
      dnf remove -y docker docker-client docker-client-latest \
        docker-common docker-latest docker-engine 2>/dev/null || true
      ;;
  esac

  # ── Install Docker Engine ──────────────────────────────────────────────────
  info "Adding Docker repository..."
  case "$OS_ID" in
    ubuntu|debian)
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${OS_ID} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      os_pkg_install docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      ;;
    amzn)
      dnf install -y docker
      # Compose plugin via pip on Amazon Linux
      pip3 install docker-compose 2>/dev/null || \
        curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
          -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose
      ;;
    centos|rocky|rhel|almalinux)
      dnf install -y yum-utils
      dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo
      dnf install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      ;;
  esac

  # ── Enable & start ────────────────────────────────────────────────────────
  os_svc_enable docker

  # ── Add current user to docker group ──────────────────────────────────────
  SUDO_USER_NAME="${SUDO_USER:-}"
  if [[ -n "$SUDO_USER_NAME" && "$SUDO_USER_NAME" != "root" ]]; then
    usermod -aG docker "$SUDO_USER_NAME"
    log "Added $SUDO_USER_NAME to docker group (re-login required)"
  fi

  # ── Verify ────────────────────────────────────────────────────────────────
  docker --version && log "Docker installed: $(docker --version)"
  docker compose version 2>/dev/null && log "Docker Compose: $(docker compose version)"

  # ── Docker daemon tuning ──────────────────────────────────────────────────
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<DAEMON
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

  systemctl reload docker 2>/dev/null || systemctl restart docker
  log "Docker daemon configured (log rotation + live-restore)"

  # ── Docker cleanup cron ───────────────────────────────────────────────────
  echo "0 3 * * 0 root docker system prune -f --volumes >> /var/log/docker-prune.log 2>&1" \
    > /etc/cron.d/docker-weekly-prune
  log "Weekly Docker cleanup cron installed (Sundays 3am)"
}