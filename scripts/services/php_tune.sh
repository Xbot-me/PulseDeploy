#!/usr/bin/env bash
# Service: PHP-FPM performance tuning

tune_php_fpm() {
  section "PHP-FPM Performance Tuning"

  # Detect PHP version in use
  PHP_VER="${PHP_VER:-$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)}"
  [[ -z "$PHP_VER" ]] && { warn "PHP not found, skipping tuning."; return 0; }

  # Detect RAM
  local RAM_MB
  RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)

  # Calculate pool values based on RAM
  local PM_MAX_CHILDREN PM_START PM_MIN_SPARE PM_MAX_SPARE
  PM_MAX_CHILDREN=$(( RAM_MB / 40 ))   # ~40MB per PHP process
  [[ $PM_MAX_CHILDREN -lt 5 ]] && PM_MAX_CHILDREN=5
  PM_START=$(( PM_MAX_CHILDREN / 4 ))
  [[ $PM_START -lt 2 ]] && PM_START=2
  PM_MIN_SPARE=$(( PM_MAX_CHILDREN / 4 ))
  [[ $PM_MIN_SPARE -lt 2 ]] && PM_MIN_SPARE=2
  PM_MAX_SPARE=$(( PM_MAX_CHILDREN / 2 ))
  [[ $PM_MAX_SPARE -lt 4 ]] && PM_MAX_SPARE=4

  info "RAM: ${RAM_MB}MB → pm.max_children=${PM_MAX_CHILDREN}, start=${PM_START}"

  # Find pool config
  local POOL_CONF
  POOL_CONF=$(find /etc/php -name "www.conf" 2>/dev/null | head -1)
  [[ -z "$POOL_CONF" ]] && POOL_CONF="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"

  if [[ -f "$POOL_CONF" ]]; then
    cp "$POOL_CONF" "${POOL_CONF}.bak"
    sed -i "s|^pm = .*|pm = dynamic|"                                          "$POOL_CONF"
    sed -i "s|^pm.max_children = .*|pm.max_children = ${PM_MAX_CHILDREN}|"    "$POOL_CONF"
    sed -i "s|^pm.start_servers = .*|pm.start_servers = ${PM_START}|"         "$POOL_CONF"
    sed -i "s|^pm.min_spare_servers = .*|pm.min_spare_servers = ${PM_MIN_SPARE}|" "$POOL_CONF"
    sed -i "s|^pm.max_spare_servers = .*|pm.max_spare_servers = ${PM_MAX_SPARE}|" "$POOL_CONF"
    sed -i "s|^;pm.max_requests = .*|pm.max_requests = 500|"                  "$POOL_CONF"
    log "PHP-FPM pool tuned in $POOL_CONF"
  fi

  # ── OPcache config ────────────────────────────────────────────────────────
  local OPCACHE_CONF
  OPCACHE_CONF=$(find /etc/php -name "opcache.ini" 2>/dev/null | head -1)
  [[ -z "$OPCACHE_CONF" ]] && OPCACHE_CONF="/etc/php/${PHP_VER}/mods-available/opcache.ini"

  local OPCACHE_MEM=$(( RAM_MB / 8 ))
  [[ $OPCACHE_MEM -lt 64  ]] && OPCACHE_MEM=64
  [[ $OPCACHE_MEM -gt 256 ]] && OPCACHE_MEM=256

  cat > "/etc/php/${PHP_VER}/mods-available/opcache.ini" 2>/dev/null || \
  cat > /tmp/opcache-tune.ini <<OPCACHE
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=${OPCACHE_MEM}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.jit_buffer_size=64M
opcache.jit=tracing
OPCACHE

  log "OPcache tuned: ${OPCACHE_MEM}MB memory + JIT tracing enabled"

  # ── PHP.ini hardening ─────────────────────────────────────────────────────
  local PHP_INI
  PHP_INI=$(find /etc/php -name "php.ini" -path "*/fpm/*" 2>/dev/null | head -1)
  if [[ -f "$PHP_INI" ]]; then
    cp "$PHP_INI" "${PHP_INI}.bak"
    sed -i 's|^expose_php = .*|expose_php = Off|'          "$PHP_INI"
    sed -i 's|^upload_max_filesize = .*|upload_max_filesize = 64M|' "$PHP_INI"
    sed -i 's|^post_max_size = .*|post_max_size = 64M|'   "$PHP_INI"
    sed -i 's|^max_execution_time = .*|max_execution_time = 300|' "$PHP_INI"
    sed -i 's|^memory_limit = .*|memory_limit = 256M|'    "$PHP_INI"
    log "PHP.ini hardened (expose_php off, memory 256M, upload 64M)"
  fi

  # Restart PHP-FPM
  systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || \
  systemctl restart php-fpm 2>/dev/null || true
  log "PHP-FPM restarted"
}