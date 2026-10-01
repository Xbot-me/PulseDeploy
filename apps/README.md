# App registry

`crm.sh` reads plain `KEY=value` definitions from here. They are parsed, never
executed, so a definition cannot run code on the server.

- `crm/<id>.conf`: a CRM (backend + admin). Chosen with `--crm <id>` (default `aventech`).
- `storefronts/<id>.conf`: a storefront. Chosen with `--storefront <id>`, or pass any
  Git URL, or `none`.

List what is available: `bash crm.sh storefronts`.

## Format

```
# comment
NAME=Human readable name          # scalar: last one wins
BUILD_ENV+=KEY=value              # list: "+=" adds one entry
```

Values may use placeholders, filled in at install time:

| Placeholder | Meaning |
|---|---|
| `{API_URL}` `{ADMIN_URL}` `{SHOP_URL}` | public URLs of the three hosts, for example `https://api.example.com` |
| `{INTERNAL_API_URL}` | loopback API address, `http://127.0.0.1:8081` |
| `{STORE}` `{STORE_NAME}` | the tenant slug and display name |
| `{ADMIN_EMAIL}` `{ADMIN_PASSWORD}` | first store admin (password only for the store-creation step) |
| `{DOMAIN}` `{APP_NAME}` | main domain, display name of the CRM |

## Storefront keys

| Key | Default | Meaning |
|---|---|---|
| `NAME` | id | display name |
| `REPO` | required | Git URL (https or ssh) |
| `REF` | `main` | branch, tag or commit |
| `DIR` | `.` | folder inside the repo that holds `package.json` |
| `BUILD_CMD` | `npm ci && npm run build` | run in `DIR` as the deploy user |
| `BUILD_ENV+=` | none | `KEY=value` set for the build (`NEXT_PUBLIC_*` are baked in at build time) |
| `RUNTIME_ENV+=` | none | `KEY=value` written to the app's runtime `.env` on the server |

The storefront must be a Next.js app; the installer turns on `output: "standalone"`
in its Next.js config when it is not already set.
