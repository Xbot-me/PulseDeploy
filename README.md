# ⚡ PulseDeploy

> **One-command VPS & AWS server setup automation** — LEMP · LAMP · Node.js · Docker · Redis · SSL · Firewall

[![CI](https://github.com/Xbot-me/PulseDeploy/actions/workflows/ci.yml/badge.svg)](https://github.com/Xbot-me/PulseDeploy/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-f97316?style=flat-square)](LICENSE)
[![Bash](https://img.shields.io/badge/Bash-5.x-f97316?style=flat-square&logo=gnubash)](https://www.gnu.org/software/bash/)
[![Distros](https://img.shields.io/badge/Distros-Ubuntu%20%7C%20Debian%20%7C%20Amazon%20Linux%20%7C%20Rocky-blue?style=flat-square)](README.md)
[![Stacks](https://img.shields.io/badge/Stacks-LEMP%20%7C%20LAMP%20%7C%20Node.js-brightgreen?style=flat-square)](README.md)

```
  ██████╗ ██╗   ██╗██╗     ███████╗███████╗
  ██╔══██╗██║   ██║██║     ██╔════╝██╔════╝
  ██████╔╝██║   ██║██║     ███████╗█████╗
  ██╔═══╝ ██║   ██║██║     ╚════██║██╔══╝
  ██║     ╚██████╔╝███████╗███████║███████╗
  ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚══════╝
  ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗
  ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝
  ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝
  ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝
  ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║
  ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝
  VPS & AWS Server Automation · by @Xbot-me
```

---

## 🧠 About

**PulseDeploy** is a modular Bash automation toolkit for spinning up production-ready Linux servers in minutes — whether you're on a Hetzner VPS, DigitalOcean Droplet, Linode, Vultr, or **AWS EC2**.

No Ansible. No Terraform. No YAML hell. Just clean, readable Bash with an interactive wizard that auto-detects your OS, adapts to your RAM, asks what you need — then gets out of the way.

Built by a developer who personally recovered from 502 storms, 8GB database bloat, Redis misconfigurations, and live payment skimmer incidents on a WooCommerce store with 130k+ customers. This script exists because I needed it to exist.

---

## ✨ Features

| Category       | What's included |
|----------------|----------------|
| **Stacks**     | LEMP (Nginx + PHP-FPM + MySQL), LAMP (Apache + PHP + MySQL), Node.js + PM2 + Nginx reverse proxy, **Laravel + Next.js** (API + admin + storefront on one small server, see [docs](docs/laravel-next.md)) |
| **PHP**        | Version selector (8.1 – 8.4; third-party repo added only if your distro lacks it), OPcache JIT, PHP-FPM pool auto-tuning based on RAM |
| **Security**   | UFW / firewalld, fail2ban (SSH + Nginx + Apache rules), secure file blocking in web configs |
| **SSL**        | Certbot (Let's Encrypt) with auto-renewal cron |
| **Caching**    | Redis with Unix socket or TCP, maxmemory auto-calculated, allkeys-lru policy |
| **Containers** | Docker Engine + Docker Compose v2, log rotation, weekly prune cron |
| **Swap**       | Auto-sized swap file based on detected RAM, swappiness=10 tuning |
| **Reliability**| Idempotent (safe to re-run), every step verified (health checks, not just exit codes), strict flag/input validation, config changes validated and rolled back on failure |
| **Logging**    | Full install log saved to `/var/log/server-bootstrap.log` |

---

## 🐧 Supported Operating Systems

| Distro                               | Package Manager | Notes |
|--------------------------------------|-----------------|-------|
| Ubuntu 20.04 / 22.04 / 24.04        | apt             | Full support |
| Debian 11 (Bullseye) / 12 (Bookworm)| apt             | Full support |
| Amazon Linux 2023 (AL2 best effort, EOL) | dnf / yum  | AWS-aware: Security Group hints, IMDSv2 detection |
| CentOS 8 / Rocky Linux 8 & 9        | dnf             | SELinux awareness, Remi repo for PHP |

---

## 🚀 Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/Xbot-me/PulseDeploy.git
cd PulseDeploy

# 2. Make executable
chmod +x bootstrap.sh scripts/**/*.sh

# 3. Run as root
sudo bash bootstrap.sh
```

The interactive wizard walks you through:

1. **OS detection** — automatic, no input needed
2. **Stack selection** — LEMP / LAMP / Node.js / core only
3. **Services toggle** — Redis · Docker · Firewall · SSL · Swap · PHP tuning
4. **Summary + confirmation** — review everything before a single package is installed

Everything the wizard asks can also be given as a flag (`--stack`, `--php`, `--node`, `--services`, `--domain`, `--email`, `--db-name`, `--db-user`, `--swap-size`, `--redis-conn`, `--open-ports`, `--ssh-port`, `--hostname`, `--timezone`, `--disable-root-ssh`, `--non-interactive`) or `PULSE_*` environment variable. See `bash bootstrap.sh --help`.

**Laravel API + two Next.js apps on one cheap VPS:** `sudo bash bootstrap.sh --stack laravel-next --domain example.com`. It tunes PHP-FPM, MySQL, Redis and Node for a shared 2-8 GB box, sets up systemd services, a queue worker, backups and a `pulse deploy` / `pulse rollback` command. Full guide and CI examples: [docs/laravel-next.md](docs/laravel-next.md); a worked multi-tenant example is in [docs/aventech-crm.md](docs/aventech-crm.md).

**Everything in one command** (pull, build, install and configure the CRM with a chosen storefront): `sudo bash crm.sh install --domain example.com --storefront <id|git-url|none> ...`, see [docs/crm-installer.md](docs/crm-installer.md). Trying it on a fresh VM (including Amazon Linux 2023): [docs/testing-on-a-vm.md](docs/testing-on-a-vm.md), with a read-only `scripts/vm-check.sh` readiness check. Afterwards, `sudo pulse-crm audit` measures the live server against its tuning targets (settings, memory, cache hit rates, latency, hardening): [docs/auditing.md](docs/auditing.md).

To undo an installation: `sudo bash revert.sh --list`, then `sudo bash revert.sh --yes` (dry-run without `--yes`; databases and Docker data are kept unless `--purge-data`).

---

## 📁 Project Structure

```
PulseDeploy/
├── bootstrap.sh              # Main entry point & interactive wizard
├── revert.sh                 # Roll back what bootstrap.sh installed (dry-run by default)
├── crm.sh                    # One command: pull, build, install and configure a CRM + storefront
├── apps/                     # CRM and storefront definitions (crm/, storefronts/)
├── bin/pulse                 # On-server CLI: deploy, rollback, status, logs, backup (laravel-next)
├── docs/laravel-next.md      # Laravel + Next.js stack guide
├── examples/github-actions/  # CI workflows that build and deploy the apps
├── tests/run.sh              # Unit tests for helpers + CLI validation
├── scripts/
│   ├── lib/                  # Shared helpers (logging, validation, pkg/service/config)
│   │   ├── common.sh
│   │   ├── web.sh            # nginx/apache/PHP layout, health checks
│   │   └── profile_tuning.sh # RAM-based sizing for the laravel-next stack
│   ├── os/                   # OS-specific package management
│   │   ├── ubuntu.sh
│   │   ├── debian.sh
│   │   ├── amazon_linux.sh   # AWS-aware (IMDSv2, Security Group hints)
│   │   └── centos_rocky.sh   # SELinux-aware
│   ├── stacks/               # Web stack installers
│   │   ├── lemp.sh           # Nginx + PHP-FPM + MySQL
│   │   ├── lamp.sh           # Apache + PHP + MySQL
│   │   ├── node.sh           # Node.js + PM2 + Nginx proxy
│   │   └── laravel_next.sh   # Laravel API + Next.js admin + storefront
│   └── services/             # Optional service installers
│       ├── firewall.sh       # UFW / firewalld + fail2ban
│       ├── redis.sh          # Redis with socket/TCP option
│       ├── docker.sh         # Docker Engine + Compose v2
│       ├── certbot.sh        # Let's Encrypt SSL + auto-renewal
│       ├── swap.sh           # Auto-sized swap file
│       ├── mysql.sh          # MySQL/MariaDB install + hardening + DB/user creation
│       └── php_tune.sh       # PHP-FPM + OPcache + php.ini tuning (drop-in files)
├── config/
│   ├── nginx/default.conf    # Production Nginx template
│   └── apache/vhost.conf     # Production Apache vhost template
└── .github/workflows/ci.yml  # ShellCheck lint + config validation
```

---

## ☁️ AWS EC2 Notes

When running on Amazon Linux 2 / 2023, PulseDeploy automatically:

- Detects the EC2 instance via **IMDSv2**
- Warns you to open **ports 80/443/22** in your **Security Group** (OS-level firewall rules alone are not enough on AWS)
- Uses `firewalld` instead of `ufw`
- Uses the distribution's MariaDB/MySQL packages (no third-party repo required)

**Recommended EC2 setup before running:**

```bash
# Open required ports via AWS CLI
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
```

---

## 🔒 Security Defaults

Every stack is deployed with hardened defaults out of the box:

- `server_tokens off` — hides Nginx/Apache version from response headers
- Blocked access to `.env`, `.git`, `.sql`, `.log`, `.bak`, `.sh` files
- HTTP security headers: `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, `Referrer-Policy`
- fail2ban: 24-hour SSH ban after 3 failed attempts, Nginx + Apache jail rules included
- MySQL root password auto-generated and saved to `/root/.my.cnf` (chmod 600)
- PHP: `expose_php = Off`, memory and upload limits set for production

---

## 🧩 Running Individual Modules

Every module is independently sourceable — no need to run the full wizard. Settings are plain variables (`PHP_VER`, `SWAP_SIZE`, `REDIS_CONN`, `DOMAIN`, …); run as root:

```bash
# Install only Redis on an existing server
source scripts/os/ubuntu.sh
source scripts/services/redis.sh
install_redis

# Tune PHP-FPM on a live server
source scripts/os/ubuntu.sh
source scripts/services/php_tune.sh
tune_php_fpm

# Set up Docker only
source scripts/os/debian.sh
source scripts/services/docker.sh
install_docker
```

---

## 📋 Post-Install Checklist

- [ ] SSL: pass `--domain` + `--email` with the `certbot` service, or run `certbot --nginx -d yourdomain.com`
- [ ] Upload your site to `/var/www/html` (a placeholder page is there until you do)
- [ ] Point your domain DNS A record to your server IP
- [ ] Review fail2ban: `fail2ban-client status sshd`
- [ ] Check firewall rules: `ufw status` or `firewall-cmd --list-all`
- [ ] Test Redis: `redis-cli ping` → should return `PONG`
- [ ] On AWS: verify Security Group rules in the AWS Console

---

## 🛡️ Reliability Notes

- **Verified, not assumed.** LEMP/LAMP run an end-to-end HTTP → PHP check (using a throw-away file, no `phpinfo()` is left exposed); Redis, Docker, MySQL and swap are each confirmed working before being reported as done.
- **Safe defaults.** MySQL root gets a random password (saved to `/root/.my.cnf`, `chmod 600`) and *requires* it; the firewall always keeps every SSH port open and never resets your existing rules; `--disable-root-ssh` refuses unless another sudo user with an SSH key exists; Docker's weekly cleanup never touches volumes.
- **Fails loudly.** Any failure prints the function, file:line and command, then exits non-zero. Unknown flags and invalid values are rejected before anything is changed.
- **Non-interactive by design.** Flags/env vars cover every choice the wizard asks; with no terminal (cloud-init) it switches to non-interactive automatically.
- **Requirements.** A real VM/VPS with systemd (not a Docker container), 2 GB free disk, root. Port 80 must not be held by another web server.

### Testing status

Unit tests: `bash tests/run.sh` (no root, no network). The Ubuntu path (LEMP, LAMP, Node, Redis, swap, PHP tuning, fail2ban, SSH hardening, revert) has been exercised end to end on Ubuntu 24.04. **Debian, Rocky/Alma/RHEL and Amazon Linux code paths follow the same design but have not been run on real machines yet** — please report issues using the bug template.

---

## 🗺️ Roadmap

- [ ] WordPress fast-deploy module (on top of LEMP)
- [ ] `healthcheck.sh` — audit an existing server's config and services
- [ ] PostgreSQL stack option
- [ ] Slack / email notification on install complete

---

## 🤝 Contributing

PRs welcome. If you add support for a new distro or service, follow the existing module pattern — one file per concern, source-able standalone, OS functions via the `os_*` abstraction layer.

```bash
git checkout -b feat/your-feature
# make changes
git commit -m "feat: description"
git push origin feat/your-feature
```

---

## 📜 License

MIT — free to use, fork, and adapt for your own infrastructure.

---

> Built by [@Xbot-me](https://github.com/Xbot-me) · `build it · break it · fix it · automate it`
