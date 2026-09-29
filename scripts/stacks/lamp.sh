#!/usr/bin/env bash
# Stack: LAMP — Apache + PHP + MySQL/MariaDB
# shellcheck source=scripts/lib/web.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/web.sh"
# shellcheck source=scripts/services/mysql.sh
source "$(dirname "${BASH_SOURCE[0]}")/../services/mysql.sh"

install_lamp() {
  section "Installing LAMP Stack"
  PHP_VER="${PHP_VER:-8.2}"

  local apache_svc="apache2" apache_conf="/etc/apache2/sites-available/000-default.conf"
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    apache_svc="httpd"
    apache_conf="/etc/httpd/conf.d/pulsedeploy.conf"
  fi
  require_port_free 80 "apache2|httpd"

  # ── Apache ─────────────────────────────────────────────────────────────────
  info "Installing Apache..."
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    os_pkg_install apache2
  else
    os_pkg_install httpd mod_ssl
  fi

  # ── PHP ────────────────────────────────────────────────────────────────────
  info "Installing PHP $PHP_VER + extensions..."
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    php_install_packages apache
    # Only one PHP module may be loaded at a time.
    local m
    for m in /etc/apache2/mods-enabled/php*.load; do
      [[ -e "$m" ]] || continue
      m="$(basename "$m" .load)"
      [[ "$m" == "php${PHP_VER}" ]] || a2dismod "$m" >/dev/null
    done
    a2enmod "php${PHP_VER}" >/dev/null
    a2enmod rewrite ssl headers expires deflate >/dev/null
  else
    # On RHEL family Apache talks to PHP-FPM (php.conf ships with php-fpm).
    php_install_packages fpm
    php_configure_fpm_pool
    svc_restart "$PHP_FPM_SVC"
  fi

  # ── Apache vhost ───────────────────────────────────────────────────────────
  local rendered
  rendered="$(mktemp)"
  cp "$SCRIPT_DIR/config/apache/vhost.conf" "$rendered"
  if [[ -n "${DOMAIN:-}" ]]; then
    sed -i "s|ServerName   localhost|ServerName   ${DOMAIN}|" "$rendered"
  fi
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    # shellcheck disable=SC2016  # ${APACHE_LOG_DIR} is literal text in the template
    sed -i -e 's|\${APACHE_LOG_DIR}/error.log|logs/error_log|' \
           -e 's|\${APACHE_LOG_DIR}/access.log|logs/access_log|' "$rendered"
  fi
  backup_file "$apache_conf"
  cp "$rendered" "$apache_conf"
  rm -f "$rendered"
  ensure_docroot

  if ! apachectl configtest; then
    if [[ -e "${apache_conf}.pulsedeploy.bak" ]]; then cp -a "${apache_conf}.pulsedeploy.bak" "$apache_conf"; else rm -f "$apache_conf"; fi
    error "Generated Apache configuration is invalid (see output above); it was rolled back."
  fi
  svc_restart "$apache_svc"
  log "Apache running with PHP $PHP_VER"
  open_web_ports

  # ── Database ───────────────────────────────────────────────────────────────
  install_mysql

  # ── Verify end to end ──────────────────────────────────────────────────────
  web_check_php || warn "LAMP installed, but the PHP health check failed — see messages above."
  log "LAMP stack installation complete ✔"
  return 0
}
