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

**PulseDeploy** is a modular Bash toolkit for turning a fresh Linux server into a production-ready one: web stack, database, cache, firewall, TLS, backups and a deploy command. It works on a VPS (Hetzner, DigitalOcean, Linode, Vultr) or **AWS EC2**.

No Ansible. No Terraform. No YAML. Plain Bash you can read, with an interactive wizard that detects the OS, sizes everything to the machine's RAM and asks only what it needs.

Built after recovering from 502 storms, a bloated database, Redis misconfiguration and a payment-skimmer incident on a WooCommerce store with 130k+ customers.

**On this page:** [What you get](#-what-you-get) · [Supported systems](#-supported-operating-systems) · [Before you start](#-before-you-start-every-os) · [Install on Ubuntu / Debian](#-install-on-ubuntu--debian) · [Install on Amazon Linux 2023](#-install-on-amazon-linux-2023-aws-ec2-or-a-vm) · [Install on Rocky / Alma / CentOS](#-install-on-rocky--alma--centos--rhel) · [Working from Windows or macOS](#-working-from-windows-or-macos) · [Stacks](#-the-stacks) · [Options](#-every-option) · [After installing](#-after-installing) · [Operating the server](#-operating-the-server) · [Auditing, tuning, load testing](#-auditing-tuning-and-load-testing) · [Undo](#-undoing-an-install) · [Troubleshooting](#-troubleshooting)

---

## ✨ What you get

| Category       | What's included |
|----------------|----------------|
| **Stacks**     | LEMP (Nginx + PHP-FPM + MySQL/MariaDB), LAMP (Apache + PHP + MySQL/MariaDB), Node.js + PM2 + Nginx reverse proxy, **Laravel + Next.js** (API + admin + storefront on one small server, see [docs](docs/laravel-next.md)) |
| **One-command CRM** | `crm.sh` pulls, builds and configures the AvenTech CRM (Laravel API + Next.js admin, multi-tenant) with a chosen storefront ([docs](docs/crm-installer.md)) |
| **PHP**        | Version selector (8.1 – 8.4; a third-party repo is added only if your distro lacks the version), OPcache JIT, PHP-FPM pool sized from RAM |
| **Security**   | UFW or firewalld, fail2ban (SSH + Nginx + Apache), blocked access to `.env`/`.git`/`.sql`/backups, security headers, MariaDB/MySQL bound to localhost |
| **SSL**        | Certbot (Let's Encrypt) with auto-renewal |
| **Caching**    | Redis over a Unix socket or TCP, `maxmemory` calculated from RAM, `allkeys-lru` |
| **Containers** | Docker Engine + Compose v2, log rotation, weekly prune (never touches volumes) |
| **Swap**       | Auto-sized swap file, `swappiness=10` |
| **Operations** | `pulse` CLI (deploy, rollback, status, logs, backup, restore), nightly backups, `audit` and `retune` commands, load-test and test-data tooling |
| **Reliability**| Idempotent (safe to re-run), every step verified with a real check (not only an exit code), strict flag validation, config changes validated and rolled back on failure |
| **Logging**    | Full install log in `/var/log/server-bootstrap.log` (and `/var/log/pulsedeploy-crm.log` for `crm.sh`) |

---

## 🐧 Supported Operating Systems

| Distro | Package manager | Tested on a real machine? | Notes |
|---|---|---|---|
| Ubuntu 20.04 / 22.04 / 24.04 | apt | **Yes**, 24.04 (LEMP, LAMP, Node, Redis, swap, tuning, fail2ban, SSH hardening, revert) | Full support |
| Amazon Linux 2023 | dnf | **Yes**, on a VMware VM (full Laravel + Next.js + CRM install, audit, tuning, load test) | MariaDB replaces MySQL; Redis is `redis6`; no `fail2ban`/`certbot` packages (skipped with a warning). AWS-aware: IMDSv2 detection, Security Group hints |
| Amazon Linux 2 | yum | No (end of life) | Best effort; current Node.js cannot run on it. Use 2023 |
| Debian 11 / 12 | apt | Not yet | Same code path as Ubuntu |
| Rocky / AlmaLinux / CentOS Stream / RHEL 8 & 9 | dnf | Not yet | SELinux awareness, Remi repo for PHP |

"Not yet" means the code follows the same design but has not been run on a real machine. If you try one, please report the result with the bug template.

---

## 🧭 Before you start (every OS)

You need:

| Need | Why |
|---|---|
| A real VM or VPS with **systemd** (not a Docker container) | services are managed with `systemctl` |
| **root** or `sudo` | the installer changes system packages and config |
| 2 GB free disk (15 GB+ for the Laravel + Next.js / CRM stacks, builds use about 3 GB) | packages, builds, backups |
| RAM: 1 GB for LEMP/LAMP/Node; 2 GB (with swap) to 4 GB+ for the CRM stack | everything is sized from the detected RAM |
| Internet access | package repositories, GitHub, npm, Packagist |
| Port 80 not held by another web server | nginx/Apache binds it |
| A domain pointing at the server (only for real TLS certificates) | Let's Encrypt must reach the server |

**Open the network first.** A server firewall is not enough on cloud providers: open ports **22 (SSH), 80 and 443** in the provider's firewall too (AWS Security Group, DigitalOcean Cloud Firewall, Hetzner Firewall, ...).

**Never put secrets in the command line or in chat.** Private-repository tokens go in a file (`--git-token-file`), passwords are generated for you and saved to a root-only file, and anything shown in a terminal can end up in shell history and logs.

**Take a snapshot first** if the machine matters. Then a bad attempt costs nothing.

---

## 🟠 Install on Ubuntu / Debian

Works on Ubuntu 20.04 / 22.04 / 24.04 and Debian 11 / 12. Commands run on the server, as a user with `sudo`.

**1. Get the code.** `git` is already installed on most images; if not, the first line installs it.

```bash
sudo apt update && sudo apt install -y git      # refresh package lists, install git
git clone https://github.com/Xbot-me/PulseDeploy.git
cd PulseDeploy
```

**2. Check the machine (changes nothing).**

```bash
bash scripts/vm-check.sh      # OS, RAM, disk, systemd, outbound access; fix any FAIL line first
```

**3. Run the interactive wizard.** It detects the OS, asks for the stack and services, prints a summary and waits for your confirmation before installing anything.

```bash
sudo bash bootstrap.sh
```

**4. Or run it with no questions** (good for cloud-init and repeatable servers). A complete LEMP server with TLS:

```bash
sudo bash bootstrap.sh \
  --stack lemp --php 8.3 \
  --services redis,firewall,swap,certbot,phptune \
  --domain example.com --email you@example.com \
  --db-name app --db-user app \
  --timezone UTC --non-interactive
```

What each part does: `--stack lemp` installs Nginx + PHP-FPM + MariaDB/MySQL; `--php 8.3` picks the PHP version; `--services` turns on Redis, the firewall (UFW + fail2ban), a swap file, Let's Encrypt and PHP-FPM/OPcache tuning; `--domain`/`--email` set the Nginx `server_name` and certificate contact; `--db-name`/`--db-user` create a database and a user with a random password saved to `/root/.my.cnf` (mode 600).

Other examples:

```bash
# Node.js app behind Nginx on port 3000, kept alive by PM2
sudo bash bootstrap.sh --stack node --node 22 --app-port 3000 \
  --services firewall,swap --domain app.example.com --non-interactive

# Laravel API + Next.js admin + storefront on one small server
sudo bash bootstrap.sh --stack laravel-next --domain example.com --email you@example.com \
  --services redis,firewall,swap,certbot --non-interactive

# Core only (updates, firewall, swap, no web stack)
sudo bash bootstrap.sh --stack none --services firewall,swap --non-interactive
```

**5. Verify.**

```bash
systemctl status nginx php8.3-fpm mysql --no-pager     # (mariadb on some images) services active
curl -I http://localhost                               # HTTP 200 from the placeholder page
sudo ufw status                                        # firewall rules
sudo fail2ban-client status sshd                       # SSH protection
```

On **Debian** the commands are identical. On a minimal image run `sudo apt install -y sudo curl ca-certificates git` first as root.

---

## 🟡 Install on Amazon Linux 2023 (AWS EC2 or a VM)

This is the best-tested path for the Laravel + Next.js / CRM stack. Amazon Linux 2023 differs from Ubuntu in a few ways, and PulseDeploy handles them:

| Difference | What PulseDeploy does |
|---|---|
| `dnf` instead of `apt` | the OS layer wraps it; you never call it |
| MariaDB instead of MySQL (`mysql.service` is an alias of `mariadb.service`) | installs MariaDB, binds it to `127.0.0.1` only (the default listens on all interfaces), sets `utf8mb4_unicode_ci` so Laravel 11 migrations work |
| Redis package is `redis6`, client `redis6-cli` | uses those names |
| `firewalld` instead of UFW | opens only the ports you allow |
| No `fail2ban` / `certbot` packages in the default repos | skipped with a warning (use Cloudflare or an ALB for TLS, or install certbot yourself) |
| Node 18 preinstalled | upgraded to the requested version (default 22) |
| Several `php8.x` versions available at once | installs exactly the requested one and removes conflicts |

**1. Launch the instance** (EC2): Amazon Linux **2023** (not "Amazon Linux 2"), `t3.medium` or larger for the CRM (2 vCPU, 4 GB), 20 GB disk. In the **Security Group** allow inbound 22 (your IP only), 80 and 443:

```bash
aws ec2 authorize-security-group-ingress --group-id sg-xxxxxxxx --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id sg-xxxxxxxx --protocol tcp --port 443 --cidr 0.0.0.0/0
```

Not on AWS? A VMware/VirtualBox/Proxmox VM running Amazon Linux 2023 works the same way: see [docs/testing-on-a-vm.md](docs/testing-on-a-vm.md) (host names without real DNS, snapshots, what to check).

**2. Connect and get the code.** The default user is `ec2-user`:

```bash
ssh -i your-key.pem ec2-user@<public-ip>
sudo dnf install -y git
git clone https://github.com/Xbot-me/PulseDeploy.git
cd PulseDeploy
bash scripts/vm-check.sh      # read-only readiness check; WARN lines about fail2ban/certbot are expected
```

**3. Install.** Plain stack, no CRM:

```bash
sudo bash bootstrap.sh --stack laravel-next --domain example.com \
  --services redis,firewall,swap --non-interactive
```

Or the whole CRM in one command (pull, build, configure, first store, smoke tests). Try the plan first, then run it:

```bash
# private repositories only: type the token at the prompt (it is not echoed or kept in shell history)
read -rsp "Token: " t; echo; printf '%s' "$t" | sudo install -m 600 /dev/stdin /root/gh-token; unset t

sudo bash crm.sh install --domain example.com --storefront none \
  --git-token-file /root/gh-token --dry-run        # print the plan, change nothing
sudo bash crm.sh install --domain example.com --storefront none \
  --git-token-file /root/gh-token --check          # also prove the repositories are readable
sudo bash crm.sh install --domain example.com --storefront none \
  --git-token-file /root/gh-token --store main --store-name "My Store" -y
```

The admin login is generated and saved to `/root/pulsedeploy-crm-credentials.txt` (read it with `sudo cat`; it is never printed to the log). Add a storefront later with `sudo bash crm.sh install --skip-server --only storefront --storefront <id|git-url>`. If a PHP version is missing from the repository, pin one: add `-- -P 8.2` at the end.

**4. Verify.**

```bash
pulse status                                           # services active, all three hosts answer HTTP 200
sudo bash scripts/audit.sh --no-perf                   # settings, memory, cache hit rates, hardening
sudo cat /root/pulsedeploy-crm-credentials.txt         # admin login
```

**Behind Cloudflare?** Add `--cloudflare` (real client IPs, https URLs). Without Cloudflare or certbot, URLs are plain `http://`.

---

## 🔴 Install on Rocky / Alma / CentOS / RHEL

Rocky Linux 8 and 9, AlmaLinux 8 and 9, CentOS Stream and RHEL 8/9. These paths follow the same design as the others but have **not yet been run on real machines**: review the dry run and report anything that fails.

```bash
sudo dnf install -y git
git clone https://github.com/Xbot-me/PulseDeploy.git
cd PulseDeploy
bash scripts/vm-check.sh
sudo bash bootstrap.sh --stack lemp --php 8.3 --services redis,firewall,swap,certbot \
  --domain example.com --email you@example.com --non-interactive
```

What differs: PulseDeploy enables **EPEL** (extra packages) and the **CRB/PowerTools** repo, installs the **Remi** repository to get the PHP version you ask for (falling back to the distro's PHP, with a warning, if Remi is unreachable), uses `firewalld`, and checks **SELinux**. If SELinux is `Enforcing` you may need booleans for nginx/PHP, for example:

```bash
sudo setsebool -P httpd_can_network_connect 1       # nginx/PHP may open network connections
sudo setsebool -P httpd_can_network_connect_db 1    # ... to a database
```

To confirm SELinux is the cause of a 502, run `sudo setenforce 0` temporarily; if the error goes away, add the right boolean instead of leaving SELinux off.

---

## 💻 Working from Windows or macOS

PulseDeploy itself runs **on the Linux server**. Your Windows or macOS computer is the place you connect from, and where you run the load tests.

| Task | Windows | macOS |
|---|---|---|
| Open a shell on the server | PowerShell or Windows Terminal: `ssh ec2-user@<ip>` (OpenSSH is built in) | Terminal: `ssh ec2-user@<ip>` |
| Run bash scripts locally (load tests) | **Git Bash** (from git-scm.com) with Python 3.9+ from python.org, or **WSL** | built in (`bash`), install Python 3 with `brew install python` |
| Reach a test VM without DNS | edit `C:\Windows\System32\drivers\etc\hosts` as Administrator | `sudo nano /etc/hosts` |
| Hosts entry to add | `192.168.1.50  api.crm.test admin.crm.test shop.crm.test` | same |

The load-test module (`loadtest/run.sh`) is designed to run from your PC, not from the server, and works in Git Bash on Windows. Full steps: [docs/load-testing.md](docs/load-testing.md).

Do not try to run `bootstrap.sh` on Windows or macOS: it installs system packages and manages services, and refuses to run on anything but a supported Linux.

---

## 🧱 The stacks

| `--stack` | Installs | Typical use |
|---|---|---|
| `lemp` | Nginx, PHP-FPM, MariaDB/MySQL | PHP sites, WordPress, Laravel on a classic server |
| `lamp` | Apache, PHP, MariaDB/MySQL | Apache-only PHP apps |
| `node` | Node.js, PM2, Nginx reverse proxy | any Node app on `--app-port` |
| `laravel-next` | Nginx, PHP-FPM, MariaDB/MySQL, Redis, Node, systemd services for the API, queue worker, scheduler and two Next.js apps, backups, `pulse` CLI | Laravel API + Next.js admin + storefront on one 2-8 GB server ([guide](docs/laravel-next.md), [worked CRM example](docs/aventech-crm.md)) |
| `none` | core only (updates, selected services) | you bring your own application layer |

`crm.sh install` is `laravel-next` plus pulling the CRM and storefront code, building them, creating the first store and running smoke tests ([docs/crm-installer.md](docs/crm-installer.md)). `bash crm.sh storefronts` lists the storefronts you can choose.

---

## 🎛️ Every option

Everything the wizard asks can be given as a flag or a `PULSE_*` environment variable. Flags may be written `--flag value` or `--flag=value`; unknown flags and invalid values are rejected before anything changes. `bash bootstrap.sh --help` prints this list.

| Option | Meaning | Default |
|---|---|---|
| `-s, --stack` | `lemp` `lamp` `node` `laravel-next` `none` | wizard |
| `-P, --php` | `8.1` `8.2` `8.3` `8.4` | 8.2 |
| `-N, --node` | `18` `20` `22` `24` | 22 |
| `-S, --services` | comma list of `redis,docker,firewall,certbot,swap,phptune` | none |
| `--redis-conn` | `socket` or `tcp` | socket |
| `--open-ports` | extra firewall ports, e.g. `8080,9000` | none |
| `--domain`, `--email` | server name and certificate contact | none |
| `--hostname`, `--timezone` | set the machine's hostname / timezone (e.g. `Asia/Dhaka`) | unchanged |
| `--ssh-port` | SSH port the firewall must keep open (the port sshd really uses is always kept) | 22 |
| `--disable-root-ssh` | turn off root SSH login; refused unless another sudo user with an SSH key exists | off |
| `--app-port` | Node app port for the reverse proxy | 3000 |
| `--db-name`, `--db-user` | create a database and user (random password in `/root/.my.cnf`) | none |
| `--swap-size` | e.g. `512M`, `2G` | auto from RAM |
| `-y, --non-interactive` | no prompts (automatic when there is no terminal) | off |
| `--api-host`, `--admin-host`, `--shop-host`, `--app-user`, `--cloudflare`, `--tenant-db-prefix`, `--serve-storage`, `--no-queue`, `--no-scheduler` | `laravel-next` options | `api.<domain>`, `admin.<domain>`, `<domain>`, `deploy` |

For `crm.sh install` (and `update`, `audit`, `retune`) run `bash crm.sh help`.

---

## 📋 After installing

- [ ] DNS: point the A records for your domain (and `api.`, `admin.` for the Laravel stack) at the server's IP
- [ ] TLS: pass `--domain` + `--email` with the `certbot` service, or run `sudo certbot --nginx -d yourdomain.com`
- [ ] Upload your site to `/var/www/html` (a placeholder page is there until you do)
- [ ] SSH protection: `sudo fail2ban-client status sshd`
- [ ] Firewall: `sudo ufw status` (Ubuntu/Debian) or `sudo firewall-cmd --list-all` (RHEL family)
- [ ] Redis: `redis-cli ping` returns `PONG` (`redis6-cli` on Amazon Linux)
- [ ] Database is not exposed: `ss -ltnp | grep -E ':3306'` must show `127.0.0.1`, not `0.0.0.0`
- [ ] On AWS: confirm the Security Group allows only the ports you want
- [ ] Change any password that was ever pasted into a chat or ticket

---

## 🔧 Operating the server

The `pulse` command is installed with the `laravel-next` stack and the CRM installer:

```bash
pulse status                                  # services and the three hosts
pulse logs api -f                             # follow a log (api|admin|shop|queue|scheduler|php|nginx)
pulse deploy api --git https://github.com/you/api.git --ref main   # deploy new code (migrates)
pulse rollback admin                          # return to the previous release
sudo pulse backup                             # database dump, kept on disk
sudo pulse restore FILE.sql.gz --yes          # restore a dump
sudo pulse-crm update --only backend,admin    # CRM: pull and redeploy
```

CI examples that build and deploy automatically are in `examples/github-actions/`.

---

## 📈 Auditing, tuning and load testing

| Tool | Command | What it does |
|---|---|---|
| **Audit** | `sudo pulse-crm audit` or `sudo bash scripts/audit.sh [--no-perf]` | read-only: compares the live server with its tuning targets (settings, memory, cache hit rates, latency, hardening) ([docs](docs/auditing.md)) |
| **Retune** | `sudo pulse-crm retune [--apply]` | applies hand-tuned values from `/etc/pulsedeploy/tuning.conf` (they survive re-runs) |
| **Test data** | `sudo bash loadtest/seed/seed.sh --store loadtest --create-store` | fills a separate test store with realistic products, customers and orders (100k orders in ~10 s), and `--purge` removes it |
| **Load test** | `bash loadtest/run.sh ...` (from your PC, not the server) | human-like traffic: people log in once, think, click and leave. Profiles: smoke, average, peak, spike, soak, breakpoint ([docs](docs/load-testing.md)) |

Seed first, then load-test: an empty database always looks fast. [docs/CRM-SCALING-FINDINGS.md](docs/CRM-SCALING-FINDINGS.md) records what that showed for the AvenTech CRM (order list and dashboard slow down sharply past about 10,000 orders).

---

## ↩️ Undoing an install

```bash
sudo bash revert.sh --list        # show what PulseDeploy installed
sudo bash revert.sh               # dry run: shows what would be removed
sudo bash revert.sh --yes         # do it
```

Databases and Docker data are kept unless you add `--purge-data`. On a throw-away VM it is faster to restore the snapshot.

---

## 🩺 Troubleshooting

Every failure prints the function, file:line and command that stopped. The installer is safe to re-run after a fix. Logs: `/var/log/server-bootstrap.log`, `/var/log/pulsedeploy-crm.log`.

| Symptom | Likely cause and fix |
|---|---|
| `No match for argument: php8.x-...` | that PHP version is not in the repository: add `-P 8.2` (or `--php 8.2`) |
| certbot "not packaged" (Amazon Linux) | expected: leave `--certbot` out, use Cloudflare/ALB, or install certbot yourself |
| 502 from nginx | `pulse logs php` / `pulse logs nginx`; on RHEL-family with SELinux `Enforcing`, test with `sudo setenforce 0` and then add the right boolean |
| Build killed / out of memory | on 2 GB machines make sure swap is on (`swapon --show`) or build in CI |
| A host answers 444 or nothing | the `Host` name you used is not one of the configured hosts (check `/etc/hosts` on your PC) |
| Migration error about collation `utf8mb4_0900_ai_ci` | MariaDB lacks it; PulseDeploy sets `DB_COLLATION=utf8mb4_unicode_ci` on MariaDB, re-run the installer |
| `git clone` fails with a network error | retry (the installer retries and uses HTTP/1.1); for a private repo pass `--git-token-file` |
| Port 80 in use | stop the other web server (`sudo systemctl disable --now apache2` etc.) and re-run |

Need help? Send the last 40 terminal lines, both log files, `bash scripts/vm-check.sh` and `cat /etc/os-release`. More: [docs/testing-on-a-vm.md](docs/testing-on-a-vm.md).

---

## 📁 Project Structure

```
PulseDeploy/
├── bootstrap.sh              # Main entry point & interactive wizard
├── revert.sh                 # Roll back what bootstrap.sh installed (dry-run by default)
├── crm.sh                    # One command: pull, build, install and configure a CRM + storefront
├── apps/                     # CRM and storefront definitions (crm/, storefronts/)
├── bin/pulse                 # On-server CLI: deploy, rollback, status, logs, backup (laravel-next)
├── docs/                     # Guides: laravel-next, crm-installer, auditing, load-testing, VM testing, CRM findings
├── examples/github-actions/  # CI workflows that build and deploy the apps
├── loadtest/                 # Human-like load testing (run.sh, scenarios) and seed/ (realistic test data)
├── tests/run.sh              # Unit tests for helpers + CLI validation
├── scripts/
│   ├── audit.sh retune.sh vm-check.sh   # measure, fine-tune and pre-check a server
│   ├── lib/                  # Shared helpers (logging, validation, pkg/service/config, RAM-based tuning)
│   ├── os/                   # ubuntu.sh debian.sh amazon_linux.sh centos_rocky.sh
│   ├── stacks/               # lemp.sh lamp.sh node.sh laravel_next.sh
│   └── services/             # firewall redis docker certbot swap mysql php_tune
├── config/                   # Nginx / Apache templates, MySQL tuning
└── .github/workflows/ci.yml  # ShellCheck lint + tests
```

Every module is sourceable on its own (one file per concern, OS differences behind the `os_*` functions), for example `source scripts/os/ubuntu.sh; source scripts/services/redis.sh; install_redis` as root.

---

## 🔒 Security Defaults

- `server_tokens off`: Nginx/Apache version hidden
- Blocked access to `.env`, `.git`, `.sql`, `.log`, `.bak`, `.sh` files
- HTTP security headers: `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, `Referrer-Policy`
- fail2ban: 24-hour SSH ban after 3 failed attempts, Nginx + Apache jails (where the package exists)
- MySQL/MariaDB root password generated and saved to `/root/.my.cnf` (mode 600); the database listens on localhost only
- The firewall always keeps every SSH port open and never resets your existing rules
- PHP: `expose_php = Off`, production memory and upload limits
- Secrets are generated and written to root-only files, never printed to the log

---

## 🛡️ Reliability Notes

- **Verified, not assumed.** LEMP/LAMP run an end-to-end HTTP → PHP check with a throw-away file (no `phpinfo()` is left behind); Redis, Docker, MySQL and swap are each confirmed working before being reported as done.
- **Fails loudly.** Any failure prints the function, file:line and command, then exits non-zero.
- **Non-interactive by design.** Flags and env vars cover every wizard choice; with no terminal (cloud-init) it switches to non-interactive automatically.
- **Tests.** `bash tests/run.sh` (about 210 checks, no root, no network).

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
