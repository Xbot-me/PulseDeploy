#!/usr/bin/env bash
# Service: Certbot (Let's Encrypt SSL)
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

install_certbot() {
  section "Installing Certbot (Let's Encrypt)"

  # Distribution packages: no snap dependency, works in minimal images.
  pkg_available certbot || pkg_installed certbot ||
    error "certbot is not packaged for $OS_ID $OS_VERSION. Install it with the official pip/venv method (https://certbot.eff.org/instructions) and re-run."
  pkg_install_required certbot
  local nginx_present=0 apache_present=0
  command -v nginx &>/dev/null && nginx_present=1
  { command -v apache2ctl &>/dev/null || command -v httpd &>/dev/null; } && apache_present=1
  [[ "$nginx_present" -eq 1 ]] && pkg_install_optional python3-certbot-nginx
  [[ "$apache_present" -eq 1 ]] && pkg_install_optional python3-certbot-apache
  local version
  version="$(certbot --version 2>&1)" ||
    error "certbot was installed but does not run: ${version%%$'\n'*}"
  log "Certbot installed: $version"

  # ── Renewal: reload the web server after each successful renewal ───────────
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/pulsedeploy-reload.sh <<'HOOK'
#!/bin/sh
# Installed by PulseDeploy - reload whichever web server is running.
for s in nginx apache2 httpd; do
  systemctl is-active --quiet "$s" && systemctl reload "$s"
done
exit 0
HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/pulsedeploy-reload.sh

  # Prefer the systemd timer the package ships; fall back to a cron job.
  local t timer=""
  for t in certbot certbot-renew snap.certbot.renew; do
    if systemctl cat "$t.timer" &>/dev/null; then timer="$t"; break; fi
  done
  if [[ -n "$timer" ]]; then
    systemctl enable --now "$timer.timer"
    log "Auto-renewal enabled via systemd timer: $timer.timer"
  else
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%d 3 * * * root certbot renew --quiet\n' \
      "$((RANDOM % 60))" >/etc/cron.d/pulsedeploy-certbot
    chmod 644 /etc/cron.d/pulsedeploy-certbot
    log "Auto-renewal cron installed (daily ~3am)"
  fi

  _certbot_issue

  echo ""
  info "To issue or add certificates later:"
  echo -e "  ${BOLD}Nginx :${RESET} certbot --nginx  -d yourdomain.com -d www.yourdomain.com"
  echo -e "  ${BOLD}Apache:${RESET} certbot --apache -d yourdomain.com -d www.yourdomain.com"
  echo -e "  ${BOLD}Standalone (no web server):${RESET} certbot certonly --standalone -d yourdomain.com"
  echo ""
  return 0
}

# Try to issue a certificate when --domain and --email were given. DNS may not
# point here yet, so failure is a warning, never fatal.
_certbot_issue() {
  [[ -n "${DOMAIN:-}" ]] || return 0
  if [[ -z "${EMAIL:-}" ]]; then
    warn "Certificate not requested: --email is required together with --domain."
    return 0
  fi
  local plugin=""
  if command -v nginx &>/dev/null && [[ -f /etc/nginx/conf.d/pulsedeploy.conf ]]; then
    plugin="--nginx"
  elif command -v apache2ctl &>/dev/null || command -v httpd &>/dev/null; then
    plugin="--apache"
  else
    info "No web server configured by PulseDeploy - skipping automatic certificate."
    return 0
  fi
  info "Requesting a certificate for ${DOMAIN} ..."
  if certbot "$plugin" -d "$DOMAIN" --non-interactive --agree-tos --no-eff-email \
      -m "$EMAIL" --redirect; then
    log "HTTPS enabled for https://${DOMAIN}"
  else
    warn "Certificate request failed (is the DNS A record for ${DOMAIN} pointing to this server, and port 80 open?)."
    warn "Fix that, then run: certbot ${plugin} -d ${DOMAIN}"
  fi
  return 0
}
