#!/usr/bin/env bash
# =============================================================================
# PulseDeploy - shared helpers (logging, validation, packages, services, config)
# Safe to source more than once and from standalone module usage.
# =============================================================================
# shellcheck disable=SC2034  # Variables here are consumed by sourcing scripts
[[ -n "${PULSE_COMMON_LOADED:-}" ]] && return 0
PULSE_COMMON_LOADED=1

PULSE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$PULSE_LIB_DIR/../.." && pwd)}"

# os_release_value <KEY> - read one field of /etc/os-release without sourcing it
os_release_value() {
  awk -F= -v k="$1" '$1 == k { v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v); print v; exit }' \
    /etc/os-release 2>/dev/null || true
}

# Detect OS facts for standalone module use (bootstrap.sh sets them too).
if [[ -z "${OS_ID:-}" && -r /etc/os-release ]]; then
  OS_ID="$(os_release_value ID)"
  OS_VERSION="$(os_release_value VERSION_ID)"
  OS_VERSION="${OS_VERSION:-unknown}"
fi
OS_ID="${OS_ID:-unknown}"
OS_VERSION="${OS_VERSION:-unknown}"

# ── Colours (real escape bytes, so they work in heredocs and printf alike) ────
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
# bootstrap.sh tees stdout+stderr into the log file, so these just print.
log()     { printf '%s\n' "${GREEN}[✔]${RESET} $*"; }
info()    { printf '%s\n' "${CYAN}[i]${RESET} $*"; }
warn()    { printf '%s\n' "${YELLOW}[⚠]${RESET} $*" >&2; }
error()   { printf '%s\n' "${RED}[✘]${RESET} $*" >&2; exit 1; }
section() { printf '\n%s\n\n' "${BOLD}${BLUE}━━━ $* ━━━${RESET}"; }

# ── Generic helpers ───────────────────────────────────────────────────────────
# retry <tries> <delay-seconds> <command...>
retry() {
  local tries="$1" delay="$2" i
  shift 2
  for ((i = 1; i <= tries; i++)); do
    if "$@"; then return 0; fi
    if ((i < tries)); then
      warn "Command failed (attempt $i/$tries): $* - retrying in ${delay}s"
      sleep "$delay"
    fi
  done
  warn "Giving up after $tries attempts: $*"
  return 1
}

# Random alphanumeric password. Deliberately avoids `tr … | head -c N` on
# /dev/urandom: under `set -o pipefail` that pipeline dies with SIGPIPE (141).
generate_password() {
  local len="${1:-24}" out=""
  while ((${#out} < len)); do
    out+="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:len}"
}

# First non-loopback IPv4 address, with fallbacks; never fails.
primary_ip() {
  local ip=""
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  if [[ -z "$ip" ]] && command -v ip &>/dev/null; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')" || true
  fi
  printf '%s' "${ip:-127.0.0.1}"
}

total_ram_mb() { awk '/^MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo; }

# Recommended swap size for the machine's RAM (e.g. "2G")
swap_suggest_size() {
  local ram_mb="${1:-$(total_ram_mb)}"
  if   ((ram_mb <= 512));  then echo "1G"
  elif ((ram_mb <= 2048)); then echo "2G"
  elif ((ram_mb <= 8192)); then echo "4G"
  else                          echo "8G"
  fi
}

# download <url> <dest> - fails loudly, retries transient errors
download() {
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1"
}

# backup_file <path> - keep the ORIGINAL once, never overwrite the backup
backup_file() {
  if [[ -e "$1" && ! -e "$1.pulsedeploy.bak" ]]; then
    cp -a "$1" "$1.pulsedeploy.bak"
  fi
  return 0
}

# conf_set <file> <key> <value> [separator]
# Idempotently set a "key<sep>value" directive:
#   • replaces every active `key…` line;
#   • else inserts the directive right after the first commented example;
#   • else appends it.
# Values pass through the environment so backslashes/pipes/ampersands are safe.
conf_set() {
  local file="$1" key="$2" value="$3" sep="${4:- }" tmp
  [[ -f "$file" ]] || return 1
  tmp="$(mktemp)"
  PD_KEY="$key" PD_VAL="$value" PD_SEP="$sep" awk '
    function keyed(line, comment,   s, c) {
      s = line
      sub(/^[ \t]+/, "", s)
      if (comment) {
        if (substr(s, 1, 1) != "#" && substr(s, 1, 1) != ";") return 0
        s = substr(s, 2)
        sub(/^[ \t]+/, "", s)
      }
      if (index(s, ENVIRON["PD_KEY"]) != 1) return 0
      c = substr(s, length(ENVIRON["PD_KEY"]) + 1, 1)
      return (c == "" || c == " " || c == "\t" || c == "=")
    }
    { lines[NR] = $0 }
    END {
      active = 0; first_comment = 0
      for (i = 1; i <= NR; i++) {
        if (keyed(lines[i], 0)) active = 1
        else if (!first_comment && keyed(lines[i], 1)) first_comment = i
      }
      newline = ENVIRON["PD_KEY"] ENVIRON["PD_SEP"] ENVIRON["PD_VAL"]
      for (i = 1; i <= NR; i++) {
        if (keyed(lines[i], 0)) { print newline; continue }
        print lines[i]
        if (!active && i == first_comment) print newline
      }
      if (!active && !first_comment) print newline
    }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file" # keep inode, owner and mode of the original
  rm -f "$tmp"
}

# ── Validators (return 0 when valid) ──────────────────────────────────────────
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
valid_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
valid_timezone() {
  [[ "$1" =~ ^[A-Za-z0-9_+/-]+$ && "$1" != *..* && -f "/usr/share/zoneinfo/$1" ]]
}
valid_swap_size() { [[ "$1" =~ ^[1-9][0-9]{0,3}[MmGg]$ ]]; }
valid_db_name() { [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]]; }
valid_db_user() { [[ "$1" =~ ^[A-Za-z0-9_]{1,32}$ ]]; }

# ── Package management ────────────────────────────────────────────────────────
# apt front-end: non-interactive, waits for the dpkg lock (cloud-init and
# unattended-upgrades often hold it on fresh servers), keeps existing configs.
apt_get() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -q \
    -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@"
}

# yum/dnf front-end (Amazon Linux 2 only has yum)
pm_rpm() {
  if command -v dnf &>/dev/null; then dnf "$@"; else yum "$@"; fi
}

pkg_installed() {
  case "${PKG_MANAGER:-}" in
    apt) [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]] ;;
    dnf) rpm -q --quiet "$1" ;;
    *) return 1 ;;
  esac
}

pkg_available() {
  case "${PKG_MANAGER:-}" in
    apt)
      local cand
      cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2 }')"
      [[ -n "$cand" && "$cand" != "(none)" ]]
      ;;
    dnf) pm_rpm -q info "$1" &>/dev/null ;;
    *) return 1 ;;
  esac
}

# Install every package or fail (used for required packages).
pkg_install_required() {
  local p
  for p in "$@"; do
    pkg_installed "$p" && continue
    pkg_available "$p" || error "Package '$p' is not available in the configured repositories ($OS_ID $OS_VERSION)."
  done
  os_pkg_install "$@"
}

# Install the first available package from the list; sets PKG_INSTALLED.
pkg_install_first() {
  PKG_INSTALLED=""
  local p
  for p in "$@"; do
    if pkg_installed "$p" || { pkg_available "$p" && os_pkg_install "$p"; }; then
      PKG_INSTALLED="$p"
      return 0
    fi
  done
  return 1
}

# Install packages one by one; a missing/failed optional package is a warning.
pkg_install_optional() {
  local p
  for p in "$@"; do
    if pkg_installed "$p"; then continue; fi
    if pkg_available "$p"; then
      os_pkg_install "$p" || warn "Optional package '$p' failed to install - continuing."
    else
      warn "Optional package '$p' is not available - skipping."
    fi
  done
  return 0
}

# ── Service management ────────────────────────────────────────────────────────
has_systemd() { [[ -d /run/systemd/system ]]; }
svc_exists()  { systemctl cat "$1.service" &>/dev/null; }
svc_active()  { systemctl is-active --quiet "$1"; }

# Print the first existing unit from the list (without the .service suffix).
svc_first_existing() {
  local s
  for s in "$@"; do
    if svc_exists "$s"; then printf '%s' "$s"; return 0; fi
  done
  return 1
}

os_svc_enable() { systemctl enable --now "$1"; }

# Enable and (re)start a service so new config is really applied; on failure
# show why, then fail.
svc_restart() {
  systemctl enable "$1" &>/dev/null || true
  if ! systemctl restart "$1"; then
    warn "Service '$1' failed to (re)start. Recent status:"
    systemctl status --no-pager -l "$1" 2>&1 | tail -n 15 >&2 || true
    journalctl -u "$1" -n 20 --no-pager 2>/dev/null >&2 || true
    return 1
  fi
}

svc_reload() { systemctl reload "$1" 2>/dev/null || svc_restart "$1"; }

# ── Networking helpers ────────────────────────────────────────────────────────
# Every TCP port sshd is (or may be) reachable on - used so the firewall can
# never lock out the session that is running this script.
ssh_ports() {
  local -a ports=()
  local p
  if command -v sshd &>/dev/null; then
    while read -r p; do [[ -n "$p" ]] && ports+=("$p"); done \
      < <(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true)
  fi
  [[ -n "${SSH_CONNECTION:-}" ]] && ports+=("${SSH_CONNECTION##* }")
  ports+=("${SSH_PORT:-22}")
  printf '%s\n' "${ports[@]}" | grep -E '^[0-9]+$' | sort -un
}

# Make sure ports 80/443 are reachable if a firewall is already running.
open_web_ports() {
  if command -v ufw &>/dev/null && [[ "$(ufw status 2>/dev/null | head -n 1)" == "Status: active" ]]; then
    ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null && log "ufw: opened ports 80/443"
  elif command -v firewall-cmd &>/dev/null && svc_active firewalld; then
    firewall-cmd --permanent --add-service=http --add-service=https >/dev/null &&
      firewall-cmd --reload >/dev/null && log "firewalld: opened HTTP/HTTPS"
  fi
  return 0
}
