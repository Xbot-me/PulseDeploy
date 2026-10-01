# Testing on a fresh VM (Amazon Linux 2023, or any supported distro)

Use a VM you can throw away, and take a snapshot before you start so every
attempt begins from the same clean state.

## 1. The VM

| Need | Why |
|---|---|
| Amazon Linux **2023** (not AL2) | AL2 cannot run current Node.js |
| 4 GB RAM (2 GB works with swap), 2 vCPU | MySQL/MariaDB + PHP + two Node apps + builds |
| 15 GB+ free disk | builds need about 3 GB |
| A bridged or NAT network with internet access | GitHub, Packagist, npm, NodeSource, package repos |
| systemd, root or sudo | services are managed with `systemctl` |

Take the snapshot **after** the OS is updated and SSH works.

## 2. Reach the apps without real DNS

The installer serves three host names. For a VM test you do not need public DNS:
add them to the `hosts` file of the machine whose browser you use, pointing at the VM's IP
(`ip -4 addr` on the VM). On Windows edit `C:\Windows\System32\drivers\etc\hosts`; on
macOS/Linux edit `/etc/hosts`:

```
192.168.1.50  api.crm.test  admin.crm.test  shop.crm.test
```

Use a name such as `crm.test` (not a real domain) and pass the three hosts
explicitly. Leave out `--certbot` and `--cloudflare`; certificates and Cloudflare are
tested later on a public server. URLs will be plain `http://`.

## 3. Prepare and check

```bash
sudo dnf install -y git
git clone https://github.com/Xbot-me/PulseDeploy.git && cd PulseDeploy
git checkout claude/quirky-lamport-fyksj1        # until the PR is merged

bash scripts/vm-check.sh                          # read-only: FAIL lines must be fixed first
bash tests/run.sh                                 # unit tests (optional; installs nothing)
```

`vm-check.sh` verifies the OS, RAM, disk, systemd, tools, outbound access and, on
dnf systems, that the PHP, database, Redis, nginx and firewalld packages exist. WARN
lines are usually fine (for example no `fail2ban` or `certbot` package on Amazon Linux
2023; the installer skips those).

For a private repository, put a read-only token in a file:
`sudo install -m 600 /dev/null /root/gh-token && sudo nano /root/gh-token`.

## 4. Dry run, then the real thing

```bash
sudo bash crm.sh install --domain crm.test --storefront none \
  --api-host api.crm.test --admin-host admin.crm.test --shop-host shop.crm.test \
  --git-token-file /root/gh-token --dry-run          # prints the plan
sudo bash crm.sh install --domain crm.test --storefront none \
  --api-host api.crm.test --admin-host admin.crm.test --shop-host shop.crm.test \
  --git-token-file /root/gh-token --check            # also proves the repos are readable

sudo bash crm.sh install --domain crm.test --storefront none \
  --api-host api.crm.test --admin-host admin.crm.test --shop-host shop.crm.test \
  --git-token-file /root/gh-token --store demo --store-name "Demo Store" \
  --admin-email admin@crm.test -y -- -P 8.2
```

Start with `--storefront none` so you test the server and the CRM first, then add a
storefront with `install --skip-server --only storefront --storefront <id>`.
`-P 8.2` (after `--`) pins PHP if the newer versions are not in the repository yet.

## 5. What to check

```bash
pulse status                           # services active, all three hosts HTTP 200
sudo cat /root/pulsedeploy-crm-credentials.txt
curl -s -H 'Host: api.crm.test' http://127.0.0.1/up -o /dev/null -w '%{http_code}\n'
```

Then in the browser: `http://admin.crm.test` and log in with the credentials file.
Also try: `sudo pulse backup`, `pulse rollback admin`, re-running the same
`crm.sh install ...` (must succeed without changing the store), and
`sudo bash revert.sh --stack --yes --no-confirm` followed by a revert to your snapshot.

## 6. When something fails

Send back: the last 40 lines of the terminal, `/var/log/server-bootstrap.log`,
`/var/log/pulsedeploy-crm.log`, `bash scripts/vm-check.sh`, and `cat /etc/os-release`.
Every failure prints the function, file:line and command that stopped, and the installer
is safe to re-run after a fix.

| Symptom | Likely cause |
|---|---|
| "No match for argument: php8.x-..." | that PHP version is not in the repository: pass `-- -P 8.2` |
| certbot "not packaged" | expected on Amazon Linux 2023: leave `--certbot` out |
| nginx or PHP 502 | check `pulse logs nginx` / `pulse logs php`; with SELinux Enforcing try `sudo setenforce 0` to confirm |
| build killed / out of memory | 2 GB VM: make sure swap is on (`swapon --show`), or build in CI |
| a host answers 444 or nothing | the browser's `Host` name is not one of the three configured hosts |
