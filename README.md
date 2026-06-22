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
| **Stacks**     | LEMP (Nginx + PHP-FPM + MySQL), LAMP (Apache + PHP + MySQL), Node.js + PM2 + Nginx reverse proxy |
| **PHP**        | Version selector (8.1 / 8.2 / 8.3), OPcache JIT, PHP-FPM pool auto-tuning based on RAM |
| **Security**   | UFW / firewalld, fail2ban (SSH + Nginx + Apache rules), secure file blocking in web configs |
| **SSL**        | Certbot (Let's Encrypt) with auto-renewal cron |
| **Caching**    | Redis with Unix socket or TCP, maxmemory auto-calculated, allkeys-lru policy |
| **Containers** | Docker Engine + Docker Compose v2, log rotation, weekly prune cron |
| **Swap**       | Auto-sized swap file based on detected RAM, swappiness=10 tuning |
| **Logging**    | Full install log saved to `/var/log/pulsedeploy.log` |

---

## 🐧 Supported Operating Systems

| Distro                               | Package Manager | Notes |
|--------------------------------------|-----------------|-------|
| Ubuntu 20.04 / 22.04 / 24.04        | apt             | Full support |
| Debian 11 (Bullseye) / 12 (Bookworm)| apt             | Full support |
| Amazon Linux 2 / 2023               | dnf             | AWS-aware: Security Group hints, IMDSv2 detection |
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

---

## 📁 Project Structure

```
PulseDeploy/
├── bootstrap.sh              # Main entry point & interactive wizard
├── scripts/
│   ├── os/                   # OS-specific package management
│   │   ├── ubuntu.sh
│   │   ├── debian.sh
│   │   ├── amazon_linux.sh   # AWS-aware (IMDSv2, Security Group hints)
│   │   └── centos_rocky.sh   # SELinux-aware
│   ├── stacks/               # Web stack installers
│   │   ├── lemp.sh           # Nginx + PHP-FPM + MySQL
│   │   ├── lamp.sh           # Apache + PHP + MySQL
│   │   └── node.sh           # Node.js + PM2 + Nginx proxy
│   └── services/             # Optional service installers
│       ├── firewall.sh       # UFW / firewalld + fail2ban
│       ├── redis.sh          # Redis with socket/TCP option
│       ├── docker.sh         # Docker Engine + Compose v2
│       ├── certbot.sh        # Let's Encrypt SSL + auto-renewal
│       ├── swap.sh           # Auto-sized swap file
│       └── php_tune.sh       # PHP-FPM + OPcache + php.ini tuning
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
- Falls back to MariaDB if the MySQL repo is unavailable

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

Every module is independently sourceable — no need to run the full wizard:

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

- [ ] Delete `/var/www/html/info.php` after verifying PHP works
- [ ] Run `certbot --nginx -d yourdomain.com` to issue SSL certificate
- [ ] Point your domain DNS A record to your server IP
- [ ] Review fail2ban: `fail2ban-client status sshd`
- [ ] Check firewall rules: `ufw status` or `firewall-cmd --list-all`
- [ ] Test Redis: `redis-cli ping` → should return `PONG`
- [ ] On AWS: verify Security Group rules in the AWS Console

---

## 🗺️ Roadmap

- [ ] `--non-interactive` flag mode for cloud-init / user-data bootstrapping
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
