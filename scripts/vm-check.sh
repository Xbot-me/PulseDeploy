#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - vm-check.sh: read-only readiness check for a fresh server
#   bash scripts/vm-check.sh
# Changes nothing. Prints PASS / WARN / FAIL for what the installer needs and
# exits non-zero if anything failed. Run it before the first install.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

PASS=0; WARN=0; FAIL=0
pass()  { PASS=$((PASS + 1)); printf '  %s %s\n' "${GREEN}PASS${RESET}" "$*"; }
warnc() { WARN=$((WARN + 1)); printf '  %s %s\n' "${YELLOW}WARN${RESET}" "$*"; }
fail()  { FAIL=$((FAIL + 1)); printf '  %s %s\n' "${RED}FAIL${RESET}" "$*"; }

# verdict <fail|warn> <message if ok> <message if not> <command...>
verdict() {
  local level="$1" okmsg="$2" badmsg="$3"
  shift 3
  if "$@"; then pass "$okmsg"; elif [[ "$level" == "fail" ]]; then fail "$badmsg"; else warnc "$badmsg"; fi
}

is_root()      { [[ "$(id -u)" -eq 0 ]]; }
known_arch()   { [[ "$1" == "x86_64" || "$1" == "aarch64" ]]; }
os_major_ge()  { [[ "$major" =~ ^[0-9]+$ && "$major" -ge "$1" ]]; }
# "reachable" = the server answered over HTTP (2xx, 3xx, or a plain 404)
http_ok()      { local c; c="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$1" 2>/dev/null || true)"; [[ "$c" =~ ^[23][0-9][0-9]$ || "$c" == "404" ]]; }
port_free()    { ! ss -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN; }
have()         { command -v "$1" &>/dev/null; }
clock_synced() { [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; }
selinux_ok()   { [[ "$(getenforce)" != "Enforcing" ]]; }

echo "${BOLD}System${RESET}"
major="${OS_VERSION%%.*}"
PKG_MANAGER=""
case "$OS_ID" in
  ubuntu) PKG_MANAGER=apt; verdict fail "Ubuntu $OS_VERSION" "Ubuntu $OS_VERSION is too old (need 20.04+)" os_major_ge 20 ;;
  debian) PKG_MANAGER=apt; verdict fail "Debian $OS_VERSION" "Debian $OS_VERSION is too old (need 11+)" os_major_ge 11 ;;
  amzn)
    PKG_MANAGER=dnf
    if [[ "$OS_VERSION" == "2023" ]]; then pass "Amazon Linux 2023"
    elif [[ "$OS_VERSION" == "2" ]]; then fail "Amazon Linux 2 cannot run current Node.js (glibc too old); use Amazon Linux 2023"
    else fail "Amazon Linux $OS_VERSION is not supported"; fi ;;
  centos|rocky|rhel|almalinux)
    PKG_MANAGER=dnf
    verdict fail "$OS_ID $OS_VERSION" "$OS_ID $OS_VERSION is too old (need 8+)" os_major_ge 8 ;;
  *) fail "Unsupported OS '$OS_ID'" ;;
esac
verdict warn "running as root" "not root (fine for this check; the installer needs root or sudo)" is_root
verdict fail "systemd is PID 1" "systemd is not running (container or WSL1?)" has_systemd
arch="$(uname -m)"
verdict warn "architecture $arch" "untested architecture $arch" known_arch "$arch"

ram="$(total_ram_mb)"
if ((ram >= 3500)); then pass "RAM ${ram}MB"
elif ((ram >= 1800)); then warnc "RAM ${ram}MB: works with swap (the stack adds it); 4GB is comfortable"
else fail "RAM ${ram}MB: 2GB is the minimum"; fi
free_gb=$(($(df -Pm / | awk 'NR == 2 { print $4 }') / 1024))
if ((free_gb >= 10)); then pass "free disk ${free_gb}GB on /"
elif ((free_gb >= 5)); then warnc "free disk ${free_gb}GB: builds need about 3GB, 10GB+ is comfortable"
else fail "free disk ${free_gb}GB on / is too little"; fi
if have getenforce; then
  verdict warn "SELinux $(getenforce)" "SELinux is Enforcing: expect to need booleans; Permissive is easiest for a first test" selinux_ok
fi
if have timedatectl; then
  verdict warn "clock is synchronised" "clock not reported as synchronised (TLS and package signatures need a correct time)" clock_synced
fi

echo "${BOLD}Tools${RESET}"
for t in git curl tar sudo runuser ss systemctl awk sed; do
  if [[ "$t" == "git" ]]; then
    hint="sudo apt-get install -y git"
    [[ "$PKG_MANAGER" == "dnf" ]] && hint="sudo dnf install -y git"
    verdict fail "git" "git is missing: install it first ($hint)" have git
  else
    verdict warn "$t" "$t not found" have "$t"
  fi
done
verdict warn "perl" "perl not found (only used to read Next.js configs; a fallback exists)" have perl

echo "${BOLD}Network${RESET}"
for u in https://github.com https://repo.packagist.org https://registry.npmjs.org; do
  verdict fail "$u reachable" "$u not reachable (firewall or proxy?)" http_ok "$u"
done
node_host="deb.nodesource.com"
[[ "$PKG_MANAGER" == "dnf" ]] && node_host="rpm.nodesource.com"
verdict fail "$node_host reachable (Node.js packages)" "$node_host not reachable" http_ok "https://$node_host"
verdict warn "getcomposer.org reachable (Composer, if not packaged)" "getcomposer.org not reachable: Composer must come from a package" http_ok "https://getcomposer.org/installer"

echo "${BOLD}Ports${RESET}"
for p in 80 443 3306 6379; do
  verdict warn "port $p free" "port $p is already in use" port_free "$p"
done

if [[ -n "$PKG_MANAGER" ]]; then
  echo "${BOLD}Packages this distribution offers${RESET} (from the configured repositories)"
  check_pkg() { # check_pkg <label> <required|optional> <names...>
    local label="$1" need="$2" n
    shift 2
    for n in "$@"; do
      if pkg_installed "$n" || pkg_available "$n"; then pass "$label: $n"; return 0; fi
    done
    if [[ "$need" == "required" ]]; then fail "$label: none of [$*] available"; else warnc "$label: none of [$*] available (that feature is skipped)"; fi
  }
  check_pkg "web server" required nginx
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    check_pkg "PHP" required php8.3-fpm php8.2-fpm php8.4-fpm php8.1-fpm
    check_pkg "database" required mysql-server mariadb-server
    check_pkg "cache" required redis-server
  else
    check_pkg "PHP 8.2+" required php8.4-fpm php8.3-fpm php8.2-fpm php-fpm
    check_pkg "database" required mariadb1011-server mariadb105-server mariadb-server mysql-server
    check_pkg "cache" required redis6 redis7 redis
    check_pkg "firewall" required firewalld
  fi
  check_pkg "certificates (or install certbot yourself)" optional certbot
  check_pkg "intrusion protection" optional fail2ban
fi

echo
echo "Result: ${GREEN}${PASS} pass${RESET}, ${YELLOW}${WARN} warn${RESET}, ${RED}${FAIL} fail${RESET}"
[[ "$FAIL" -eq 0 ]]
