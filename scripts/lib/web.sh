#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - web-stack helpers shared by the LEMP / LAMP / Node stacks
# =============================================================================
# shellcheck disable=SC2034  # Variables here are consumed by sourcing scripts
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DOCROOT="${DOCROOT:-/var/www/html}"
NGINX_ROOT="${NGINX_ROOT:-/etc/nginx}"
NGINX_SITE="${NGINX_ROOT}/conf.d/pulsedeploy.conf"

# ── PHP layout per distro family ──────────────────────────────────────────────
# Sets PHP_FPM_SVC PHP_FPM_BIN PHP_FPM_SOCK PHP_POOL_CONF and PHP_INI_DIRS[]
php_layout() {
  local v="${PHP_VER:-8.2}"
  PHP_INI_DIRS=()
  case "$PKG_MANAGER" in
    apt)
      PHP_FPM_SVC="php${v}-fpm"
      PHP_FPM_BIN="php-fpm${v}"
      PHP_FPM_SOCK="/run/php/php${v}-fpm.sock"
      PHP_POOL_CONF="/etc/php/${v}/fpm/pool.d/www.conf"
      local d
      for d in "/etc/php/${v}/fpm/conf.d" "/etc/php/${v}/apache2/conf.d"; do
        [[ -d "$d" ]] && PHP_INI_DIRS+=("$d")
      done
      ;;
    dnf)
      PHP_FPM_SVC="php-fpm"
      PHP_FPM_BIN="php-fpm"
      PHP_FPM_SOCK="/run/php-fpm/www.sock"
      PHP_POOL_CONF="/etc/php-fpm.d/www.conf"
      [[ -d /etc/php.d ]] && PHP_INI_DIRS+=("/etc/php.d")
      ;;
  esac
  return 0
}

# RPM package-name prefix: Amazon Linux 2023 ships versioned packages
# (php8.2-fpm); Remi / AL2 / module streams use the plain "php-" names.
php_rpm_prefix() {
  if [[ "$OS_ID" == "amzn" && "$OS_VERSION" == "2023" ]]; then
    printf 'php%s' "${PHP_VER:-8.2}"
  else
    printf 'php'
  fi
}

# Make the requested PHP version installable, adding a third-party repo only
# when the distribution's own archive does not carry it.
php_ensure_repo() {
  local v="${PHP_VER:-8.2}"
  case "$PKG_MANAGER" in
    apt)
      if pkg_available "php${v}-cli"; then
        info "PHP ${v} is available from the distribution archive"
      else
        info "PHP ${v} not in the distribution archive - adding the PHP repository"
        os_get_php_repo
        pkg_available "php${v}-cli" ||
          error "PHP ${v} is not available for $OS_ID $OS_VERSION even after adding the PHP repository. Try --php with another version."
      fi
      ;;
    dnf) os_get_php_repo ;;
  esac
  return 0
}

# php_install_packages fpm|apache
php_install_packages() {
  local mode="$1" v="${PHP_VER:-8.2}"
  php_ensure_repo
  case "$PKG_MANAGER" in
    apt)
      local -a req=("php${v}-cli" "php${v}-mysql" "php${v}-curl" "php${v}-gd"
        "php${v}-mbstring" "php${v}-xml" "php${v}-zip" "php${v}-bcmath" "php${v}-intl")
      if [[ "$mode" == "apache" ]]; then
        req+=("libapache2-mod-php${v}")
      else
        req+=("php${v}-fpm")
      fi
      pkg_install_required "${req[@]}"
      pkg_install_optional "php${v}-opcache"
      if pkg_available "php${v}-redis"; then
        pkg_install_optional "php${v}-redis"
      else
        pkg_install_optional php-redis
      fi
      ;;
    dnf)
      local p
      p="$(php_rpm_prefix)"
      pkg_install_required "${p}-fpm" "${p}-cli" "${p}-mysqlnd" "${p}-gd" "${p}-mbstring" \
        "${p}-xml" "${p}-intl" "${p}-bcmath"
      pkg_install_optional "${p}-opcache"
      pkg_install_first "${p}-pecl-zip" "${p}-zip" || warn "No PHP zip extension package found - skipping."
      pkg_install_first "${p}-pecl-redis6" "${p}-pecl-redis5" "${p}-redis" ||
        warn "No PHP redis extension package found - skipping."
      ;;
  esac
  # Make the version we report match what is really installed. Ask the
  # version-specific binary: plain `php` may be another installed version.
  local actual php_bin="php"
  [[ "$PKG_MANAGER" == "apt" ]] && php_bin="php${v}"
  actual="$("$php_bin" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null)" ||
    error "PHP was installed but '$php_bin' does not run - check the package installation output above."
  if [[ -n "$actual" && "$actual" != "$v" ]]; then
    warn "Requested PHP ${v} but PHP ${actual} is installed - continuing with ${actual}."
    PHP_VER="$actual"
  fi
  php_layout
  return 0
}

# Point PHP-FPM at the socket the web server expects (RHEL family; Debian's
# packaging already does the right thing).
php_configure_fpm_pool() {
  php_layout
  [[ -f "$PHP_POOL_CONF" ]] || return 0
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    backup_file "$PHP_POOL_CONF"
    mkdir -p /run/php-fpm
    conf_set "$PHP_POOL_CONF" "listen" "$PHP_FPM_SOCK" " = "
    conf_set "$PHP_POOL_CONF" "listen.acl_users" "apache,nginx" " = "
  fi
  return 0
}

# ── Web server helpers ────────────────────────────────────────────────────────
# Create the docroot and, if it has no index page, a small placeholder so a
# brand-new server answers 200 instead of 403.
ensure_docroot() {
  mkdir -p "$DOCROOT"
  # Only the names the server config serves count (not Debian's
  # index.nginx-debian.html, which nginx's `index` directive ignores).
  if [[ ! -e "$DOCROOT/index.php" && ! -e "$DOCROOT/index.html" && ! -e "$DOCROOT/index.htm" ]]; then
    cat >"$DOCROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Server ready</title></head>
<body style="font-family:sans-serif;max-width:40rem;margin:4rem auto">
<h1>Server ready</h1>
<p>Provisioned with PulseDeploy. Upload your site to <code>/var/www/html</code> and delete this file.</p>
</body></html>
HTML
  fi
  return 0
}

# Remove the distribution's default catch-all server so ours can answer on :80.
nginx_disable_defaults() {
  # Debian/Ubuntu: default site symlink
  rm -f "${NGINX_ROOT}/sites-enabled/default"

  # RHEL family: strip the stock `server { … }` from the http block of nginx.conf
  local conf="${NGINX_ROOT}/nginx.conf"
  if [[ "$PKG_MANAGER" == "dnf" && -f "$conf" ]] &&
     awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s !~ /^#/ && $0 ~ /^[ \t]*server[ \t]*\{/) f=1 } END { exit !f }' "$conf"; then
    backup_file "$conf"
    local tmp
    tmp="$(mktemp)"
    awk '
      {
        raw = $0; s = raw; sub(/^[ \t]+/, "", s)
        if (s ~ /^#/) { if (!skipping) print raw; next }
        opens = gsub(/\{/, "{", s); closes = gsub(/\}/, "}", s)
        if (!skipping && depth == 1 && raw ~ /^[ \t]*server[ \t]*\{/) {
          skipping = 1
          print "    # default server block removed by PulseDeploy (see conf.d/pulsedeploy.conf)"
        }
        if (!skipping) print raw
        depth += opens - closes
        if (skipping && depth == 1) skipping = 0
      }
    ' "$conf" >"$tmp"
    cat "$tmp" >"$conf"
    rm -f "$tmp"
    info "Removed the stock default server block from $conf"
  fi
  return 0
}

# nginx_activate <rendered-config-file>
# Installs the config, validates it with `nginx -t` and rolls back on failure.
nginx_activate() {
  local src="$1"
  backup_file "$NGINX_SITE"
  local previous=""
  if [[ -f "$NGINX_SITE" ]]; then
    previous="$(mktemp)"
    cp -a "$NGINX_SITE" "$previous"
  fi
  cp "$src" "$NGINX_SITE"
  if ! nginx -t; then
    if [[ -n "$previous" ]]; then cp -a "$previous" "$NGINX_SITE"; else rm -f "$NGINX_SITE"; fi
    [[ -n "$previous" ]] && rm -f "$previous"
    error "Generated nginx configuration is invalid (see output above); it was rolled back."
  fi
  [[ -n "$previous" ]] && rm -f "$previous"
  svc_restart nginx
  log "Nginx configured: $NGINX_SITE"
  return 0
}

# Tailor a shipped nginx template: server_name and IPv6 availability.
nginx_render() {
  local tpl="$1" out="$2"
  cp "$tpl" "$out"
  if [[ -n "${DOMAIN:-}" ]]; then
    sed -i "s|server_name _;|server_name ${DOMAIN};|" "$out"
  fi
  local ipv6_off=0
  [[ -e /proc/net/if_inet6 ]] || ipv6_off=1
  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == "1" ]] && ipv6_off=1
  if [[ "$ipv6_off" -eq 1 ]]; then
    sed -i '/listen \[::\]/d' "$out"
  fi
  return 0
}

# ── Health checks ─────────────────────────────────────────────────────────────
# web_check_php - drops a throw-away PHP file, requests it over HTTP, removes
# it. Proves web server → PHP end to end without leaving phpinfo() exposed.
web_check_php() {
  local name token url body=""
  token="$(generate_password 12)"
  name="pulsedeploy-check-${token}.php"
  ensure_docroot
  printf '<?php echo "PULSEDEPLOY_OK_%s";\n' "$token" >"$DOCROOT/$name"
  chmod 644 "$DOCROOT/$name"
  url="http://127.0.0.1/${name}"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    body="$(curl -fsS -m 5 "$url" 2>/dev/null)" || body=""
    [[ "$body" == "PULSEDEPLOY_OK_${token}" ]] && break
    sleep 1
  done
  rm -f "$DOCROOT/$name"
  if [[ "$body" == "PULSEDEPLOY_OK_${token}" ]]; then
    log "Health check passed: web server is executing PHP (${url%/*}/)"
    return 0
  fi
  warn "Health check FAILED: http://127.0.0.1/ did not execute PHP."
  warn "Check: nginx/apache error log, and 'systemctl status ${PHP_FPM_SVC:-php-fpm}'."
  return 1
}

# web_check_http <port> - expects any 2xx/3xx answer from the local port
web_check_http() {
  local port="$1" code="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null)" || code=""
    [[ "$code" =~ ^[23] ]] && break
    sleep 1
  done
  if [[ "$code" =~ ^[23] ]]; then
    log "Health check passed: http://127.0.0.1:${port}/ answered HTTP ${code}"
    return 0
  fi
  warn "Health check FAILED: http://127.0.0.1:${port}/ answered '${code:-no response}'."
  return 1
}

# ── Port ownership ────────────────────────────────────────────────────────────
# require_port_free <port> <allowed-process-regex>
# Fails early with a clear message when something else already listens there
# (e.g. Apache pre-installed on the image while installing Nginx).
require_port_free() {
  local port="$1" allowed="$2" listeners
  command -v ss &>/dev/null || return 0
  listeners="$(ss -ltnpH "sport = :${port}" 2>/dev/null || true)"
  [[ -z "$listeners" ]] && return 0
  if grep -Eq "\"(${allowed})\"" <<<"$listeners"; then
    return 0
  fi
  echo "$listeners" >&2
  error "Port ${port} is already in use by another service (shown above). Stop or remove it, then re-run."
}
