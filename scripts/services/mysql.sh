#!/usr/bin/env bash
# Service: MySQL / MariaDB (used by the LEMP and LAMP stacks)
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MYSQL_CLIENT_CNF="/root/.my.cnf"

# Wait until the server answers on its socket (up to ~60 s).
mysql_wait_ready() {
  local i
  for i in $(seq 1 30); do
    if mysqladmin --no-defaults ping &>/dev/null || mysqladmin ping &>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

mysql_is_mariadb() { [[ "$(mysql --version 2>/dev/null)" == *[Mm]aria[Dd][Bb]* ]]; }

install_mysql() {
  info "Installing database server..."
  # Distribution packages only: predictable, signed, and no third-party
  # release RPM/DEB URLs that go stale.
  local -a candidates
  case "$OS_ID" in
    ubuntu)           candidates=(mysql-server mariadb-server) ;;
    debian)           candidates=(mariadb-server default-mysql-server mysql-server) ;;
    amzn)             candidates=(mariadb1011-server mariadb105-server mariadb-server mysql-server) ;;
    *)                candidates=(mysql-server mariadb-server) ;;
  esac
  # Versioned MariaDB packages conflict with each other: keep one that is already installed.
  if [[ "$OS_ID" == "amzn" ]]; then
    local have=""
    have="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -E '^mariadb[0-9]*-server$' | head -n 1)" || have=""
    if [[ -n "$have" ]]; then candidates=("$have"); fi
  fi
  pkg_install_first "${candidates[@]}" ||
    error "Could not install a database server (tried: ${candidates[*]})."
  log "Installed database package: $PKG_INSTALLED"

  local svc
  svc="$(svc_first_existing mysql mysqld mariadb)" ||
    error "No MySQL/MariaDB systemd unit found after installing $PKG_INSTALLED."
  os_svc_enable "$svc"
  mysql_wait_ready || error "Database server '$svc' did not become ready within 60s (systemctl status $svc)."
  log "Database server running: $svc"

  secure_mysql
  create_database
  return 0
}

# Apply <password> to root@localhost with password authentication forced.
# A bare `IDENTIFIED BY` keeps the account's current plugin, and root ships
# with auth_socket, which ignores passwords - so name the plugin explicitly.
# SQL goes over stdin, never the command line, so it can't show up in `ps`.
_mysql_set_root_password() {
  local pass="$1"
  if mysql_is_mariadb; then
    mysql --no-defaults -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${pass}');
SQL
  elif ! mysql --no-defaults -uroot <<SQL 2>/dev/null
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${pass}';
SQL
  then
    mysql --no-defaults -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${pass}';
SQL
  fi
  return 0
}

# Give root a real random password and remove insecure defaults, then store
# the credentials in /root/.my.cnf, only after the change is verified.
secure_mysql() {
  info "Securing database server..."

  local saved_pass=""
  if [[ -f "$MYSQL_CLIENT_CNF" ]]; then
    saved_pass="$(awk -F= '$1 == "password" { v = substr($0, 10); gsub(/^"|"$/, "", v); print v; exit }' "$MYSQL_CLIENT_CNF")" || saved_pass=""
  fi
  local cnf_works=0 socket_open=0
  mysql --defaults-file="$MYSQL_CLIENT_CNF" -e 'SELECT 1' &>/dev/null && cnf_works=1
  # Fresh installs let the OS root user in over the local socket, no password.
  mysql --no-defaults -uroot -e 'SELECT 1' &>/dev/null && socket_open=1

  # Already done: saved credentials work AND a password is really required.
  if [[ -n "$saved_pass" && "$cnf_works" -eq 1 && "$socket_open" -eq 0 ]]; then
    log "MySQL root credentials in $MYSQL_CLIENT_CNF already work - leaving them unchanged"
    return 0
  fi
  if [[ "$socket_open" -eq 0 ]]; then
    warn "Cannot log in to the database as root (no working credentials and no socket auth)."
    warn "Skipping hardening. Secure it manually with: mysql_secure_installation"
    return 0
  fi

  local pass
  if [[ -n "$saved_pass" && "$cnf_works" -eq 1 ]]; then
    pass="$saved_pass" # enforce the password the admin already has saved
    info "Enforcing the root password already saved in $MYSQL_CLIENT_CNF"
  else
    pass="$(generate_password 24)"
  fi
  # Cleanup runs first: once the password is set, root needs it to connect.
  mysql --no-defaults -uroot <<SQL
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS 'root'@'%';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
  _mysql_set_root_password "$pass"

  if [[ "$pass" != "$saved_pass" ]]; then
    if [[ -e "$MYSQL_CLIENT_CNF" ]]; then
      cp -a "$MYSQL_CLIENT_CNF" "${MYSQL_CLIENT_CNF}.pulsedeploy.bak"
      warn "Existing $MYSQL_CLIENT_CNF backed up to ${MYSQL_CLIENT_CNF}.pulsedeploy.bak"
    fi
    (
      umask 077
      printf '[client]\nuser=root\npassword="%s"\n' "$pass" >"$MYSQL_CLIENT_CNF"
    )
    chmod 600 "$MYSQL_CLIENT_CNF"
  fi

  if mysql --no-defaults -uroot -e 'SELECT 1' &>/dev/null; then
    error "Root can still log in without a password after hardening - the server ignored the authentication change."
  fi
  if ! mysql --defaults-file="$MYSQL_CLIENT_CNF" -e 'SELECT 1' &>/dev/null; then
    error "Root password was changed but the saved credentials in $MYSQL_CLIENT_CNF do not work. Recover with: sudo mysqld_safe --skip-grant-tables (see MySQL docs)."
  fi
  log "MySQL secured: root requires the password saved in $MYSQL_CLIENT_CNF (chmod 600)"
  return 0
}

# mysql_saved_password <user> - password saved for that user in /root/.my.cnf
mysql_saved_password() {
  awk -v sec="[client_$1]" '
    $0 == sec { f = 1; next }
    /^\[/ { f = 0 }
    f && /^password=/ { v = substr($0, 10); gsub(/^"|"$/, "", v); print v; exit }
  ' "$MYSQL_CLIENT_CNF" 2>/dev/null || true
}

# For apps that create one database per tenant with their own DB user: allow
# that user everything on databases named <prefix>*. "_" is a wildcard in grant
# patterns, so it is escaped to match literally.
mysql_grant_tenant_prefix() {
  local user="$1" prefix="${TENANT_DB_PREFIX:-}"
  [[ -n "$prefix" ]] || return 0
  [[ "$prefix" =~ ^[A-Za-z0-9_]{2,40}$ ]] || error "Invalid tenant database prefix '$prefix'."
  local pattern="${prefix//_/\\_}%"
  mysql -e "GRANT ALL PRIVILEGES ON \`${pattern}\`.* TO '${user}'@'localhost'; FLUSH PRIVILEGES;"
  log "Database user ${user} may create and manage databases named ${prefix}*"
}

# Create DB_NAME and (optionally) DB_USER with a random password.
create_database() {
  [[ -z "${DB_NAME:-}" && -z "${DB_USER:-}" ]] && return 0
  if [[ -z "${DB_NAME:-}" ]]; then
    warn "--db-user needs --db-name; skipping database/user creation."
    return 0
  fi
  valid_db_name "$DB_NAME" || error "Invalid database name '$DB_NAME' (use letters, digits, underscore; max 64)."
  [[ -z "${DB_USER:-}" ]] || valid_db_user "$DB_USER" || error "Invalid database user '$DB_USER' (use letters, digits, underscore; max 32)."

  if ! mysql -e 'SELECT 1' &>/dev/null; then
    warn "Cannot connect to the database with the saved root credentials; skipping database creation."
    return 0
  fi

  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  log "Database ready: $DB_NAME"

  [[ -n "${DB_USER:-}" ]] || return 0

  local exists
  exists="$(mysql -N -e "SELECT COUNT(*) FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost';")"
  if [[ "$exists" != "0" ]]; then
    warn "Database user '${DB_USER}'@'localhost' already exists - password left unchanged."
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
    mysql_grant_tenant_prefix "$DB_USER"
    return 0
  fi

  local pass
  pass="$(generate_password 24)"
  mysql <<SQL
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  (
    umask 077
    printf '\n[client_%s]\nuser=%s\npassword="%s"\ndatabase=%s\n' \
      "$DB_USER" "$DB_USER" "$pass" "$DB_NAME" >>"$MYSQL_CLIENT_CNF"
  )
  log "Database user created: $DB_USER - credentials in $MYSQL_CLIENT_CNF (group [client_${DB_USER}])"
  mysql_grant_tenant_prefix "$DB_USER"
  return 0
}
