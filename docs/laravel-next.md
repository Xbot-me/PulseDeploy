# Laravel + Next.js on one small server

`--stack laravel-next` sets up a single VPS for a Laravel API, a Next.js admin
dashboard and a Next.js storefront, tuned for a low monthly bill: about 4 GB of
RAM is comfortable, 2 GB works with swap.

```bash
sudo bash bootstrap.sh --stack laravel-next --domain example.com \
  --email you@example.com --services certbot,swap --cloudflare --non-interactive
```

## What you get

| Host (default)      | Served by                                    |
|---------------------|----------------------------------------------|
| `api.example.com`   | nginx, PHP-FPM (Laravel)                     |
| `admin.example.com` | nginx, Next.js on `127.0.0.1:3001` (systemd) |
| `example.com`       | nginx, Next.js on `127.0.0.1:3000` (systemd) |

Also installed: MySQL (tuned), Redis (cache, sessions, queues, loopback only),
a queue worker and a scheduler timer (systemd), a `deploy` user, a firewall,
fail2ban, automatic security updates, nightly database backups, and the `pulse`
command. Override host names with `--api-host`, `--admin-host`, `--shop-host`.

## Why it is cheap to run

- **PHP-FPM `ondemand`**: workers exist only while requests arrive, so idle RAM is close to zero.
- **MySQL** sized for a shared box (buffer pool about 18% of RAM, performance schema off, at most 50-100 connections).
- **Next.js `standalone`** output under systemd: no PM2 daemon, no `node_modules` install on the server, a memory cap per app.
- **nginx serves `/_next/static` from disk** with immutable caching and caches optimised storefront images, so Node only renders pages.
- **Cloudflare (free plan)** in front (`--cloudflare`) absorbs traffic and restores real visitor IPs for rate limiting.
- **Builds happen in CI**, not on the server: building Next.js needs more RAM than the app itself.

| Server RAM | php-fpm workers | MySQL buffer pool | Redis | Node heap (admin / shop) |
|-----------:|----------------:|------------------:|------:|--------------------------|
| 2 GB       | 6               | 384 MB            | 122 MB| 256 / 256 MB             |
| 4 GB       | 13              | 768 MB            | 245 MB| 256 / 384 MB             |
| 8 GB       | 27              | 1 GB              | 491 MB| 384 / 512 MB             |

## After the install

1. Point DNS A records for the three hosts (and `www`) at the server. With Cloudflare, keep the proxy on and use SSL mode *Full (strict)*.
2. Get certificates: pass `--services certbot --email you@example.com` (needs DNS in place first), or run `certbot --nginx -d ...` later.
3. Laravel settings live in `/var/www/api/shared/.env` (database, Redis, session domain and Sanctum domains are pre-filled). `APP_KEY` is generated on the first deploy.
4. Deploy (see below). Until the first deploy each host shows a small holding page.

## Deploying

Everything happens through `pulse`, as the `deploy` user (the installer copies
root's SSH keys there so CI can log in):

```bash
pulse deploy api   --artifact api.tar.gz        # or: --git URL --ref main
pulse deploy admin --artifact admin.tar.gz
pulse deploy shop  --artifact shop.tar.gz
pulse rollback api                              # previous release, instantly
pulse status                                    # services, releases, health, disk, RAM
pulse logs queue -f                             # api | admin | shop | queue | scheduler | php | nginx
sudo pulse backup                               # also runs nightly at ~03:xx
sudo pulse restore /var/backups/pulsedeploy/db-app-....sql.gz --yes
```

Each deploy builds a new directory under `releases/`, links the shared `.env`
and `storage`, runs migrations and caches (Laravel), then switches the `current`
symlink atomically and restarts the service. If the new release does not answer
its health check, `pulse` switches back automatically. The last 5 releases are
kept.

**Next.js artifact layout.** Set `output: 'standalone'` in `next.config.js` and
package the result so `server.js`, `.next/`, `public/` and `node_modules/` sit
at the archive root. `examples/github-actions/` has complete workflows.
`NEXT_PUBLIC_*` values are baked in at build time; other runtime variables go
in `/var/www/<app>/shared/.env`.

## Operating notes

- Backups: `/var/backups/pulsedeploy` (root only, 7 days). Set `RCLONE_REMOTE` in `/etc/pulsedeploy/pulse.conf` to copy them off the server (Backblaze B2 and similar are cheap), and `HEALTHCHECK_URL` to get alerted when a backup does not run.
- The web processes run as the `deploy` user. That keeps permissions simple on a single-tenant server; it also means a compromised app can rewrite its own code, so keep dependencies updated.
- `deploy` may use `sudo` only for restarting the PulseDeploy services and reloading PHP-FPM.
- Re-running the installer is safe: deployed releases, the Laravel `.env` and credentials are left alone.
- Undo with `sudo bash revert.sh --stack`. Applications, uploads and backups are kept unless you add `--purge-data`.
