#!/usr/bin/env bash
# Service: Redis

install_redis() {
  section "Installing Redis"

  case "$PKG_MANAGER" in
    apt) os_pkg_install redis-server ;;
    dnf) os_pkg_install redis ;;
  esac

  # ── Config tuning ──────────────────────────────────────────────────────────
  local REDIS_CONF
  REDIS_CONF=$(find /etc/redis* -name "*.conf" 2>/dev/null | head -1)
  REDIS_CONF="${REDIS_CONF:-/etc/redis/redis.conf}"

  if [[ -f "$REDIS_CONF" ]]; then
    # Detect available RAM for maxmemory suggestion
    local RAM_MB
    RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    local REDIS_MEM=$(( RAM_MB / 4 ))  # use ~25% of RAM
    [[ $REDIS_MEM -lt 64 ]] && REDIS_MEM=64

    # Ask for connection type
    echo -e "\nRedis connection method:"
    echo "  1) Unix socket (recommended for same-server apps)"
    echo "  2) TCP localhost:6379"
    read -rp "$(echo -e "${CYAN}Choose [1-2, default 1]:${RESET} ")" REDIS_CONN
    REDIS_CONN="${REDIS_CONN:-1}"

    cp "$REDIS_CONF" "${REDIS_CONF}.bak"

    if [[ "$REDIS_CONN" == "1" ]]; then
      sed -i 's|^# *unixsocket .*|unixsocket /var/run/redis/redis.sock|' "$REDIS_CONF"
      sed -i 's|^# *unixsocketperm .*|unixsocketperm 777|' "$REDIS_CONF"
      sed -i 's|^bind .*|bind 127.0.0.1|' "$REDIS_CONF"
      log "Redis: Unix socket at /var/run/redis/redis.sock"
    else
      sed -i 's|^bind .*|bind 127.0.0.1|' "$REDIS_CONF"
      log "Redis: TCP localhost:6379"
    fi

    # Memory & policy
    sed -i "s|^# *maxmemory .*\|^maxmemory .*|maxmemory ${REDIS_MEM}mb|" "$REDIS_CONF"
    sed -i "s|^# *maxmemory-policy .*\|^maxmemory-policy .*|maxmemory-policy allkeys-lru|" "$REDIS_CONF"

    # Persistence: disable AOF for cache-only use
    sed -i 's|^appendonly yes|appendonly no|' "$REDIS_CONF"

    log "Redis maxmemory set to ${REDIS_MEM}mb with allkeys-lru policy"
  fi

  local REDIS_SVC="redis-server"
  command -v redis-server &>/dev/null || REDIS_SVC="redis"
  os_svc_enable "$REDIS_SVC"

  # Test
  if redis-cli ping 2>/dev/null | grep -q "PONG"; then
    log "Redis is running and responding to PING ✔"
  else
    warn "Redis installed but not responding. Check: systemctl status $REDIS_SVC"
  fi
}