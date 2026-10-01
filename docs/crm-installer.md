# One command: pull, build, install and configure the CRM with a storefront

`crm.sh` provisions the server, pulls the CRM and the storefront you choose
from Git, builds them, deploys them, creates the first store and checks that
everything answers.

```bash
git clone https://github.com/Xbot-me/PulseDeploy.git && cd PulseDeploy

sudo bash crm.sh install \
  --domain example.com --email you@example.com --certbot --cloudflare \
  --storefront <id | git-url | none> \
  --store acme --store-name "Acme Shop" --admin-email you@example.com \
  --git-token-file /root/gh-token \
  -- --timezone Asia/Dhaka --swap-size 2G
```

## What it does, in order

1. **Validates** every option and checks that each repository and branch is
   reachable, before anything on the server changes.
2. **Provisions the server** (`bootstrap.sh --stack laravel-next` with the options the
   CRM needs: database names, per-store database grants, uploads served by nginx, ...).
3. **Pulls, builds and deploys** the backend (`composer install`), the admin app
   and the storefront (`npm ci && npm run build`, standalone output). Builds run as
   the unprivileged deploy user. Each deploy is an atomic release that rolls back by
   itself if the health check fails.
4. **Creates the first store** and its admin login. The generated password goes to
   `/root/pulsedeploy-crm-credentials.txt` (root only), never to the log.
5. **Smoke-tests** the API, the admin (including a real login through to the store's
   database) and the storefront, and prints the URLs.

Re-running is safe: existing `.env` values are kept (`--reset-env` to overwrite),
an existing store is left alone, and deployed releases are replaced only after a
successful build.

## Choosing a storefront

```bash
bash crm.sh storefronts
```

- `--storefront <id>`: a definition in `apps/storefronts/<id>.conf` (see `apps/README.md`).
  Copy `sample.conf.disabled`, fill in the repository and the variables it needs.
- `--storefront <git-url>`: any Next.js repository. Add what it needs with
  `--storefront-ref`, `--storefront-dir`, `--storefront-build-cmd`, and repeatable
  `--storefront-build-env KEY=value` / `--storefront-runtime-env KEY=value`.
  Values may use `{API_URL} {ADMIN_URL} {SHOP_URL} {INTERNAL_API_URL} {STORE} {STORE_NAME} {DOMAIN}`.
- `--storefront none`: CRM only.

Build-time variables (`NEXT_PUBLIC_*`) are compiled into the bundle, so they must be
given at install time; runtime variables are written to the storefront's `.env` on the
server. If the storefront does not already use `output: "standalone"`, the installer
turns it on in its Next.js config for the build.

## Private repositories

- `--git-token-file FILE` (or the `PULSE_GIT_TOKEN` variable): a GitHub/GitLab token with
  read access. It is passed to git through the environment, never on a command line.
- `--git-ssh-key FILE` for `git@...` URLs.

## Day two

```bash
sudo pulse-crm update                          # pull, rebuild and redeploy everything
sudo pulse-crm update --only storefront --storefront-ref v1.4.0
sudo pulse-crm update --only backend,admin
pulse status | pulse logs admin | pulse rollback shop | sudo pulse backup
```

`update` remembers the choices made at install time (`/etc/pulsedeploy/crm.conf`).

## Options

`bash crm.sh help` lists everything. Anything after `--` goes straight to
`bootstrap.sh` (`--hostname`, `--timezone`, `--swap-size`, `--ssh-port`,
`--disable-root-ssh`, `--php`, `--node`, ...).

| Flow option | Effect |
|---|---|
| `--check` | validate options and repository access, then stop |
| `--dry-run` | print the plan, then stop |
| `--skip-server` | the server is already provisioned; only pull, build and deploy |
| `--only backend,admin,storefront` | act on some components |
| `--crm <id>` / `--crm-repo` / `--crm-ref` | choose or override the CRM definition |

Building on the server needs memory: the installer sizes Node's heap from the RAM
and the stack enables swap on servers with 4 GB or less. For very small servers,
build in CI instead and use `pulse deploy` (see `examples/github-actions/`).

## When GitHub cannot be reached reliably

If a download keeps breaking part-way (`curl 56 ... connection reset / timed out`,
`curl 92 ... stream not closed cleanly`, `early EOF`), the network between the server and
GitHub is dropping long transfers. The installer retries three times from a clean
directory and uses HTTP/1.1 for git. If it still fails:

1. **Let TCP discover the path size.** A common cause on VM/NAT networks is that large
   packets vanish while ICMP (which would tell the sender to use smaller ones) is filtered:
   small requests work, long downloads stall. This is safe and takes effect at once:
   ```bash
   sudo sysctl -w net.ipv4.tcp_mtu_probing=1
   echo 'net.ipv4.tcp_mtu_probing = 1' | sudo tee /etc/sysctl.d/99-mtu-probing.conf
   ```
2. **Bring the repository over another way.** On a machine that can reach GitHub:
   ```bash
   git clone --branch <branch> https://github.com/<owner>/<repo>.git crm
   git -C crm bundle create ../crm.bundle --all
   scp crm.bundle ec2-user@<server>:/tmp/
   ```
   On the server (the `deploy` user must be able to read it):
   ```bash
   sudo git clone /tmp/crm.bundle /srv/crm && sudo chmod -R a+rX /srv/crm
   sudo bash crm.sh update --only backend --crm-repo file:///srv/crm --crm-ref <branch>
   ```
   `--crm-repo` (and `--check`) accept `file:///path`; no token is needed for a local clone.

