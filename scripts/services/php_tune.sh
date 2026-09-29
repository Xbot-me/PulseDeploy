#!/usr/bin/env bash
# Service: PHP-FPM / php.ini / OPcache performance tuning
# shellcheck source=scripts/lib/web.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/web.sh"

tune_php_fpm() {
  section "PHP Performance Tuning"

  # Use the PHP that is really installed (Debian keeps one dir per version).
  local detected=""
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    if [[ -n "${PHP_VER:-}" && -d "/etc/php/${PHP_VER}" ]]; then
      detected="$PHP_VER"
    else
      detected="$(find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)" || detected=""
    fi
  else
    detected="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)" || detected=""
  fi
  if [[ -z "$detected" ]]; then
    warn "PHP not found, skipping tuning."
    return 0
  fi
  PHP_VER="$detected"
  php_layout

  local ram_mb
  ram_mb="$(total_ram_mb)"

  # ── FPM pool ───────────────────────────────────────────────────────────────
  # ~100MB of RAM per child leaves headroom for MySQL/Redis/OS on the same box.
  local max_children=$((ram_mb / 100))
  ((max_children < 5)) && max_children=5
  ((max_children > 300)) && max_children=300
  local min_spare=$((max_children / 4)); ((min_spare < 2)) && min_spare=2
  local max_spare=$((max_children / 2)); ((max_spare < 4)) && max_spare=4
  local start=$min_spare
  info "RAM: ${ram_mb}MB → pm.max_children=${max_children}, start=${start}, spare=${min_spare}-${max_spare}"

  local pool_changed=0
  if [[ -f "$PHP_POOL_CONF" ]]; then
    backup_file "$PHP_POOL_CONF"
    conf_set "$PHP_POOL_CONF" "pm" "dynamic" " = "
    conf_set "$PHP_POOL_CONF" "pm.max_children" "$max_children" " = "
    conf_set "$PHP_POOL_CONF" "pm.start_servers" "$start" " = "
    conf_set "$PHP_POOL_CONF" "pm.min_spare_servers" "$min_spare" " = "
    conf_set "$PHP_POOL_CONF" "pm.max_spare_servers" "$max_spare" " = "
    conf_set "$PHP_POOL_CONF" "pm.max_requests" "500" " = "
    pool_changed=1
    log "PHP-FPM pool tuned in $PHP_POOL_CONF"
  else
    info "No PHP-FPM pool config found (mod_php setup?) — tuning php.ini only"
  fi

  # ── php.ini + OPcache as a drop-in, never editing package-owned files ──────
  # (Overwriting the package's opcache.ini would drop its zend_extension line
  # and silently disable OPcache.)
  local opcache_mem=$((ram_mb / 8))
  ((opcache_mem < 64)) && opcache_mem=64
  ((opcache_mem > 256)) && opcache_mem=256

  local -a written=()
  local d
  for d in "${PHP_INI_DIRS[@]}"; do
    cat >"$d/99-pulsedeploy.ini" <<INI
; Managed by PulseDeploy — remove this file to undo
expose_php = Off
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300

opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${opcache_mem}
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
opcache.jit_buffer_size = 64M
opcache.jit = tracing
INI
    written+=("$d/99-pulsedeploy.ini")
  done
  if ((${#written[@]})); then
    log "php.ini + OPcache (${opcache_mem}MB, JIT tracing) tuned via ${written[*]}"
  else
    warn "No PHP conf.d directory found — php.ini/OPcache tuning skipped."
  fi

  # ── Validate before restarting; roll back on failure ───────────────────────
  if [[ "$pool_changed" -eq 1 ]] && command -v "$PHP_FPM_BIN" &>/dev/null; then
    if ! "$PHP_FPM_BIN" -t; then
      cp -a "${PHP_POOL_CONF}.pulsedeploy.bak" "$PHP_POOL_CONF"
      ((${#written[@]})) && rm -f "${written[@]}"
      error "PHP-FPM rejected the tuned configuration; original files were restored."
    fi
  fi

  if svc_exists "$PHP_FPM_SVC"; then
    svc_restart "$PHP_FPM_SVC"
    log "PHP-FPM restarted"
  fi
  local apache_svc
  if apache_svc="$(svc_first_existing apache2 httpd)" && svc_active "$apache_svc"; then
    svc_restart "$apache_svc"
    log "$apache_svc restarted (mod_php picks up new php.ini settings)"
  fi
  return 0
}
