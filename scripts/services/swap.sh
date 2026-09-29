#!/usr/bin/env bash
# Service: Swap file setup
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# swap_size_mb <size like 512M / 2G>
_swap_size_mb() {
  local n="${1%[MmGg]}" u="${1: -1}"
  case "$u" in
    G|g) echo $((n * 1024)) ;;
    *)   echo "$n" ;;
  esac
}

setup_swap() {
  section "Configuring Swap"

  # Skip if any swap is already active
  if [[ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]]; then
    warn "Swap already active. Skipping."
    swapon --show
    return 0
  fi

  local ram_mb suggested
  ram_mb="$(total_ram_mb)"
  suggested="$(swap_suggest_size "$ram_mb")"

  local size="${SWAP_SIZE:-$suggested}"
  valid_swap_size "$size" || error "Invalid swap size '$size' (examples: 512M, 2G)."
  local size_mb
  size_mb="$(_swap_size_mb "$size")"
  info "Detected RAM: ${ram_mb}MB — creating ${size} swap file at /swapfile"

  # Never fill the disk: keep at least 1 GB free after creating the file.
  local free_mb
  free_mb="$(df -Pm / | awk 'NR == 2 { print $4 }')"
  if ((free_mb < size_mb + 1024)); then
    warn "Not enough free disk (${free_mb}MB free) for a ${size} swap file plus 1GB headroom — skipping swap."
    return 0
  fi

  if [[ -e /swapfile ]]; then
    # Reuse it if it is already a swap area, otherwise refuse to touch it.
    if [[ "$(blkid -p -o value -s TYPE /swapfile 2>/dev/null || true)" == "swap" ]]; then
      info "/swapfile is already a swap area — enabling it"
    else
      error "/swapfile exists but is not a swap area; move it away and re-run."
    fi
  else
    if ! fallocate -l "${size_mb}M" /swapfile 2>/dev/null; then
      dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  chmod 600 /swapfile

  # Containers (LXC/OpenVZ) and some filesystems refuse swapon: don't fail the run.
  if ! swapon /swapfile 2>/dev/null; then
    warn "swapon /swapfile failed (container or unsupported filesystem?) — removing the file."
    rm -f /swapfile
    return 0
  fi

  grep -qs '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab

  # Tune swappiness for server workloads
  cat >/etc/sysctl.d/99-swap.conf <<SYSCTL
# Managed by PulseDeploy (revert.sh uses this file to know the swap is ours)
vm.swappiness=10
vm.vfs_cache_pressure=50
SYSCTL
  sysctl -p /etc/sysctl.d/99-swap.conf &>/dev/null || warn "Could not apply sysctl settings now (they apply on reboot)."

  log "Swap configured: ${size} at /swapfile (swappiness=10)"
  swapon --show
  return 0
}
