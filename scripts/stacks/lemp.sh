#!/usr/bin/env bash
# Stack: LEMP — Nginx + PHP-FPM + MySQL/MariaDB
# shellcheck source=scripts/lib/web.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/web.sh"
# shellcheck source=scripts/services/mysql.sh
source "$(dirname "${BASH_SOURCE[0]}")/../services/mysql.sh"

install_lemp() {
  section "Installing LEMP Stack"
  PHP_VER="${PHP_VER:-8.2}"

  require_port_free 80 "nginx"

  # ── Nginx ──────────────────────────────────────────────────────────────────
  info "Installing Nginx..."
  os_pkg_install nginx
  nginx_disable_defaults

  # ── PHP-FPM ────────────────────────────────────────────────────────────────
  info "Installing PHP $PHP_VER + extensions..."
  php_install_packages fpm
  php_configure_fpm_pool
  svc_restart "$PHP_FPM_SVC"
  log "PHP $PHP_VER-FPM running ($PHP_FPM_SVC)"

  # ── Wire Nginx → PHP-FPM ───────────────────────────────────────────────────
  local rendered
  rendered="$(mktemp)"
  nginx_render "$SCRIPT_DIR/config/nginx/default.conf" "$rendered"
  sed -i "s|PHP_FPM_SOCK|${PHP_FPM_SOCK}|g" "$rendered"
  nginx_activate "$rendered"
  rm -f "$rendered"
  ensure_docroot
  open_web_ports

  # ── Database ───────────────────────────────────────────────────────────────
  install_mysql

  # ── Verify end to end ──────────────────────────────────────────────────────
  web_check_php || warn "LEMP installed, but the PHP health check failed — see messages above."
  log "LEMP stack installation complete ✔"
  return 0
}
