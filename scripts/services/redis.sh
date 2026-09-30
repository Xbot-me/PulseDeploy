#!/usr/bin/env bash
# Service: Redis
# shellcheck source=scripts/lib/web.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/web.sh"

# _redis_ping <socket|tcp> <socket-path> - retries for ~10 s
# The client is named after the package on Amazon Linux (redis6-cli, redis7-cli).
_redis_cli_bin() {
  local b
  for b in redis-cli redis6-cli redis7-cli; do
    if command -v "$b" &>/dev/null; then printf '%s' "$b"; return 0; fi
  done
  return 1
}

_redis_ping() {
  local mode="$1" sock="$2" i reply="" cli=""
  cli="$(_redis_cli_bin)" || error "No redis client (redis-cli) found to verify the server."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ "$mode" == "socket" ]]; then
      reply="$("$cli" -s "$sock" ping 2>/dev/null || true)"
    else
      reply="$("$cli" ping 2>/dev/null || true)"
    fi
    [[ "$reply" == "PONG" ]] && return 0
    sleep 1
  done
  return 1
}

install_redis() {
  section "Installing Redis"

  case "$PKG_MANAGER" in
    apt) os_pkg_install redis-server ;;
    dnf) pkg_install_first redis redis6 redis7 || error "No Redis package found in the enabled repositories." ;;
  esac

  # ── Locate the main config (never sentinel.conf) ───────────────────────────
  local conf="" c
  for c in /etc/redis/redis.conf /etc/redis.conf /etc/redis/redis-server.conf \
           /etc/redis6/redis6.conf /etc/redis7/redis7.conf; do
    [[ -f "$c" ]] && { conf="$c"; break; }
  done
  [[ -n "$conf" ]] || error "Redis config file not found after installation."
  backup_file "$conf"

  local ram_mb redis_mem sock="/run/redis/redis.sock" conn="${REDIS_CONN:-socket}"
  ram_mb="$(total_ram_mb)"
  redis_mem="${REDIS_MAXMEM_MB:-$((ram_mb / 4))}" # default ~25% of RAM
  ((redis_mem < 64)) && redis_mem=64

  # ── Security: loopback only ────────────────────────────────────────────────
  conf_set "$conf" bind "127.0.0.1"
  conf_set "$conf" protected-mode "yes"

  if [[ "$conn" == "socket" ]]; then
    conf_set "$conf" unixsocket "$sock"
    conf_set "$conf" unixsocketperm "770"
    # Give web-server users access through the redis group (not world-writable).
    local u
    for u in www-data nginx apache; do
      if id "$u" &>/dev/null; then usermod -aG redis "$u" && info "Added $u to the redis group"; fi
    done
    log "Redis: Unix socket at $sock (mode 770, group redis)"
  else
    log "Redis: TCP 127.0.0.1:6379"
  fi

  # ── Memory & persistence ───────────────────────────────────────────────────
  conf_set "$conf" maxmemory "${redis_mem}mb"
  conf_set "$conf" maxmemory-policy "allkeys-lru"
  conf_set "$conf" appendonly "no"
  log "Redis maxmemory ${redis_mem}mb, policy allkeys-lru"

  local svc
  svc="$(svc_first_existing redis-server redis redis6 redis7)" || error "No Redis systemd unit found."
  svc_restart "$svc"

  # ── Verify (falls back to TCP if the socket cannot be used) ────────────────
  if ! _redis_ping "$conn" "$sock"; then
    if [[ "$conn" == "socket" ]]; then
      warn "Redis did not answer on $sock - falling back to TCP 127.0.0.1:6379"
      sed -i '/^unixsocket/d' "$conf"
      conn="tcp"
      svc_restart "$svc"
      _redis_ping "$conn" "$sock" ||
        error "Redis is not answering PING. Check: systemctl status $svc; journalctl -u $svc"
    else
      error "Redis is not answering PING after configuration. Check: systemctl status $svc; journalctl -u $svc"
    fi
  fi
  log "Redis is running and responding to PING ✔ (${conn})"

  # PHP-FPM must be restarted to pick up the new group membership.
  php_layout
  if [[ "$conn" == "socket" ]] && svc_exists "$PHP_FPM_SVC" && svc_active "$PHP_FPM_SVC"; then
    svc_restart "$PHP_FPM_SVC"
  fi
  return 0
}
