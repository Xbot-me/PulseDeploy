#!/usr/bin/env bash
# Stack: LAMP — Apache + PHP + MySQL

install_lamp() {
  section "Installing LAMP Stack"

  # ── PHP version ────────────────────────────────────────────────────────────
  echo -e "\nAvailable PHP versions:"
  echo "  1) PHP 8.1   2) PHP 8.2 (recommended)   3) PHP 8.3"
  read -rp "$(echo -e "${CYAN}Choose PHP version [1-3, default 2]:${RESET} ")" PHP_CHOICE
  case "${PHP_CHOICE:-2}" in
    1) PHP_VER="8.1" ;; 3) PHP_VER="8.3" ;; *) PHP_VER="8.2" ;;
  esac
  log "PHP version: $PHP_VER"

  # ── Apache ─────────────────────────────────────────────────────────────────
  info "Installing Apache..."
  case "$PKG_MANAGER" in
    apt) os_pkg_install apache2 ;;
    dnf) os_pkg_install httpd ;;
  esac
  local APACHE_SVC="apache2"; [[ "$PKG_MANAGER" == "dnf" ]] && APACHE_SVC="httpd"
  os_svc_enable "$APACHE_SVC"

  # Enable required Apache modules (apt only)
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    a2enmod rewrite ssl headers expires deflate
  fi

  # Copy Apache vhost config
  cp "$SCRIPT_DIR/config/apache/vhost.conf" \
    "/etc/apache2/sites-available/000-default.conf" 2>/dev/null || true
  log "Apache installed"

  # ── PHP ────────────────────────────────────────────────────────────────────
  info "Installing PHP $PHP_VER + extensions..."
  os_get_php_repo 2>/dev/null || true

  case "$PKG_MANAGER" in
    apt)
      os_pkg_install \
        "php${PHP_VER}" "libapache2-mod-php${PHP_VER}" \
        "php${PHP_VER}-mysql" "php${PHP_VER}-curl" \
        "php${PHP_VER}-gd" "php${PHP_VER}-mbstring" \
        "php${PHP_VER}-xml" "php${PHP_VER}-zip" \
        "php${PHP_VER}-bcmath" "php${PHP_VER}-intl" \
        "php${PHP_VER}-redis" "php${PHP_VER}-opcache"
      ;;
    dnf)
      os_pkg_install \
        "php" "php-mysqlnd" "php-curl" "php-gd" \
        "php-mbstring" "php-xml" "php-zip" \
        "php-bcmath" "php-intl" "php-opcache"
      ;;
  esac

  service "$APACHE_SVC" restart
  log "PHP $PHP_VER installed with Apache mod"

  # ── MySQL ──────────────────────────────────────────────────────────────────
  info "Installing MySQL..."
  os_get_mysql_repo 2>/dev/null || true
  os_pkg_install mysql-server 2>/dev/null || os_pkg_install mariadb-server
  os_svc_enable mysql 2>/dev/null || os_svc_enable mariadb

  MYSQL_ROOT_PASS=$(tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c 20)
  mysql --user=root <<EOF 2>/dev/null || true
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF
  echo "[client]
user=root
password=${MYSQL_ROOT_PASS}" > /root/.my.cnf
  chmod 600 /root/.my.cnf
  log "MySQL installed and secured. Root credentials in /root/.my.cnf"

  # ── PHP info test page ─────────────────────────────────────────────────────
  echo "<?php phpinfo();" > /var/www/html/info.php
  log "PHP info page: http://$(hostname -I | awk '{print $1}')/info.php"
  warn "Remember to delete /var/www/html/info.php after testing!"

  log "LAMP stack installation complete ✔"
}