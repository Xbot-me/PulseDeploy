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

**On this page:** [What you get](#-what-you-get) · [Supported systems](#-supported-operating-systems) · [Before you start](#-before-you-start-every-os) · [Install on Ubuntu / Debian](#-install-on-ubuntu--debian) · [Install on Amazon Linux 2023](#-install-on-amazon-linux-2023-aws-ec2-or-a-vm) · [Install on Rocky / Alma / CentOS](#-install-on-rocky--alma--centos--rhel) · [Working from Windows or macOS](#-working-from-windows-or-macos) · [Stacks](#-the-stacks) · [Options](#-every-option) · [After installing](#-after-installing) · [Operating the server](#-operating-the-server) · [Laravel + Next.js](#-laravel--nextjs-in-detail) · [CRM in one command](#-one-command-the-crm) · [Testing on a VM](#-testing-on-a-vm) · [Auditing and tuning](#-auditing-and-tuning) · [Load testing and benchmarks](#-load-testing-and-benchmarks) · [Recent changes](#-recent-changes) · [Undo](#-undoing-an-install) · [Troubleshooting](#-troubleshooting)

---

## ✨ What you get

| Category       | What's included |
|----------------|----------------|
| **Stacks**     | LEMP (Nginx + PHP-FPM + MySQL/MariaDB), LAMP (Apache + PHP + MySQL/MariaDB), Node.js + PM2 + Nginx reverse proxy, **Laravel + Next.js** (API + admin + storefront on one small server, see [Laravel + Next.js in detail](#-laravel--nextjs-in-detail)) |
| **One-command CRM** | `crm.sh` pulls, builds and configures the AvenTech CRM (Laravel API + Next.js admin, multi-tenant) with a chosen storefront ([details](#-one-command-the-crm)) |
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

Not on AWS? A VMware/VirtualBox/Proxmox VM running Amazon Linux 2023 works the same way: see [Testing on a VM](#-testing-on-a-vm) (host names without real DNS, snapshots, what to check).

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

The load-test module (`loadtest/run.sh`) is designed to run from your PC, not from the server, and works in Git Bash on Windows. Full steps: [Load testing and benchmarks](#-load-testing-and-benchmarks).

Do not try to run `bootstrap.sh` on Windows or macOS: it installs system packages and manages services, and refuses to run on anything but a supported Linux.

---

## 🧱 The stacks

| `--stack` | Installs | Typical use |
|---|---|---|
| `lemp` | Nginx, PHP-FPM, MariaDB/MySQL | PHP sites, WordPress, Laravel on a classic server |
| `lamp` | Apache, PHP, MariaDB/MySQL | Apache-only PHP apps |
| `node` | Node.js, PM2, Nginx reverse proxy | any Node app on `--app-port` |
| `laravel-next` | Nginx, PHP-FPM, MariaDB/MySQL, Redis, Node, systemd services for the API, queue worker, scheduler and two Next.js apps, backups, `pulse` CLI | Laravel API + Next.js admin + storefront on one 2-8 GB server ([details](#-laravel--nextjs-in-detail), [CRM in one command](#-one-command-the-crm)) |
| `none` | core only (updates, selected services) | you bring your own application layer |

`crm.sh install` is `laravel-next` plus pulling the CRM and storefront code, building them, creating the first store and running smoke tests ([details](#-one-command-the-crm)). `bash crm.sh storefronts` lists the storefronts you can choose.

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

## 🧪 Laravel + Next.js in detail

`--stack laravel-next` sets up one VPS for a Laravel API, a Next.js admin dashboard and a Next.js storefront, tuned for a low monthly bill: about 4 GB of RAM is comfortable, 2 GB works with swap.

| Host (default) | Served by |
|---|---|
| `api.<domain>` | nginx, PHP-FPM (Laravel) |
| `admin.<domain>` | nginx, Next.js on `127.0.0.1:3001` (systemd) |
| `<domain>` | nginx, Next.js on `127.0.0.1:3000` (systemd) |

Also installed: MariaDB/MySQL (tuned), Redis (cache, sessions, queues, loopback only), a queue worker and a scheduler timer (systemd), a `deploy` user, a firewall, fail2ban, automatic security updates, nightly database backups and the `pulse` command. Override host names with `--api-host`, `--admin-host`, `--shop-host`.

**Why it is cheap to run:** PHP-FPM `ondemand` (idle RAM close to zero); the database sized for a shared box (buffer pool about 18% of RAM, performance schema off, 50-100 connections); Next.js `standalone` output under systemd (no PM2, a memory cap per app); nginx serves `/_next/static` from disk and caches optimised images; Cloudflare in front with `--cloudflare` restores real visitor IPs; builds belong in CI, not on the server.

| Server RAM | php-fpm workers | Database buffer pool | Redis | Node heap (admin / shop) |
|---:|---:|---:|---:|---|
| 2 GB | 6 | 384 MB | 122 MB | 256 / 256 MB |
| 4 GB | 13 | 768 MB | 245 MB | 256 / 384 MB |
| 8 GB | 27 | 1 GB | 491 MB | 384 / 512 MB |

Useful options: `--tenant-db-prefix P` (apps with one database per tenant: the DB user may create and manage databases named `P*`, and only those), `--serve-storage` (nginx serves `/storage/*` straight from the Laravel public disk), `--no-queue` / `--no-scheduler`.

**Deploying** is done with `pulse`, as the `deploy` user:

```bash
pulse deploy api   --artifact api.tar.gz        # or: --git URL --ref main
pulse deploy admin --artifact admin.tar.gz
pulse deploy shop  --artifact shop.tar.gz
pulse rollback api                              # previous release, instantly
pulse status                                    # services, releases, health, disk, RAM
pulse logs queue -f                             # api | admin | shop | queue | scheduler | php | nginx
sudo pulse backup                               # also nightly at about 03:xx
sudo pulse restore /var/backups/pulsedeploy/db-....sql.gz --yes
```

Each deploy builds a new directory under `releases/`, links the shared `.env` and `storage`, runs migrations (the central database **and, for multi-tenant apps that provide a `tenants:migrate` command, every tenant database**; a failure there stops the deploy before the release goes live), caches, then switches `current` atomically. If the new release fails its health check, `pulse` switches back. The last 5 releases are kept. For Next.js, set `output: 'standalone'` and package `server.js`, `.next/`, `public/` and `node_modules/` at the archive root (`examples/github-actions/` has complete workflows); `NEXT_PUBLIC_*` values are baked in at build time.

Operating notes: backups live in `/var/backups/pulsedeploy` (root only, 7 days); set `RCLONE_REMOTE` in `/etc/pulsedeploy/pulse.conf` to copy them off the server and `HEALTHCHECK_URL` to be alerted when one does not run. The web processes run as `deploy`, which keeps permissions simple on a single-tenant server but means a compromised app can rewrite its own code. Re-running the installer is safe; undo with `sudo bash revert.sh --stack`.

---

## 🚀 One command: the CRM

`crm.sh` provisions the server, pulls the AvenTech CRM (Laravel 11 API + Next.js admin, multi-tenant) and the storefront you choose from Git, builds and deploys them, creates the first store and checks that everything answers.

```bash
sudo bash crm.sh install --domain example.com --email you@example.com --certbot --cloudflare \
  --storefront <id | git-url | none> \
  --store acme --store-name "Acme Shop" --admin-email you@example.com \
  --git-token-file /root/gh-token \
  -- --timezone Asia/Dhaka --swap-size 2G
```

What it does, in order:

1. **Validates** every option and checks each repository and branch is reachable before anything changes (`--check`, `--dry-run` stop here).
2. **Provisions the server** with `bootstrap.sh --stack laravel-next` (database `aventech_crm` / user `aventech`, rights on `aventech_tenant_*` only, uploads served by nginx).
3. **Pulls, builds and deploys** the backend (`composer install`), the admin app and the storefront (`npm ci && npm run build`, standalone output). Builds run as the unprivileged deploy user; each deploy is an atomic release that rolls back if the health check fails.
4. **Creates the first store** with the CRM's production command `store:provision`: a strong random owner password (read from a root-owned temp file, never from the command line, deleted afterwards), no moderator or development accounts, an empty or starter catalog (`--catalog none|starter|demo`, default `starter`; `demo` needs `--demo <slug>`; `--vertical` picks the catalog profile). The result is one JSON object the installer reads; the password goes to `/root/pulsedeploy-crm-credentials.txt` (root only), never to the log. An existing store is left alone and its credentials are not rewritten. The store slug is 2-40 lower-case letters, digits and dashes, starting with a letter.
5. **Smoke-tests** the API, a real read of the store's database through the API, the admin (including a real login), the storefront, the scheduler timer and, with `--certbot`, the certificates. **If any check fails the command lists exactly which, prints no success banner and exits non-zero**, so CI and scripts notice.

A new gadget-shop client in one command (the storefront lives in the CRM repository; the store slug is compiled into the builds, so one install serves one client):

```bash
sudo bash crm.sh install --domain client.example --email you@example.com --certbot \
  --storefront gadgets --store voltgadgets --store-name "Volt Gadgets" \
  --admin-email owner@client.example --git-token-file /root/gh-token
```

**Choosing a storefront:** `bash crm.sh storefronts` lists them. `--storefront <id>` uses a definition in `apps/storefronts/<id>.conf` (copy `sample.conf.disabled`); `--storefront <git-url>` takes any Next.js repository (add `--storefront-ref`, `--storefront-dir`, `--storefront-build-cmd` and repeatable `--storefront-build-env` / `--storefront-runtime-env KEY=value`, with `{API_URL} {ADMIN_URL} {SHOP_URL} {INTERNAL_API_URL} {STORE} {STORE_NAME} {DOMAIN}` available); `none` installs the CRM only. If the storefront does not use `output: "standalone"`, the installer turns it on for the build.

**Private repositories:** `--git-token-file FILE` (or `PULSE_GIT_TOKEN`; passed through the environment, never a command line) or `--git-ssh-key FILE` for `git@` URLs.

**Day two:**

```bash
sudo pulse-crm update                          # pull, rebuild and redeploy everything
sudo pulse-crm update --only backend,admin     # or: storefront --storefront-ref v1.4.0
```

`update` remembers the install choices (`/etc/pulsedeploy/crm.conf`, which also records the CRM and PulseDeploy commits that were deployed). Other flow options: `--skip-server`, `--only backend,admin,storefront`, `--crm-repo` / `--crm-ref`, `--reset-env`; everything after `--` goes to `bootstrap.sh`. Building on the server needs memory: Node's heap is sized from RAM and the stack enables swap on 4 GB or less; for very small servers build in CI and use `pulse deploy`.

**If GitHub downloads keep breaking part-way** (`curl 56`, `curl 92`, `early EOF`): the installer already retries three times with HTTP/1.1. On VM/NAT networks large packets can vanish while ICMP is filtered; `sudo sysctl -w net.ipv4.tcp_mtu_probing=1` (and the same line in `/etc/sysctl.d/99-mtu-probing.conf`) fixes the common case. Or bring the repository over as a bundle (`git bundle create`, `scp`, clone on the server) and pass `--crm-repo file:///srv/crm`.

---

## 🖥️ Testing on a VM

Use a machine you can throw away and take a snapshot after the OS is updated. Amazon Linux **2023** needs 4 GB RAM (2 GB works with swap), 2 vCPU, 15 GB+ disk and internet access. Without real DNS, add the three host names to the hosts file of the machine whose browser or load generator you use (`C:\Windows\System32\drivers\etc\hosts` as Administrator on Windows, `/etc/hosts` elsewhere): `192.168.1.50  api.crm.test admin.crm.test shop.crm.test`, then pass `--api-host api.crm.test --admin-host admin.crm.test --shop-host shop.crm.test`. Leave out `--certbot` and `--cloudflare`. `scripts/vm-check.sh` is a read-only readiness check. After the install try `pulse status`, `sudo pulse backup`, `pulse rollback admin`, and re-run the same `crm.sh install ...` (it must succeed without changing the store).

---

## 📈 Auditing and tuning

```bash
sudo pulse-crm audit                  # or: sudo bash scripts/audit.sh [--load] [--no-perf]
sudo pulse-crm retune [--apply]       # apply hand-tuned values from /etc/pulsedeploy/tuning.conf
```

The audit is **read-only**; each line is `PASS`, `WARN`, `FAIL`, `INFO` or `SKIP` with the measured value next to its target, and it exits 1 when anything failed, so it works in a monitoring job. It checks that the server (1) matches its own tuning (PHP-FPM pool, OPcache, InnoDB buffer pool, connections, Redis memory and policy, Node heap and `MemoryMax`, nginx), (2) behaves well when measured (available memory, swap, buffer-pool hit ratio, temp tables on disk, slow queries, Redis evictions, Node restarts, response times from the server itself, compression and asset caching, Laravel release state, optional load burst), and (3) is hardened (only SSH, 80 and 443 public; databases and Redis loopback only; firewall and fail2ban active; file permissions; backup freshness; disk and inode use). Thresholds marked *guideline* are starting points (`AUDIT_P95_MS`, `AUDIT_SAMPLES`). Tune in a loop: measure a realistic load, change one thing, measure again; hand-tuned values go in `/etc/pulsedeploy/tuning.conf` and survive re-runs.

---

## 🔬 Load testing and benchmarks

Three tools, used together. An empty database always looks fast, so **seed first**.

| Tool | Runs on | What it does |
|---|---|---|
| `loadtest/run.sh` | a **separate** machine (your PC or a second VM) | human-like traffic with [Locust](https://locust.io): people log in once, think (log-normal pauses), click, sometimes leave half-way, and a new person arrives later; cold and warm browser caches; a pass/fail verdict |
| `loadtest/seed/seed.sh` | the server | realistic products, customers and orders as plain SQL, any CRM version; refuses the live store; `--purge` removes exactly what it added |
| `pulse-bench` | the server | seeds the CRM's own dataset, lifts the rate limits for a run, records the server's side and compares runs |

```bash
# from your PC (Git Bash on Windows), not from the server being tested
bash loadtest/run.sh --ip <server-ip> --domain crm.test --store loadtest \
     --email owner@crm.test --password-file ~/lt-password \
     --profile average --users 20 --hold 600
```

Profiles: `smoke`, `average`, `peak`, `spike`, `soak`, `breakpoint` (adds users in steps until a limit breaks). The run **fails** when more than `--max-fail` (1%) of requests fail or any endpoint's p95 exceeds `--p95-ms` (1500 ms). `--time-scale 0.25` makes everyone click four times faster. Scenarios are JSON files in `loadtest/scenarios/` (`aventech-admin`, `aventech-storefront`); `bash loadtest/run.sh --check ...` validates one without sending traffic. Safety: it asks you to type the target's name, writes no data unless `--writes`, caps users at 200 without `--allow-large`, tags every request `X-Load-Test`, and reads the password from a file. Logins are throttled by the CRM (5 a minute per account), so people on one account share one login unless you pass `--accounts-file` (one `email:password` per line). Only test servers you own.

**One benchmark, step by step** (on the server, against a disposable store, never a client's):

```bash
sudo bash loadtest/seed/seed.sh --store loadtest --create-store --no-data   # an empty store with plan "loadtest"
sudo pulse-bench seed loadtest --profile small --seed 42                       # small 10k orders, medium 200k, large 1M (+ reviews and behaviour events)
sudo pulse-bench throttles off --for 120                                       # optional: lift the per-IP rate limits (restores itself)
sudo pulse-bench record start L-001 --note "what this run is"
#   ... run loadtest/run.sh from your PC, then copy loadtest/results/<time>/summary.json to the server (scp file user@server:) ...
sudo pulse-bench record stop --results ~/summary.json                          # writes benchmark-L-001.json and .md
sudo pulse-bench throttles on
sudo pulse-bench diff /var/lib/pulsedeploy/bench/L-001/benchmark-L-001.json /var/lib/pulsedeploy/bench/L-002/benchmark-L-002.json
```

`pulse-bench throttles off` sets `LOADTEST_MODE=true` and `APP_ENV=staging` (the CRM ignores the switch in production on purpose), rebuilds the config cache and reloads PHP-FPM; `on` restores the original `.env` byte for byte, and a systemd timer does the same after `--for` minutes. `record` snapshots the VM, versions, deployed commits, database/PHP/OPcache/Redis/nginx settings and the dataset; samples CPU, I/O wait, steal, swap, memory, PHP workers, Node memory and database threads during the run; reads nginx request times per log (API, loopback API, admin, storefront); counts database and Redis activity; lists every query slower than 200 ms; and merges the load generator's results. `diff` prints only what differs, so two runs are comparable when that list is just the change under test. Add results from a forgotten run later with `sudo pulse-bench record attach <id> --results summary.json`.

What this does not tell you: it is server-side load, not a browser (JavaScript is not run); think times are a model (set them from your analytics); all traffic comes from one address; and a slow endpoint with no slow query is a PHP problem to profile, not to guess.

### Results so far: AvenTech CRM on 2 vCPU / 4 GB

Amazon Linux 2023 on a VMware VM, MariaDB 10.11, PHP 8.4. Every run: `--profile breakpoint --time-scale 0.25 --step-users 10 --step-seconds 120` against the admin scenario, rate limits lifted. At four times normal speed, 150 users is roughly 600 ordinary staff. Client p95 values are Locust's rounded buckets.

| Run | CRM version | Data | Requests | Failed | Worst p95 | Dashboard p95 | Orders list p95 | CPU peak | Outcome |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| L-002 | before the reporting changes | 10k orders | 54,598 | 0 | 670 ms | 670 ms | 390 ms | 97% | PASS, no breakpoint found |
| L-003 | before the reporting changes | 200k orders | 676 | 0 | 17,000 ms | 17,000 ms | 11,000 ms | 100% | FAIL at the first step (about 10 users) |
| L-004 | indexes + cache + no stampede | 200k orders | 55,800 | 0 | 790 ms | 600 ms | 360 ms | 100% | PASS, no breakpoint found |

L-003 stopped after 515 s at its first step while L-004 ran every step up to 150 users for 37 minutes, so the improvement is larger than the table suggests. Server side in L-004: nginx API p50 82 ms, p95 355 ms, p99 963 ms; 359,586 database queries of which 1,474 slower than 200 ms (all cache refreshes); Redis 29,372 commands with 13,188 hits and 16 misses; peak memory 2.3 GB of 3.9 GB, no swap, no I/O wait.

**Findings**

1. **Data volume, not server tuning, was the limit.** With 10,000 orders the 2 vCPU box coped with a heavy mixed load. With 200,000 orders the admin dashboard and order list recomputed whole-table aggregates on every request, saturating both CPUs at about 10 users. Tuning PHP, the database and Redis does not fix that.
2. **The fix was in the application:** covering indexes for the reporting queries, a short (30 s) cache for the heavy aggregates on large stores, and a lock so that when the cache entry expires one request refreshes it while the others get the previous value. A plain 30 s `Cache::remember` would let every concurrent request recompute at expiry (a cache stampede). Result: p95 of the heavy pages fell from 11-17 s to 0.4-0.8 s.
3. **What is left:** the p99 of the dashboard (2.0 s) and the status-filtered list (1.5 s) are people who arrive while a refresh runs, and CPU still touches 100% at the top of the ramp. No step failed, so this server's real breakpoint has not been found yet (next: `--max-users 400` or the `large` profile). Ideas: refresh the cache from the scheduler so nobody waits, a longer cache for very large stores, a cheaper "new versus repeat customers" figure.
4. **Redis was idle before the change** (113 commands in a whole run); it now does real work. If your admin endpoints are not cached at all, that is the first place to look.

---

## 🔧 Recent changes

* **`crm.sh`:** smoke failures now fail the install (named, non-zero exit, no success banner) with new checks (real tenant read, scheduler timer, store name on the API and storefront, certificate validity); the first store is created with `store:provision` (password by file, JSON result, `--catalog` / `--demo` / `--vertical`); the CRM definition uses the CRM's database names and trusts only the local nginx for client IPs; the scheduler stays on; a gadget-shop storefront definition (`--storefront gadgets`); the CRM and PulseDeploy commits are recorded in `/etc/pulsedeploy/crm.conf`; `jq` is installed with the base packages.
* **`pulse deploy api`:** also runs `tenants:migrate` when the app has it, so existing stores receive later migrations; a failure aborts the deploy before the release is live.
* **Installer fixes found by real runs:** the app user now owns the whole `storage/` tree (parent directories used to stay root-owned, so the app could not write to `storage/app`); nginx access logs carry the request time, including the loopback API that the admin and storefront call (its log used to be off); the Redis version is read from `INFO` (Amazon Linux's `redis6`).
* **New tools:** `pulse-bench` (seed, rate-limit switch, benchmark records, `diff`, `attach`), `loadtest/seed/seed.sh` (SQL test data with `--no-data`, `--purge`), the human-like load generator (`loadtest/run.sh`) and its scenarios; the admin scenario no longer calls an order-detail URL the CRM does not have.
* **README and OS guides:** per-OS install steps for Ubuntu/Debian, Amazon Linux 2023 and Rocky/Alma/CentOS, plus Windows and macOS client notes.

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

Need help? Send the last 40 terminal lines, both log files, `bash scripts/vm-check.sh` and `cat /etc/os-release`. More: [Testing on a VM](#-testing-on-a-vm).

---

## 📁 Project Structure

```
PulseDeploy/
├── bootstrap.sh              # Main entry point & interactive wizard
├── revert.sh                 # Roll back what bootstrap.sh installed (dry-run by default)
├── crm.sh                    # One command: pull, build, install and configure a CRM + storefront
├── apps/                     # CRM and storefront definitions (crm/, storefronts/)
├── bin/pulse                 # On-server CLI: deploy, rollback, status, logs, backup (laravel-next)
├── bin/pulse-bench              # On-server load-test helper: seed, rate-limit switch, benchmark records, diff
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
