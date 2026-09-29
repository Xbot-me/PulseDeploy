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

# PHP-FPM max_children (ondemand): ~20% of RAM at 60 MB per worker.
tune_fpm_children() { _clamp $(($1 * 20 / 100 / 60)) 4 40; }

# InnoDB buffer pool in MB: ~18% of RAM. InnoDB rounds the size to whole
# chunks (128 MB, or 1 GB once it uses several instances), so round the same
# way here and the configured value is the real one.
tune_mysql_buffer_pool() {
  local ram="$1" bp
  if ((ram <= 1536)); then echo 128; return 0; fi
  bp="$(_clamp $((ram * 18 / 100)) 192 4096)"
  if ((bp >= 1024)); then
    echo $((bp - bp % 1024))
  else
    echo $(((bp + 127) / 128 * 128))
  fi
}

tune_mysql_max_connections() { if (($1 <= 4096)); then echo 50; else echo 100; fi; }
tune_mysql_tmp_table_mb()    { if (($1 <= 4096)); then echo 32; else echo 64; fi; }

# Redis maxmemory in MB: ~6% of RAM, between 64 and 512.
tune_redis_mem() { _clamp $(($1 * 6 / 100)) 64 512; }

# Node old-space heap in MB. tune_node_heap <ram_mb> <admin|shop>
tune_node_heap() {
  local ram="$1" app="$2"
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
