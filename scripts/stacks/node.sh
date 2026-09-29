#!/usr/bin/env bash
# Stack: Node.js + Nginx reverse proxy + PM2
# shellcheck source=scripts/lib/web.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/web.sh"

# Install Node.js from NodeSource and verify the major version.
node_install_runtime() {
  NODE_VER="${NODE_VER:-22}"
  case "$NODE_VER" in
    18|20) warn "Node.js $NODE_VER is end-of-life upstream - consider --node 22 or 24." ;;
  esac
  if [[ "$OS_ID" == "amzn" && "$OS_VERSION" == "2" ]]; then
    error "Amazon Linux 2 (glibc 2.26) cannot run Node.js 18+. Use Amazon Linux 2023."
  fi
  # Reuse an existing install of the requested major version.
  local existing
  if existing="$(node -v 2>/dev/null)" && [[ "$existing" == "v${NODE_VER}."* ]]; then
    log "Node.js ${existing} already installed"
    return 0
  fi

  # ── Install Node via NodeSource ────────────────────────────────────────────
  info "Adding NodeSource repository for Node.js ${NODE_VER}.x ..."
  local setup_url="https://deb.nodesource.com/setup_${NODE_VER}.x" setup
  [[ "$PKG_MANAGER" == "dnf" ]] && setup_url="https://rpm.nodesource.com/setup_${NODE_VER}.x"
  setup="$(mktemp)"
  download "$setup_url" "$setup"
  [[ -s "$setup" ]] || error "NodeSource setup script downloaded empty from $setup_url"
  bash "$setup"
  rm -f "$setup"
  os_pkg_install nodejs

  local actual
  actual="$(node -v 2>/dev/null)" || error "node is not on PATH after installing nodejs."
  [[ "$actual" == "v${NODE_VER}."* ]] ||
    error "Expected Node.js v${NODE_VER}.x but found ${actual}. Another nodejs source is taking precedence."
  log "Node.js ${actual} installed"
  return 0
}

install_node() {
  section "Installing Node.js Stack"
  NODE_VER="${NODE_VER:-22}"
  APP_PORT="${APP_PORT:-3000}"

  require_port_free 80 "nginx"
  node_install_runtime

  # ── PM2 ───────────────────────────────────────────────────────────────────
  info "Installing PM2 process manager..."
  retry 3 5 npm install -g pm2
  if has_systemd; then
    pm2 startup systemd -u root --hp /root >/dev/null ||
      warn "pm2 startup failed - apps will not auto-start on reboot (run 'pm2 startup' manually)."
  fi
  log "PM2 installed - use 'pm2 start app.js --name myapp' to launch"

  # ── Nginx reverse proxy ────────────────────────────────────────────────────
  info "Installing Nginx as reverse proxy..."
  os_pkg_install nginx
  nginx_disable_defaults

  local server_name="_"
  [[ -n "${DOMAIN:-}" ]] && server_name="$DOMAIN"
  local rendered
  rendered="$(mktemp)"
  cat >"$rendered" <<NGINX
# Managed by PulseDeploy - Node.js reverse proxy
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      '';
}

upstream node_app {
    server 127.0.0.1:${APP_PORT};
    keepalive 64;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${server_name};

    access_log /var/log/nginx/node-app-access.log;
    error_log  /var/log/nginx/node-app-error.log;

    server_tokens off;
    client_max_body_size 64M;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        proxy_pass         http://node_app;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }

    # Static files served directly (only if the directory exists)
    location /static/ {
        alias /var/www/app/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Never serve dotfiles (.env, .git, …) except ACME challenges
    location ~ /\.(?!well-known) {
        deny all;
        return 404;
    }
}
NGINX
  # nginx_render tailors IPv6 for us; server_name is already rendered above.
  nginx_render "$rendered" "${rendered}.final"
  nginx_activate "${rendered}.final"
  rm -f "$rendered" "${rendered}.final"
  open_web_ports

  # SELinux blocks Nginx→upstream connections unless this boolean is set.
  if declare -f selinux_enforcing &>/dev/null && selinux_enforcing; then
    setsebool -P httpd_can_network_connect 1 && log "SELinux: httpd_can_network_connect enabled"
  fi
  log "Nginx reverse proxy configured → localhost:${APP_PORT}"

  # ── Sample app (never overwrites an existing app) ──────────────────────────
  mkdir -p /var/www/app
  if [[ ! -f /var/www/app/app.js ]]; then
    cat >/var/www/app/app.js <<JS
const http = require('http');
const PORT = process.env.PORT || ${APP_PORT};
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Server is running - replace this with your app!\\n');
}).listen(PORT, '127.0.0.1', () => console.log(\`Listening on port \${PORT}\`));
JS
  fi

  if pm2 describe node-app &>/dev/null; then
    info "PM2 process 'node-app' already exists - leaving it running"
  else
    pm2 start /var/www/app/app.js --name "node-app"
  fi
  pm2 save >/dev/null

  web_check_http 80 || warn "Node stack installed, but nothing answered on port 80 - check 'pm2 logs node-app'."
  log "Node.js + Nginx + PM2 stack complete ✔"
  return 0
}
