#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - retune.sh: apply hand-tuned values to a running server
#   sudo bash scripts/retune.sh             show what would change (changes nothing)
#   sudo bash scripts/retune.sh --apply     apply it
#
# Values come from /etc/pulsedeploy/tuning.conf (see docs/auditing.md), falling
# back to the RAM-based sizing for anything not set there. Only the tunable
# numbers are touched: no virtual host, TLS or application file is rewritten.
#   PHP-FPM   pool file, config test, reload          (no dropped requests)
#   database  SET GLOBAL + config file                 (no restart)
#   Redis     CONFIG SET + config file                 (no restart)
#   Node      env file + MemoryMax drop-in, restart     (about a second per app)
# A combination that would not fit in RAM is refused unless --force is given.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/audit.sh
source "$ROOT/scripts/audit.sh" # helpers only; audit.sh does nothing when sourced

APPLY=0; FORCE=0; WORKER_MB=60; CHANGES=0

step()   { printf '  %s\n' "$*"; }
ok()     { printf '  %s %s\n' "${GREEN}DONE${RESET}" "$*"; }
refuse() { printf '  %s %s\n' "${RED}STOP${RESET}" "$*" >&2; }

# change <label> <current> <new>: prints a plan line, returns 0 when a change is needed
change() {
  if [[ "$2" == "$3" ]]; then step "$1: $2 (already the target)"; return 1; fi
  CHANGES=$((CHANGES + 1))
  step "$1: $2 -> $3"
  return 0
}

db_ready() { local i; for i in $(seq 1 30); do mysql_q 'SELECT 1' >/dev/null && return 0; sleep 1; done; return 1; }

retune_php() {
  local pool cur new svc bin
  pool="$(first_file /etc/php-fpm.d/pulse-laravel.conf /etc/php/*/fpm/pool.d/pulse-laravel.conf)" || { step "PHP-FPM: pool file not found, skipped"; return 0; }
  cur="$(ini_val "$pool" pm.max_children)"; new="$(tune_fpm_children "$RAM")"
  change "PHP-FPM pm.max_children" "$cur" "$new" || return 0
  [[ "$APPLY" -eq 1 ]] || return 0
  cp -a "$pool" "$pool.retune.bak"
  sed -i -E "s/^([[:space:]]*pm\.max_children[[:space:]]*=[[:space:]]*).*/\1${new}/" "$pool"
  bin="$(command -v php-fpm || command -v php-fpm8.4 || command -v php-fpm8.3 || command -v php-fpm8.2 || true)"
  if [[ -n "$bin" ]] && ! "$bin" -t &>/dev/null; then
    cp -a "$pool.retune.bak" "$pool"; refuse "PHP-FPM rejected the new value; the pool file was restored"; return 1
  fi
  svc="$(conf_val "$LNX_ETC/pulse.conf" PHP_FPM_SVC)"; svc="${svc:-php-fpm}"
  systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
  ok "PHP-FPM reloaded with pm.max_children=${new}"
}

retune_db() {
  if ! have mysql || ! mysql_q 'SELECT 1' >/dev/null; then step "database: not reachable (run as root), skipped"; return 0; fi
  local cnf cur_bp new_bp cur_mc new_mc
  cnf="$(first_file /etc/my.cnf.d/zz-pulsedeploy.cnf /etc/mysql/conf.d/zz-pulsedeploy.cnf)" || { step "database: PulseDeploy tuning file not found, skipped"; return 0; }
  cur_bp=$(($(mysql_q 'SELECT @@innodb_buffer_pool_size') / 1048576)); new_bp="$(tune_mysql_buffer_pool "$RAM")"
  cur_mc="$(mysql_q 'SELECT @@max_connections')"; new_mc="$(tune_mysql_max_connections "$RAM")"
  if change "InnoDB buffer pool (MB)" "$cur_bp" "$new_bp" && [[ "$APPLY" -eq 1 ]]; then
    cp -a "$cnf" "$cnf.retune.bak"
    if mysql -e "SET GLOBAL innodb_buffer_pool_size = $((new_bp * 1048576))" 2>/dev/null; then
      sed -i -E "s/^(innodb_buffer_pool_size[[:space:]]*=[[:space:]]*).*/\1${new_bp}M/" "$cnf"
      ok "buffer pool set to ${new_bp}M live and in $cnf (the resize finishes in the background)"
    else
      refuse "the server refused the new buffer pool size; left unchanged"
    fi
  fi
  if change "max_connections" "$cur_mc" "$new_mc" && [[ "$APPLY" -eq 1 ]]; then
    mysql -e "SET GLOBAL max_connections = ${new_mc}" 2>/dev/null &&
      sed -i -E "s/^(max_connections[[:space:]]*=[[:space:]]*).*/\1${new_mc}/" "$cnf" &&
      ok "max_connections set to ${new_mc}"
  fi
}

retune_redis() {
  local cli cur new c
  if ! cli="$(redis_bin)" || [[ "$("$cli" ping 2>/dev/null)" != "PONG" ]]; then step "Redis: not running, skipped"; return 0; fi
  cur=$(($("$cli" config get maxmemory 2>/dev/null | tail -n 1) / 1048576)); new="$(tune_redis_mem "$RAM")"
  change "Redis maxmemory (MB)" "$cur" "$new" || return 0
  [[ "$APPLY" -eq 1 ]] || return 0
  "$cli" config set maxmemory "${new}mb" >/dev/null
  for c in /etc/redis/redis.conf /etc/redis.conf /etc/redis6/redis6.conf /etc/redis7/redis7.conf; do
    [[ -f "$c" ]] && { conf_set "$c" maxmemory "${new}mb"; break; }
  done
  ok "Redis maxmemory set to ${new}mb live and in its config"
}

retune_node() {
  local app unit env cur new mm
  for app in admin shop; do
    unit="pulse-next@${app}"; env="$LNX_ETC/$app.env"
    if ! systemctl cat "$unit" &>/dev/null || [[ ! -f "$env" ]]; then step "Node ${app}: not installed, skipped"; continue; fi
    cur="$(conf_val "$env" NODE_OPTIONS | sed -n 's/.*max-old-space-size=\([0-9]*\).*/\1/p')"; new="$(tune_node_heap "$RAM" "$app")"
    change "Node ${app} heap (MB)" "${cur:-?}" "$new" || continue
    [[ "$APPLY" -eq 1 ]] || continue
    mm="$(tune_node_memory_max "$RAM" "$app")"
    sed -i -E "s/(--max-old-space-size=)[0-9]+/\1${new}/" "$env"
    mkdir -p "/etc/systemd/system/${unit}.service.d"
    printf '[Service]\nMemoryMax=%sM\n' "$mm" >"/etc/systemd/system/${unit}.service.d/limits.conf"
    systemctl daemon-reload
    systemctl restart "$unit" && ok "Node ${app}: heap ${new}M, MemoryMax ${mm}M, restarted"
  done
}

# Refuse a plan that cannot fit: DB pool + 300, Redis, both Node limits, 512 for the OS,
# and the PHP workers at the assumed size (--worker-mb) must not exceed the RAM.
fits_in_ram() {
  local children bp redis am sm used
  children="$(tune_fpm_children "$RAM")"; bp="$(tune_mysql_buffer_pool "$RAM")"; redis="$(tune_redis_mem "$RAM")"
  am="$(tune_node_memory_max "$RAM" admin)"; sm="$(tune_node_memory_max "$RAM" shop)"
  used=$((children * WORKER_MB + bp + 300 + redis + am + sm + 512))
  step "memory plan: PHP ${children} x ${WORKER_MB} MB + database $((bp + 300)) MB + Redis ${redis} MB + Node ${am}+${sm} MB + OS 512 MB = ${used} MB of ${RAM} MB"
  if [[ "$used" -gt "$RAM" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then step "over budget by $((used - RAM)) MB, continuing because of --force"; return 0; fi
    refuse "this plan needs ${used} MB but the machine has ${RAM} MB (over by $((used - RAM)) MB). Lower a value in tuning.conf, pass --worker-mb if your measured worker is smaller, or --force"
    return 1
  fi
  return 0
}

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/retune.sh [--apply] [--worker-mb N] [--force]
  (no option)   show what would change; nothing is modified
  --apply       apply the changes to the running services
  --worker-mb   PHP worker size used for the memory check (default 60; use the
                measured figure from `audit.sh --load`)
  --force       apply even if the memory plan is over budget
Values are read from /etc/pulsedeploy/tuning.conf, for example:
  FPM_CHILDREN=16
  MYSQL_BUFFER_POOL_MB=1024
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) APPLY=1 ;;
      --force) FORCE=1 ;;
      --worker-mb) WORKER_MB="${2:-}"; shift ;;
      -h | --help) usage; return 0 ;;
      *) echo "Unknown option: $1" >&2; usage >&2; return 2 ;;
    esac
    shift
  done
  [[ "$WORKER_MB" =~ ^[1-9][0-9]*$ ]] || { echo "--worker-mb must be a positive number" >&2; return 2; }
  [[ "$(id -u)" -eq 0 ]] || { echo "Run as root." >&2; return 1; }
  [[ -r "$LNX_ETC/pulse.conf" ]] || { echo "No PulseDeploy laravel-next install found ($LNX_ETC/pulse.conf)." >&2; return 1; }
  RAM="$(mem_total_mb)"
  tune_load_overrides "$LNX_ETC/tuning.conf"
  printf '\nRetune: RAM %s MB\n' "$RAM"
  local ov; ov="$(tune_active_overrides | tr '\n' ' ')"
  step "overrides from $LNX_ETC/tuning.conf: ${ov:-none (RAM-based sizing)}"
  fits_in_ram || return 1
  printf '\n'
  retune_php
  retune_db
  retune_redis
  retune_node
  printf '\n'
  if [[ "$CHANGES" -eq 0 ]]; then
    echo "Everything already matches; nothing to do."
  elif [[ "$APPLY" -eq 1 ]]; then
    echo "Applied ${CHANGES} change(s). Verify with: sudo bash scripts/audit.sh"
  else
    echo "${CHANGES} change(s) planned. Run again with --apply to make them."
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
