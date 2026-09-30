#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - resource sizing for the single-server Laravel + Next.js profile
# Pure functions: RAM in MB in, a number out. Everything shares one machine, so
# each service gets a slice instead of the "use most of the RAM" defaults.
# =============================================================================

_clamp() { # _clamp <value> <min> <max>
  local v="$1" lo="$2" hi="$3"
  ((v < lo)) && v="$lo"
  ((v > hi)) && v="$hi"
  echo "$v"
}

# ── hand-tuned overrides ──────────────────────────────────────────────────────
# /etc/pulsedeploy/tuning.conf holds optional KEY=VALUE lines (positive integers):
#   FPM_CHILDREN  MYSQL_BUFFER_POOL_MB  MYSQL_MAX_CONNECTIONS  REDIS_MAXMEM_MB
#   NODE_HEAP_ADMIN  NODE_HEAP_SHOP
# They replace the RAM-based numbers below, so a value found by measuring survives
# re-runs of the installer and is what `audit.sh` treats as the target.
TUNE_OVERRIDE_KEYS="FPM_CHILDREN MYSQL_BUFFER_POOL_MB MYSQL_MAX_CONNECTIONS REDIS_MAXMEM_MB NODE_HEAP_ADMIN NODE_HEAP_SHOP"

# Read the file without executing it; unknown keys and non-numbers are ignored.
tune_load_overrides() { # tune_load_overrides [file]
  local f="${1:-/etc/pulsedeploy/tuning.conf}" k v
  [[ -r "$f" ]] || return 0
  while IFS='=' read -r k v; do
    v="${v//[[:space:]]/}"
    [[ " $TUNE_OVERRIDE_KEYS " == *" $k "* && "$v" =~ ^[1-9][0-9]*$ ]] && printf -v "TUNE_$k" '%s' "$v"
  done <"$f"
  return 0
}

# Active overrides as "KEY=VALUE" lines (empty when there are none).
tune_active_overrides() {
  local k n
  for k in $TUNE_OVERRIDE_KEYS; do
    n="TUNE_$k"
    [[ -z "${!n:-}" ]] || printf '%s=%s\n' "$k" "${!n}"
  done
  return 0
}

# PHP-FPM max_children (ondemand): ~20% of RAM at 60 MB per worker.
tune_fpm_children() {
  if [[ -n "${TUNE_FPM_CHILDREN:-}" ]]; then echo "$TUNE_FPM_CHILDREN"; return 0; fi
  _clamp $(($1 * 20 / 100 / 60)) 4 40
}

# InnoDB buffer pool in MB: ~18% of RAM. InnoDB rounds the size to whole
# chunks (128 MB, or 1 GB once it uses several instances), so round the same
# way here and the configured value is the real one.
tune_mysql_buffer_pool() {
  local ram="$1" bp
  if [[ -n "${TUNE_MYSQL_BUFFER_POOL_MB:-}" ]]; then echo "$TUNE_MYSQL_BUFFER_POOL_MB"; return 0; fi
  if ((ram <= 1536)); then echo 128; return 0; fi
  bp="$(_clamp $((ram * 18 / 100)) 192 4096)"
  if ((bp >= 1024)); then
    echo $((bp - bp % 1024))
  else
    echo $(((bp + 127) / 128 * 128))
  fi
}

tune_mysql_max_connections() {
  if [[ -n "${TUNE_MYSQL_MAX_CONNECTIONS:-}" ]]; then echo "$TUNE_MYSQL_MAX_CONNECTIONS"; return 0; fi
  if (($1 <= 4096)); then echo 50; else echo 100; fi
}
tune_mysql_tmp_table_mb()    { if (($1 <= 4096)); then echo 32; else echo 64; fi; }

# Redis maxmemory in MB: ~6% of RAM, between 64 and 512.
tune_redis_mem() {
  if [[ -n "${TUNE_REDIS_MAXMEM_MB:-}" ]]; then echo "$TUNE_REDIS_MAXMEM_MB"; return 0; fi
  _clamp $(($1 * 6 / 100)) 64 512
}

# Node old-space heap in MB. tune_node_heap <ram_mb> <admin|shop>
tune_node_heap() {
  local ram="$1" app="$2" o
  o="TUNE_NODE_HEAP_${app^^}"
  if [[ -n "${!o:-}" ]]; then echo "${!o}"; return 0; fi
  if ((ram >= 8192)); then
    [[ "$app" == "shop" ]] && echo 512 || echo 384
  elif ((ram >= 4096)); then
    [[ "$app" == "shop" ]] && echo 384 || echo 256
  else
    echo 256
  fi
}

# systemd MemoryMax for a Node app: heap plus headroom for buffers/native memory.
tune_node_memory_max() { echo $(($(tune_node_heap "$1" "$2") + 192)); }

# Human summary used by the installer and `pulse status`.
tune_summary() {
  local ram="$1"
  printf 'RAM %sMB: php-fpm max_children=%s, innodb_buffer_pool=%sM, redis=%sM, node heap admin=%sM shop=%sM\n' \
    "$ram" "$(tune_fpm_children "$ram")" "$(tune_mysql_buffer_pool "$ram")" \
    "$(tune_redis_mem "$ram")" "$(tune_node_heap "$ram" admin)" "$(tune_node_heap "$ram" shop)"
}
