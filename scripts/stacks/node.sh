#!/usr/bin/env bash
# Stack: Node.js + Nginx reverse proxy + PM2

install_node() {
  section "Installing Node.js Stack"

  # ── Node version ───────────────────────────────────────────────────────────
  echo -e "\nAvailable Node.js LTS versions:"
  echo "  1) Node 18 LTS   2) Node 20 LTS (recommended)   3) Node 22 LTS"
  read -rp "$(echo -e "${CYAN}Choose Node version [1-3, default 2]:${RESET} ")" NODE_CHOICE
  case "${NODE_CHOICE:-2}" in
    1) NODE_VER="18" ;; 3) NODE_VER="22" ;; *) NODE_VER="20" ;;
  esac
  log "Node.js version: $NODE_VER"

  # ── Install Node via NodeSource ────────────────────────────────────────────
  info "Adding NodeSource repository..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VER}.x" | bash - 2>/dev/null || \
  curl -fsSL "https://rpm.nodesource.com/setup_${NODE_VER}.x" | bash -
  os_pkg_install nodejs
  log "Node.js $(node -v) installed"

  # ── PM2 ───────────────────────────────────────────────────────────────────
  info "Installing PM2 process manager..."
  npm install -g pm2
  pm2 startup systemd -u root --hp /root 2>/dev/null || \
  pm2 startup 2>/dev/null || true
  log "PM2 installed — use 'pm2 start app.js --name myapp' to launch"

  # ── Nginx reverse proxy ────────────────────────────────────────────────────
  info "Installing Nginx as reverse proxy..."
  os_pkg_install nginx
  os_svc_enable nginx

  # Write Node reverse proxy config
  read -rp "$(echo -e "${CYAN}App port to proxy (default 3000):${RESET} ")" APP_PORT
  APP_PORT="${APP_PORT:-3000}"

  cat > /etc/nginx/conf.d/node-app.conf <<NGINX
upstream node_app {
    server 127.0.0.1:${APP_PORT};
    keepalive 64;
}

server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/node-app-access.log;
    error_log  /var/log/nginx/node-app-error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        proxy_pass         http://node_app;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }

    # Static files served directly
    location /static/ {
        alias /var/www/app/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
NGINX

  nginx -t && nginx -s reload
  log "Nginx reverse proxy configured → localhost:${APP_PORT}"

  # ── Create app scaffold ────────────────────────────────────────────────────
  mkdir -p /var/www/app
  cat > /var/www/app/app.js <<JS
const http = require('http');
const PORT = process.env.PORT || ${APP_PORT};
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Server is running — replace this with your app!\\n');
}).listen(PORT, () => console.log(\`Listening on port \${PORT}\`));
JS

  pm2 start /var/www/app/app.js --name "node-app"
  pm2 save
  log "Sample app running at http://$(hostname -I | awk '{print $1}')"

  log "Node.js + Nginx + PM2 stack complete ✔"
}