# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | ✅ Yes    |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

If you discover a security issue in PulseDeploy — for example, a script that exposes credentials, creates insecure file permissions, or opens unintended network access — please report it responsibly:

1. Go to the [Security tab](https://github.com/Xbot-me/PulseDeploy/security/advisories/new) and open a **private advisory**
2. Or contact the maintainer directly via GitHub: [@Xbot-me](https://github.com/Xbot-me)

Please include:
- A description of the vulnerability
- The affected script(s) and line numbers
- Steps to reproduce or a proof-of-concept
- The potential impact

## What to Expect

- **Acknowledgement** within 48 hours
- **Assessment and fix** within 7 days for critical issues
- Credit in the fix commit if you'd like it

## Security Design Notes

PulseDeploy follows these practices by default:

- MySQL root passwords are auto-generated (20 chars, mixed case + symbols) and saved to `/root/.my.cnf` with `chmod 600`
- Nginx and Apache configs block access to `.env`, `.git`, `.sql`, `.log`, `.bak`, `.sh` files
- fail2ban is configured with aggressive SSH rules (3 retries → 24h ban)
- `server_tokens off` / `ServerTokens Prod` hide version info from HTTP responses
- PHP `expose_php = Off` prevents version disclosure
- Docker daemon configured with log rotation and `live-restore` only — no privileged defaults

If you believe any of these defaults could be stronger, please open a regular issue or PR.