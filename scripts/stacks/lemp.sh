#!/usr/bin/env bash
# Stack: LEMP — Nginx + PHP-FPM + MySQL

install_lemp() {
  section "Installing LEMP Stack"

  # ── PHP version ────────────────────────────────────────────────────────────
  echo -e "\nAvailable PHP versions:"
  echo "  1) PHP 8.1   2) PHP 8.2 (recommended)   3) PHP 8.3"
  read -rp "$(echo -e "${CYAN}Choose PHP version [1-3, default 2]:${RESET} ")" PHP_CHOICE
  case "${PHP_CHOICE:-2}" in
    1) PHP_VER="8.1" ;; 3) PHP_VER="8.3" ;; *) PHP_VER="8.2" ;;
  esac
  log "PHP version: $PHP_VER"

  # ── Nginx ──────────────────────────────────────────────────────────────────
  info "Installing Nginx..."
  os_pkg_install nginx
  os_svc_enable nginx
  cp "$SCRIPT_DIR/config/nginx/default.conf" /etc/nginx/conf.d/default.conf 2>/dev/null || true
  nginx -t && log "Nginx installed and config validated"

  # ── PHP-FPM ────────────────────────────────────────────────────────────────
  info "Installing PHP $PHP_VER + extensions..."
  os_get_php_repo 2>/dev/null || true
  os_pkg_install \
    "php${PHP_VER}" "php${PHP_VER}-fpm" \
    "php${PHP_VER}-mysql" "php${PHP_VER}-curl" \
    "php${PHP_VER}-gd" "php${PHP_VER}-mbstring" \
    "php${PHP_VER}-xml" "php${PHP_VER}-zip" \
    "php${PHP_VER}-bcmath" "php${PHP_VER}-intl" \
    "php${PHP_VER}-redis" "php${PHP_VER}-opcache"

  PHP_FPM_SVC="php${PHP_VER}-fpm"
  os_svc_enable "$PHP_FPM_SVC"
  log "PHP $PHP_VER-FPM installed"

  # ── Wire Nginx → PHP-FPM ───────────────────────────────────────────────────
  local SOCK="/var/run/php/php${PHP_VER}-fpm.sock"
  sed -i "s|PHP_FPM_SOCK|${SOCK}|g" /etc/nginx/conf.d/default.conf 2>/dev/null || true
  nginx -s reload 2>/dev/null || true

  # ── MySQL ──────────────────────────────────────────────────────────────────
  info "Installing MySQL..."
  os_get_mysql_repo 2>/dev/null || true
  os_pkg_install mysql-server 2>/dev/null || os_pkg_install mariadb-server
  os_svc_enable mysql 2>/dev/null || os_svc_enable mariadb
  log "MySQL installed"

  # ── Secure MySQL ───────────────────────────────────────────────────────────
  info "Running MySQL secure installation..."
  MYSQL_ROOT_PASS=$(generate_password)
  mysql --user=root <<EOF 2>/dev/null || true
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
  echo "[client]
user=root
password=${MYSQL_ROOT_PASS}" > /root/.my.cnf
  chmod 600 /root/.my.cnf
  log "MySQL secured. Root password saved to /root/.my.cnf"

  # ── PHP info test page ─────────────────────────────────────────────────────
  echo "<?php phpinfo();" > /var/www/html/info.php
  log "PHP info page: http://$(hostname -I | awk '{print $1}')/info.php"
  warn "Remember to delete /var/www/html/info.php after testing!"

  log "LEMP stack installation complete ✔"
}

generate_password() {
  tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c 20
}