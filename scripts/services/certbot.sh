#!/usr/bin/env bash
# Service: Certbot (Let's Encrypt SSL)

install_certbot() {
  section "Installing Certbot (Let's Encrypt)"

  case "$PKG_MANAGER" in
    apt)
      os_pkg_install snapd 2>/dev/null || true
      snap install core 2>/dev/null || true
      snap refresh core 2>/dev/null || true
      snap install --classic certbot 2>/dev/null || os_pkg_install certbot python3-certbot-nginx python3-certbot-apache
      ln -sf /snap/bin/certbot /usr/local/bin/certbot 2>/dev/null || true
      ;;
    dnf)
      os_pkg_install certbot python3-certbot-nginx python3-certbot-apache
      ;;
  esac

  certbot --version 2>/dev/null && log "Certbot installed: $(certbot --version 2>&1)"

  # ── Auto-renewal cron ─────────────────────────────────────────────────────
  if ! crontab -l 2>/dev/null | grep -q certbot; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true'") | crontab -
    log "Auto-renewal cron installed (daily at 3am)"
  fi

  # ── Usage instructions ────────────────────────────────────────────────────
  echo ""
  info "Certbot installed. To issue a certificate, run:"
  echo -e "  ${BOLD}Nginx :${RESET} certbot --nginx  -d yourdomain.com -d www.yourdomain.com"
  echo -e "  ${BOLD}Apache:${RESET} certbot --apache -d yourdomain.com -d www.yourdomain.com"
  echo -e "  ${BOLD}Standalone (no web server):${RESET} certbot certonly --standalone -d yourdomain.com"
  echo ""
  warn "Your domain DNS must point to this server's IP before running certbot."
}