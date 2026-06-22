# 🖥️ server-bootstrap

> **One-command VPS & AWS server setup automation** — LEMP · LAMP · Node.js · Docker · Redis · SSL · Firewall

[![CI](https://github.com/Xbot-me/server-bootstrap/actions/workflows/ci.yml/badge.svg)](https://github.com/Xbot-me/server-bootstrap/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-f97316?style=flat-square)](LICENSE)
[![Bash](https://img.shields.io/badge/Bash-5.x-f97316?style=flat-square&logo=gnubash)](https://www.gnu.org/software/bash/)

A modular, interactive Bash automation toolkit for bootstrapping production-ready Linux servers on VPS providers (Hetzner, DigitalOcean, Linode, Vultr) and **AWS EC2** — with full multi-distro support.

```
  ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗
  ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗
  ███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝
  ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗
  ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║
  ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝
```

---

## ✨ Features

| Category      | What's included |
|---------------|----------------|
| **Stacks**    | LEMP (Nginx + PHP-FPM + MySQL), LAMP (Apache + PHP + MySQL), Node.js + PM2 + Nginx reverse proxy |
| **PHP**       | Version selector (8.1 / 8.2 / 8.3), OPcache JIT, PHP-FPM pool auto-tuning based on RAM |
| **Security**  | UFW / firewalld, fail2ban (SSH + Nginx + Apache rules), secure file blocking in web configs |
| **SSL**       | Certbot (Let's Encrypt) with auto-renewal cron |
| **Caching**   | Redis with Unix socket or TCP, maxmemory auto-calculated, allkeys-lru policy |
| **Containers**| Docker Engine + Docker Compose v2, log rotation, weekly prune cron |
| **Swap**      | Auto-sized swap file based on detected RAM, swappiness=10 tuning |
| **Logging**   | Full install log at `/var/log/server-bootstrap.log` |

---

## 🐧 Supported Operating Systems

| Distro                          | Package Manager | Notes |
|---------------------------------|-----------------|-------|
| Ubuntu 20.04 / 22.04 / 24.04   | apt             | Full support |
| Debian 11 (Bullseye) / 12 (Bookworm) | apt        | Full support |
| Amazon Linux 2 / 2023           | dnf             | AWS-aware: Security Group hints, IMDSv2 detection |
| CentOS 8 / Rocky Linux 8 & 9   | dnf             | SELinux awareness, Remi repo for PHP |

---

## 🚀 Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/Xbot-me/server-bootstrap.git
cd server-bootstrap

# 2. Make executable
chmod +x bootstrap.sh scripts/**/*.sh

# 3. Run as root
sudo bash bootstrap.sh
```

The interactive wizard will guide you through:
1. Auto-detect your OS and version
2. Stack selection (LEMP / LAMP / Node.js / skip)
3. Optional services toggle (Redis, Docker, Firewall, SSL, Swap, PHP tuning)
4. Summary confirmation before any changes are made

---

## 📁 Project Structure

```
server-bootstrap/
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

When running on Amazon Linux 2 / 2023, the script automatically:
- Detects the EC2 instance via **IMDSv2**
- Warns you to open **ports 80/443/22** in your **Security Group** (firewalld rules alone are not enough on AWS)
- Uses `firewalld` instead of `ufw`
- Falls back to MariaDB if MySQL repo is unavailable

**Recommended EC2 setup before running:**
```bash
# On your local machine — open required ports via AWS CLI
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
```

---

## 🔒 Security Defaults

Every stack installs with:
- `server_tokens off` (hides version info)
- Block rules for `.env`, `.git`, `.sql`, `.log`, `.bak`, `.sh` files
- `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection` headers
- fail2ban with 24-hour SSH ban after 3 failed attempts
- MySQL root password auto-generated and saved to `/root/.my.cnf` (chmod 600)

---

## 🧩 Running Individual Modules

You can source and run any module standalone:

```bash
# Install only Redis on an existing server
source scripts/os/ubuntu.sh   # or debian.sh / amazon_linux.sh
source scripts/services/redis.sh
install_redis

# Just tune PHP-FPM
source scripts/os/ubuntu.sh
source scripts/services/php_tune.sh
tune_php_fpm
```

---

## 📋 Post-Install Checklist

- [ ] Delete `/var/www/html/info.php` (PHP info test page)
- [ ] Run `certbot --nginx -d yourdomain.com` to issue SSL certificate
- [ ] Point domain DNS A record to your server IP
- [ ] Review fail2ban status: `fail2ban-client status sshd`
- [ ] Check UFW/firewalld rules: `ufw status` or `firewall-cmd --list-all`
- [ ] Test Redis: `redis-cli ping`
- [ ] On AWS: verify Security Group rules in the AWS Console

---

## 📜 License

MIT — free to use, fork, and adapt for your own server setups.

---

> Built by [@Xbot-me](https://github.com/Xbot-me) · `build it · break it · fix it · automate it`