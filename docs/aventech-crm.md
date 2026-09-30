# Running AvenTech CRM on a laravel-next server

> The one-command installer is [crm-installer.md](crm-installer.md); this page explains the parts.

AvenTech CRM is a Laravel 11 API (`backend/`) with a Next.js admin panel
(`admin-frontend/`). Stores are multi-tenant: each store gets its own MySQL
database (`zymerce_tenant_<subdomain>`), chosen per request by the
`X-Store-Subdomain` header. The storefront is not part of the repository yet;
its host shows a holding page until you deploy one.

## 1. Provision the server

```bash
sudo bash bootstrap.sh --stack laravel-next --domain example.com \
  --email you@example.com --services certbot --cloudflare \
  --db-name zymerce_crm --db-user zymerce \
  --tenant-db-prefix zymerce_tenant_ \
  --serve-storage --no-queue --no-scheduler --non-interactive
```

What the options do for this app:

| Option | Why |
|---|---|
| `--db-name` / `--db-user` | match the repository's `.env.example` |
| `--tenant-db-prefix zymerce_tenant_` | `php artisan store:create` runs `CREATE DATABASE` through the app's own DB user; this grants exactly `zymerce_tenant_*` and nothing else, and raises MySQL's table caches for many tenants |
| `--serve-storage` | uploaded product media (Laravel `public` disk) is served by nginx from disk on the admin and storefront hosts, so `/storage/*` never touches Node |
| `--no-queue`, `--no-scheduler` | the app has no queued jobs or scheduled tasks; saves a worker process and a per-minute PHP start |

The admin app reaches the API without leaving the machine, at
`http://127.0.0.1:8081` (a loopback-only nginx listener: no TLS, no Cloudflare
round trip, no rate limit).

## 2. One change in the admin repository

Add `output: "standalone"` to `admin-frontend/next.config.ts` so CI can package a
small, self-contained build:

```ts
const nextConfig: NextConfig = {
  output: "standalone",
  // ...existing settings
};
```

## 3. Settings

**API** `/var/www/api/shared/.env` (created by the installer; add what the app needs):

```
FRONTEND_URL=https://admin.example.com
STOREFRONT_URL=https://example.com
SSLCOMMERZ_STUB=false        # only after one real init + IPN has been verified
```

**Admin** `/var/www/admin/shared/.env`:

```
BACKEND_API_URL=http://127.0.0.1:8081/api/v1/admin
BACKEND_BASE_URL=http://127.0.0.1:8081/api
```

`NEXT_PUBLIC_*` values (for example `NEXT_PUBLIC_DEFAULT_SUBDOMAIN`) are baked in
at build time: set them in the CI build step, not on the server.

## 4. Deploy and create the first store

```bash
# from CI (see examples/github-actions), as the deploy user:
pulse deploy api   --artifact backend.tar.gz     # runs migrations, caches, reloads PHP
pulse deploy admin --artifact admin.tar.gz

# on the server:
sudo -u deploy bash -c 'cd /var/www/api/current && php artisan store:create "My Store" mystore --email=admin@example.com'
```

Payment gateway callbacks (SSLCommerz IPN and redirects) reach the API host
publicly at `https://api.example.com/...`; keep that host reachable.

## Verified on a test server

A real install with these options, then the repository's backend and admin:
migrations, `store:create` (the app user can create `zymerce_tenant_*` databases
and no others), admin login through nginx and Next.js to the tenant database with
an HttpOnly cookie, a second tenant that cannot log in with the first tenant's
credentials, uploads served by nginx, path traversal on `/storage/` refused, and
login attempts throttled by nginx on `/api/v1/admin/login`.
