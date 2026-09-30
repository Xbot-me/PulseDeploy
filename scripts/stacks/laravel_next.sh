#!/usr/bin/env bash
# Stack: Laravel API + two Next.js apps (admin dashboard, storefront) on one
# small server: nginx, PHP-FPM (ondemand), MySQL, Redis, systemd services.
# shellcheck source=scripts/lib/web.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/web.sh"
# shellcheck source=scripts/lib/profile_tuning.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/profile_tuning.sh"
# shellcheck source=scripts/services/mysql.sh
source "$(dirname "${BASH_SOURCE[0]}")/../services/mysql.sh"
# shellcheck source=scripts/services/redis.sh
source "$(dirname "${BASH_SOURCE[0]}")/../services/redis.sh"
# shellcheck source=scripts/services/php_tune.sh
source "$(dirname "${BASH_SOURCE[0]}")/../services/php_tune.sh"
# shellcheck source=scripts/stacks/node.sh
source "$(dirname "${BASH_SOURCE[0]}")/node.sh"

LNX_TEMPLATES="$SCRIPT_DIR/config/laravel-next"
LNX_APPS_ROOT="${LNX_APPS_ROOT:-/var/www}"
LNX_ETC="${LNX_ETC:-/etc/pulsedeploy}"
LNX_SHOP_PORT=3000
LNX_ADMIN_PORT=3001
LNX_INTERNAL_API_PORT=8081

# lnx_render <template> <output> KEY=value...   (replaces @KEY@ markers)
lnx_render() {
  local tpl="$1" out="$2" content kv
  shift 2
  shopt -u patsub_replacement 2>/dev/null || true
  content="$(cat "$tpl")"
  for kv in "$@"; do
    content="${content//@${kv%%=*}@/${kv#*=}}"
  done
  printf '%s\n' "$content" >"$out"
}

# Remove IPv6 listen lines on hosts without IPv6 (nginx would fail to bind).
lnx_strip_ipv6_if_absent() {
  local off=0
  [[ -e /proc/net/if_inet6 ]] || off=1
  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == "1" ]] && off=1
  if [[ "$off" -eq 1 ]]; then sed -i '/listen \[::\]/d' "$1"; fi
  return 0
}

lnx_defaults() {
  [[ -n "${DOMAIN:-}" ]] || error "The laravel-next stack needs --domain (for example example.com)."
  APP_USER="${APP_USER:-deploy}"
  API_HOST="${API_HOST:-api.${DOMAIN}}"
  ADMIN_HOST="${ADMIN_HOST:-admin.${DOMAIN}}"
  SHOP_HOST="${SHOP_HOST:-${DOMAIN}}"
  DB_NAME="${DB_NAME:-app}"
  DB_USER="${DB_USER:-app}"
  LNX_RAM_MB="$(total_ram_mb)"
  if ((LNX_RAM_MB < 1800)); then
    warn "Only ${LNX_RAM_MB}MB RAM: 2GB is the practical minimum for MySQL + PHP + two Node apps. Expect swapping."
  fi
  info "$(tune_summary "$LNX_RAM_MB")"
}

# Highest PHP version the distribution ships itself (avoids third-party repos).
lnx_default_php() {
  if [[ "${PHP_SET:-0}" == "1" ]]; then return 0; fi
  local cand=""
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    cand="$(apt-cache depends php-cli 2>/dev/null | sed -n 's/^ *Depends: php\([0-9.]*\)-cli$/\1/p' | head -n 1)" || cand=""
  fi
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    # Amazon Linux / RHEL-family: versioned packages such as php8.3-fpm
    local avail=""
    avail="$(pm_rpm list --available 'php8.*-fpm' 2>/dev/null || true)"
    cand="$(grep -o 'php8\.[2-4]-fpm' <<<"$avail" | sed 's/^php//; s/-fpm$//' | sort -V | tail -n 1)" || cand=""
  fi
  if [[ "$cand" =~ ^8\.[2-4]$ ]]; then PHP_VER="$cand"; else PHP_VER="8.3"; fi
  info "PHP version: ${PHP_VER} (Laravel needs 8.2 or newer)"
}

# ── users and directories ─────────────────────────────────────────────────────
lnx_create_user() {
  if ! id "$APP_USER" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$APP_USER"
    log "Created user $APP_USER"
  fi
  # CI deploys over SSH: reuse the keys already allowed for root, if any.
  local home ssh_dir
  home="$(getent passwd "$APP_USER" | cut -d: -f6)"
  ssh_dir="$home/.ssh"
  if [[ -s /root/.ssh/authorized_keys && ! -s "$ssh_dir/authorized_keys" ]]; then
    install -d -m 700 -o "$APP_USER" -g "$APP_USER" "$ssh_dir"
    install -m 600 -o "$APP_USER" -g "$APP_USER" /root/.ssh/authorized_keys "$ssh_dir/authorized_keys"
    info "Copied root's SSH keys to $APP_USER so CI can deploy as that user"
  fi
}

lnx_create_dirs() {
  local app
  for app in api admin shop; do
    install -d -o "$APP_USER" -g "$APP_USER" "$LNX_APPS_ROOT/$app" "$LNX_APPS_ROOT/$app/releases" "$LNX_APPS_ROOT/$app/shared"
  done
  install -d -o "$APP_USER" -g "$APP_USER" \
    "$LNX_APPS_ROOT/api/shared/storage/app/public" \
    "$LNX_APPS_ROOT/api/shared/storage/framework/cache/data" \
    "$LNX_APPS_ROOT/api/shared/storage/framework/sessions" \
    "$LNX_APPS_ROOT/api/shared/storage/framework/views" \
    "$LNX_APPS_ROOT/api/shared/storage/logs" \
    "$LNX_APPS_ROOT/admin/shared/next-cache" "$LNX_APPS_ROOT/shop/shared/next-cache"
  install -d -m 755 "$LNX_ETC"
}

# Holding pages so every vhost answers before the first real deploy. They are
# real releases, so the first deploy swaps them out like any other.
lnx_placeholders() {
  local api="$LNX_APPS_ROOT/api/releases/000-placeholder"
  if [[ ! -e "$LNX_APPS_ROOT/api/current" ]]; then
    install -d -o "$APP_USER" -g "$APP_USER" "$api/public"
    cat >"$api/public/index.php" <<'PHP'
<?php
header('Content-Type: text/plain');
echo "API ready: waiting for the first deploy (pulse deploy api ...)\n";
PHP
    chown "$APP_USER:$APP_USER" "$api/public/index.php"
    ln -sfn "$api" "$LNX_APPS_ROOT/api/current"
    chown -h "$APP_USER:$APP_USER" "$LNX_APPS_ROOT/api/current"
  fi
  local app dir
  for app in admin shop; do
    dir="$LNX_APPS_ROOT/$app/releases/000-placeholder"
    [[ -e "$LNX_APPS_ROOT/$app/current" ]] && continue
    install -d -o "$APP_USER" -g "$APP_USER" "$dir/.next/static"
    cat >"$dir/server.js" <<JS
const http = require('http');
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('${app} ready: waiting for the first deploy (pulse deploy ${app} ...)\\n');
}).listen(process.env.PORT || 3000, process.env.HOSTNAME || '127.0.0.1');
JS
    chown "$APP_USER:$APP_USER" "$dir/server.js"
    ln -sfn "$dir" "$LNX_APPS_ROOT/$app/current"
    chown -h "$APP_USER:$APP_USER" "$LNX_APPS_ROOT/$app/current"
  done
}

# ── PHP / Composer ────────────────────────────────────────────────────────────
lnx_setup_php() {
  php_install_packages fpm
  php_layout

  local web_user="www-data"
  [[ "$PKG_MANAGER" == "dnf" ]] && web_user="nginx"
  LNX_PHP_SOCK="/run/php/pulse-laravel.sock"
  [[ "$PKG_MANAGER" == "dnf" ]] && LNX_PHP_SOCK="/run/php-fpm/pulse-laravel.sock"

  local pool_dir
  pool_dir="$(dirname "$PHP_POOL_CONF")"
  lnx_render "$LNX_TEMPLATES/php-fpm-pool.conf" "$pool_dir/pulse-laravel.conf" \
    "APP_USER=$APP_USER" "PHP_SOCK=$LNX_PHP_SOCK" "WEB_USER=$web_user" \
    "CHILDREN=$(tune_fpm_children "$LNX_RAM_MB")"

  # The stock "www" pool would only sit idle; drop it (backup kept).
  if [[ -f "$PHP_POOL_CONF" ]]; then
    backup_file "$PHP_POOL_CONF"
    rm -f "$PHP_POOL_CONF"
  fi

  # Production PHP: never re-stat files (the deploy reloads FPM), no JIT.
  local -a written=() ; local opcache_mem=128
  ((LNX_RAM_MB < 2048)) && opcache_mem=96
  PHP_OPCACHE_VALIDATE=0 PHP_JIT=off PHP_OPCACHE_FILES=30000 PHP_MAX_EXECUTION=60 \
    php_write_ini_dropin "$opcache_mem" written
  ((${#written[@]})) && log "PHP ini tuned via ${written[*]}"

  if command -v "$PHP_FPM_BIN" &>/dev/null && ! "$PHP_FPM_BIN" -t; then
    rm -f "$pool_dir/pulse-laravel.conf"
    error "PHP-FPM rejected the generated pool configuration (output above); it was removed."
  fi
  svc_restart "$PHP_FPM_SVC"
  log "PHP ${PHP_VER}-FPM running with the ondemand pool (max ${LNX_PHP_CHILDREN:-$(tune_fpm_children "$LNX_RAM_MB")} workers)"

  local php_bin="php"
  [[ "$PKG_MANAGER" == "apt" ]] && php_bin="php${PHP_VER}"
  LNX_PHP_BIN="$(command -v "$php_bin")" || error "$php_bin not found after installing PHP."
  if ! "$LNX_PHP_BIN" -m | grep -qix redis; then
    warn "The phpredis extension is not installed. Set REDIS_CLIENT=predis in the Laravel .env and add predis/predis, or install php-redis."
  fi
}

lnx_setup_composer() {
  command -v composer &>/dev/null && { log "Composer present: $(composer --version 2>/dev/null | head -n 1)"; return 0; }
  if [[ "$PKG_MANAGER" == "apt" ]] && pkg_available composer; then
    os_pkg_install composer
  else
    local tmp expected actual
    tmp="$(mktemp)"
    if download "https://getcomposer.org/installer" "$tmp" 2>/dev/null &&
       expected="$(curl -fsSL https://composer.github.io/installer.sig 2>/dev/null)" &&
       actual="$("$LNX_PHP_BIN" -r "echo hash_file('sha384', '$tmp');")" &&
       [[ -n "$expected" && "$expected" == "$actual" ]]; then
      "$LNX_PHP_BIN" "$tmp" --quiet --install-dir=/usr/local/bin --filename=composer
    else
      warn "Could not install Composer (download or signature check failed). Deploy the API from a CI-built artifact, or install Composer later."
    fi
    rm -f "$tmp"
  fi
  command -v composer &>/dev/null && log "Composer installed"
  return 0
}

# ── MySQL tuning ──────────────────────────────────────────────────────────────
lnx_tune_mysql() {
  local dir="/etc/mysql/conf.d"
  [[ -d "$dir" ]] || dir="/etc/my.cnf.d"
  [[ -d "$dir" ]] || { warn "No MySQL conf.d directory found; skipping database tuning."; return 0; }
  local target="$dir/zz-pulsedeploy.cnf" binlog=""
  mysql_is_mariadb || binlog="binlog_expire_logs_seconds = 259200"
  # One database per tenant means many more tables in use at once.
  local table_cache=800 table_def=1000
  if [[ -n "${TENANT_DB_PREFIX:-}" ]]; then table_cache=2000; table_def=2000; fi
  lnx_render "$LNX_TEMPLATES/mysql-tuning.cnf" "$target" \
    "MAXCONN=$(tune_mysql_max_connections "$LNX_RAM_MB")" \
    "BP=$(tune_mysql_buffer_pool "$LNX_RAM_MB")" \
    "TMP=$(tune_mysql_tmp_table_mb "$LNX_RAM_MB")" \
    "TABLE_CACHE=$table_cache" "TABLE_DEF=$table_def" \
    "BINLOG=$binlog"
  local svc
  svc="$(svc_first_existing mysql mysqld mariadb)" || error "No MySQL/MariaDB unit found."
  if svc_restart "$svc" && mysql_wait_ready && mysql -e 'SELECT 1' &>/dev/null; then
    log "MySQL tuned: buffer pool $(tune_mysql_buffer_pool "$LNX_RAM_MB")M, performance_schema off"
  else
    warn "MySQL did not come back with the tuning file; removing it and restarting with defaults."
    rm -f "$target"
    svc_restart "$svc" || error "MySQL will not start even without PulseDeploy's tuning; check: journalctl -u $svc"
  fi
}

# ── Laravel .env (only when absent; never overwrites the app's own file) ──────
lnx_write_env() {
  local env="$LNX_APPS_ROOT/api/shared/.env" pass
  if [[ -e "$env" ]]; then
    info "Laravel .env already exists; left unchanged"
    return 0
  fi
  pass="$(mysql_saved_password "$DB_USER")"
  [[ -n "$pass" ]] || warn "No saved password for database user '$DB_USER'; set DB_PASSWORD in $env yourself."
  local queue_conn="redis"
  [[ "${NO_QUEUE:-0}" == "1" ]] && queue_conn="sync"
  local stateful="${ADMIN_HOST},${SHOP_HOST}"
  [[ "$SHOP_HOST" == "$DOMAIN" ]] && stateful="${stateful},www.${DOMAIN}"
  (
    umask 027
    cat >"$env" <<ENV
APP_NAME=${DOMAIN}
APP_ENV=production
APP_DEBUG=false
APP_KEY=
APP_URL=https://${API_HOST}

LOG_CHANNEL=daily
LOG_DAILY_DAYS=7
LOG_LEVEL=warning

DB_CONNECTION=mysql
DB_HOST=localhost
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${pass}

REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

CACHE_STORE=redis
CACHE_DRIVER=redis
SESSION_DRIVER=redis
SESSION_DOMAIN=.${DOMAIN}
SESSION_SECURE_COOKIE=true
QUEUE_CONNECTION=${queue_conn}
SANCTUM_STATEFUL_DOMAINS=${stateful}

MAIL_MAILER=log
FILESYSTEM_DISK=local
ENV
  )
  chown "$APP_USER:$APP_USER" "$env"
  chmod 640 "$env"
  log "Wrote $env (APP_KEY is generated on the first deploy)"
}

# Runtime settings for the Next.js apps (only when absent). The apps can call
# the API at INTERNAL_API_URL without leaving the machine.
lnx_write_next_env() {
  local app env
  for app in admin shop; do
    env="$LNX_APPS_ROOT/$app/shared/.env"
    [[ -e "$env" ]] && continue
    (
      umask 027
      cat >"$env" <<ENV
# Runtime settings for the ${app} app (read by systemd). NEXT_PUBLIC_* values
# are baked in at build time and do not belong here.
INTERNAL_API_URL=http://127.0.0.1:${LNX_INTERNAL_API_PORT}
ENV
    )
    chown "$APP_USER:$APP_USER" "$env"
    chmod 640 "$env"
  done
}

# ── systemd ───────────────────────────────────────────────────────────────────
lnx_setup_systemd() {
  local node_bin
  node_bin="$(command -v node)" || error "node not found."
  local unit_dir="/etc/systemd/system" f
  local -a common=("APP_USER=$APP_USER" "NODE_BIN=$node_bin" "PHP_BIN=$LNX_PHP_BIN")

  lnx_render "$LNX_TEMPLATES/systemd/pulse-next@.service" "$unit_dir/pulse-next@.service" "${common[@]}"
  lnx_render "$LNX_TEMPLATES/systemd/pulse-queue.service" "$unit_dir/pulse-queue.service" "${common[@]}" "QUEUE_MEM=256"
  lnx_render "$LNX_TEMPLATES/systemd/pulse-scheduler.service" "$unit_dir/pulse-scheduler.service" "${common[@]}"
  lnx_render "$LNX_TEMPLATES/systemd/pulse-scheduler.timer" "$unit_dir/pulse-scheduler.timer" "${common[@]}"

  local app port
  for app in shop admin; do
    port="$LNX_SHOP_PORT"
    [[ "$app" == "admin" ]] && port="$LNX_ADMIN_PORT"
    printf 'PORT=%s\nHOSTNAME=127.0.0.1\nNODE_OPTIONS=--max-old-space-size=%s\n' \
      "$port" "$(tune_node_heap "$LNX_RAM_MB" "$app")" >"$LNX_ETC/$app.env"
    mkdir -p "$unit_dir/pulse-next@${app}.service.d"
    printf '[Service]\nMemoryMax=%sM\n' "$(tune_node_memory_max "$LNX_RAM_MB" "$app")" \
      >"$unit_dir/pulse-next@${app}.service.d/limits.conf"
  done
  for f in "$LNX_ETC/shop.env" "$LNX_ETC/admin.env"; do chmod 644 "$f"; done

  systemctl daemon-reload
  systemctl enable pulse-next@shop.service pulse-next@admin.service &>/dev/null
  systemctl restart pulse-next@shop.service
  systemctl restart pulse-next@admin.service
  local extras="pulse-next@shop, pulse-next@admin"
  if [[ "${NO_QUEUE:-0}" == "1" ]]; then
    systemctl disable --now pulse-queue.service &>/dev/null || true
  else
    systemctl enable pulse-queue.service &>/dev/null
    extras+=", pulse-queue"
  fi
  if [[ "${NO_SCHEDULER:-0}" == "1" ]]; then
    systemctl disable --now pulse-scheduler.timer &>/dev/null || true
  else
    systemctl enable pulse-scheduler.timer &>/dev/null
    systemctl start pulse-scheduler.timer || warn "scheduler timer did not start"
    extras+=", pulse-scheduler.timer"
  fi
  log "systemd units installed: ${extras}"
}

lnx_setup_sudoers() {
  local sysctl_bin real
  sysctl_bin="$(command -v systemctl)"
  real="$(readlink -f "$sysctl_bin")"
  local -a bins=("$sysctl_bin")
  [[ "$real" != "$sysctl_bin" ]] && bins+=("$real")
  local tmp b line="" c
  tmp="$(mktemp)"
  for b in "${bins[@]}"; do
    for c in "restart pulse-next@shop.service" "restart pulse-next@admin.service" \
             "restart pulse-queue.service" "start pulse-scheduler.timer" \
             "reload ${PHP_FPM_SVC}.service"; do
      line+="${line:+, }$b $c"
    done
  done
  printf '%s ALL=(root) NOPASSWD: %s\n' "$APP_USER" "$line" >"$tmp"
  if visudo -cf "$tmp" &>/dev/null; then
    install -m 440 -o root -g root "$tmp" /etc/sudoers.d/pulsedeploy
    log "sudoers: $APP_USER may restart only the PulseDeploy services"
  else
    rm -f "$tmp"
    error "Generated sudoers entry failed validation; not installed."
  fi
  rm -f "$tmp"
}

# ── nginx ─────────────────────────────────────────────────────────────────────
lnx_cloudflare_realip() {
  [[ "${CLOUDFLARE:-0}" == "1" ]] || return 0
  local v4 v6 out="$1"
  v4="$(curl -fsS -m 15 https://www.cloudflare.com/ips-v4 2>/dev/null)" || v4=""
  v6="$(curl -fsS -m 15 https://www.cloudflare.com/ips-v6 2>/dev/null)" || v6=""
  if [[ -z "$v4" || -z "$v6" ]]; then
    warn "Could not download Cloudflare's IP ranges; real client IPs are NOT restored. Re-run the installer later."
    return 0
  fi
  {
    echo "# Managed by PulseDeploy - restore the real client IP behind Cloudflare"
    while read -r cidr; do [[ -n "$cidr" ]] && echo "set_real_ip_from $cidr;"; done <<<"$v4"
    while read -r cidr; do [[ -n "$cidr" ]] && echo "set_real_ip_from $cidr;"; done <<<"$v6"
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
  } >"$out"
  log "Cloudflare real-IP configuration written"
}

lnx_setup_nginx() {
  os_pkg_install nginx
  nginx_disable_defaults
  local conf_d="${NGINX_ROOT}/conf.d" tmp
  tmp="$(mktemp)"

  # A LEMP/Node install would also claim port 80; move its file out of the way.
  if [[ -f "$conf_d/pulsedeploy.conf" ]]; then
    mv "$conf_d/pulsedeploy.conf" "$conf_d/pulsedeploy.conf.disabled"
    warn "Moved the previous $conf_d/pulsedeploy.conf aside (pulsedeploy.conf.disabled)"
  fi

  local web_user="www-data"
  [[ "$PKG_MANAGER" == "dnf" ]] && web_user="nginx"
  install -d -o "$web_user" -g "$web_user" /var/cache/nginx /var/cache/nginx/pulse_shop 2>/dev/null ||
    mkdir -p /var/cache/nginx/pulse_shop

  cp "$LNX_TEMPLATES/nginx-http.conf" "$tmp"
  lnx_strip_ipv6_if_absent "$tmp"
  nginx_activate "$tmp" "$conf_d/00-pulsedeploy-http.conf"

  local cf_tmp
  cf_tmp="$(mktemp)"
  lnx_cloudflare_realip "$cf_tmp"
  [[ -s "$cf_tmp" ]] && nginx_activate "$cf_tmp" "$conf_d/01-pulsedeploy-cloudflare.conf"
  rm -f "$cf_tmp"

  # Shared request handling, included by the public and the loopback servers.
  # It lives outside conf.d so nginx does not load it on its own.
  local inc_dir="${NGINX_ROOT}/pulsedeploy" inc="${NGINX_ROOT}/pulsedeploy/api-locations.inc"
  mkdir -p "$inc_dir"
  lnx_render "$LNX_TEMPLATES/nginx-api-locations.inc" "$inc" "PHP_SOCK=$LNX_PHP_SOCK"
  lnx_render "$LNX_TEMPLATES/nginx-api.conf" "$tmp" \
    "HOST=$API_HOST" "ROOT=$LNX_APPS_ROOT/api/current/public" "PHP_SOCK=$LNX_PHP_SOCK" \
    "LOCATIONS=$inc" "INTERNAL_PORT=$LNX_INTERNAL_API_PORT"
  lnx_strip_ipv6_if_absent "$tmp"
  nginx_activate "$tmp" "$conf_d/pulsedeploy-api.conf"

  local app host port names
  for app in shop admin; do
    host="$SHOP_HOST"; port="$LNX_SHOP_PORT"
    [[ "$app" == "admin" ]] && { host="$ADMIN_HOST"; port="$LNX_ADMIN_PORT"; }
    names="$host"
    lnx_render "$LNX_TEMPLATES/nginx-next.conf" "$tmp" \
      "NAME=$app" "PORT=$port" "SERVER_NAMES=$names" \
      "STORAGE_DIR=$LNX_APPS_ROOT/api/shared/storage/app/public"
    if [[ "${SERVE_STORAGE:-0}" == "1" ]]; then
      sed -i 's/^#storage# //' "$tmp"
    else
      sed -i '/^#storage# /d' "$tmp"
    fi
    # Keep only this app's marker lines, drop the other's.
    if [[ "$app" == "shop" ]]; then
      sed -i -e 's/^#shop# //' -e '/^#admin# /d' "$tmp"
    else
      sed -i -e 's/^#admin# //' -e '/^#shop# /d' "$tmp"
    fi
    lnx_strip_ipv6_if_absent "$tmp"
    nginx_activate "$tmp" "$conf_d/pulsedeploy-${app}.conf"
  done

  if [[ "$SHOP_HOST" == "$DOMAIN" ]]; then
    lnx_render "$LNX_TEMPLATES/nginx-redirect.conf" "$tmp" "FROM=www.${DOMAIN}" "TO=$DOMAIN"
    lnx_strip_ipv6_if_absent "$tmp"
    nginx_activate "$tmp" "$conf_d/pulsedeploy-redirect.conf"
    CERT_DOMAINS="$API_HOST $ADMIN_HOST $SHOP_HOST www.${DOMAIN}"
  else
    CERT_DOMAINS="$API_HOST $ADMIN_HOST $SHOP_HOST"
  fi
  rm -f "$tmp"
  open_web_ports
}

# ── operations: CLI, backups, housekeeping ────────────────────────────────────
lnx_install_pulse_cli() {
  install -m 0755 "$SCRIPT_DIR/bin/pulse" /usr/local/bin/pulse
  cat >"$LNX_ETC/pulse.conf" <<CONF
# Written by the PulseDeploy installer; edit values here to change pulse behaviour.
APP_USER=${APP_USER}
API_HOST=${API_HOST}
ADMIN_HOST=${ADMIN_HOST}
SHOP_HOST=${SHOP_HOST}
ADMIN_PORT=${LNX_ADMIN_PORT}
SHOP_PORT=${LNX_SHOP_PORT}
PHP_BIN=${LNX_PHP_BIN}
PHP_FPM_SVC=${PHP_FPM_SVC}
QUEUE_ENABLED=$((1 - ${NO_QUEUE:-0}))
SCHEDULER_ENABLED=$((1 - ${NO_SCHEDULER:-0}))
INTERNAL_API_URL=http://127.0.0.1:${LNX_INTERNAL_API_PORT}
KEEP_RELEASES=5
DB_NAME=${DB_NAME}
BACKUP_DIR=/var/backups/pulsedeploy
BACKUP_KEEP_DAYS=7
BACKUP_FILES=1
# Optional: copy backups off the server with rclone (e.g. b2:bucket/path)
RCLONE_REMOTE=
# Optional: healthchecks.io style ping URL, called after each backup
HEALTHCHECK_URL=
CONF
  chmod 644 "$LNX_ETC/pulse.conf"

  printf 'MAILTO=""\n%d 3 * * * root /usr/local/bin/pulse backup >> /var/log/pulsedeploy-backup.log 2>&1\n' \
    "$((RANDOM % 50 + 5))" >/etc/cron.d/pulsedeploy-backup
  chmod 644 /etc/cron.d/pulsedeploy-backup
  cat >/etc/logrotate.d/pulsedeploy <<'ROTATE'
/var/log/pulsedeploy-backup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
ROTATE
  log "pulse CLI installed; nightly backup scheduled (keeps 7 days, config: $LNX_ETC/pulse.conf)"
}

lnx_housekeeping() {
  # Cap the journal so logs cannot fill a small disk
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=200M\n' >/etc/systemd/journald.conf.d/pulsedeploy.conf
  systemctl restart systemd-journald &>/dev/null || true

  printf 'net.core.somaxconn=1024\nvm.overcommit_memory=1\n' >/etc/sysctl.d/99-pulsedeploy-app.conf
  sysctl -p /etc/sysctl.d/99-pulsedeploy-app.conf &>/dev/null || warn "sysctl values apply after the next reboot"

  # Security updates without manual work (no automatic reboots)
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    os_pkg_install unattended-upgrades
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
      >/etc/apt/apt.conf.d/20auto-upgrades
    log "Automatic security updates enabled"
  fi
}

# ── end-to-end check ──────────────────────────────────────────────────────────
lnx_verify() {
  local pair name host code ok=1 i
  for pair in "api:$API_HOST" "shop:$SHOP_HOST" "admin:$ADMIN_HOST"; do
    name="${pair%%:*}"; host="${pair#*:}"
    code=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
      code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: ${host}" http://127.0.0.1/ 2>/dev/null)" || code=""
      [[ "$code" == "200" ]] && break
      sleep 1
    done
    if [[ "$code" == "200" ]]; then
      log "Health check passed: ${name} (${host}) answered 200"
    else
      warn "Health check FAILED: ${name} (${host}) answered '${code:-no response}'"
      ok=0
    fi
  done
  [[ "$ok" -eq 1 ]]
}

lnx_summary() {
  cat <<EOF

${BOLD}Next steps${RESET}
  1. DNS: point A records for ${API_HOST}, ${ADMIN_HOST} and ${SHOP_HOST}$( [[ "$SHOP_HOST" == "$DOMAIN" ]] && echo " (and www.${DOMAIN})" ) to $(primary_ip)
  2. HTTPS: re-run with the certbot service and --email, or: certbot --nginx $(for d in $CERT_DOMAINS; do printf -- '-d %s ' "$d"; done)
  3. Deploy from CI as ${APP_USER}@server:
       pulse deploy api   --artifact api.tar.gz      (or --git URL)
       pulse deploy admin --artifact admin.tar.gz
       pulse deploy shop  --artifact shop.tar.gz
  4. Day to day: pulse status | pulse logs <target> | pulse rollback <app> | sudo pulse backup
  Laravel config: ${LNX_APPS_ROOT}/api/shared/.env   Backups: /var/backups/pulsedeploy
  Next.js apps can call the API internally at http://127.0.0.1:${LNX_INTERNAL_API_PORT} (loopback only)
EOF
}

install_laravel_next() {
  section "Installing Laravel + Next.js server"
  lnx_defaults
  lnx_default_php
  require_port_free 80 "nginx"

  lnx_create_user
  lnx_setup_php
  lnx_setup_composer

  PHP_SET=1 # PHP_VER now reflects what is installed
  NODE_VER="${NODE_VER:-22}"
  node_install_runtime

  install_mysql
  lnx_tune_mysql

  REDIS_CONN=tcp REDIS_MAXMEM_MB="$(tune_redis_mem "$LNX_RAM_MB")" install_redis

  lnx_create_dirs
  lnx_write_env
  lnx_write_next_env
  lnx_placeholders
  lnx_setup_systemd
  lnx_setup_sudoers
  lnx_setup_nginx
  lnx_install_pulse_cli
  lnx_housekeeping

  lnx_verify || warn "One or more health checks failed; run 'pulse status' and check the logs."
  lnx_summary
  log "Laravel + Next.js server installation complete ✔"
  return 0
}
