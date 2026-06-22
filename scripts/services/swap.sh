#!/usr/bin/env bash
# Service: Swap file setup

setup_swap() {
  section "Configuring Swap"

  # Skip if swap already exists
  if swapon --show | grep -q "partition\|file"; then
    warn "Swap already active. Skipping."
    swapon --show
    return 0
  fi

  # Detect RAM and suggest swap size
  local RAM_MB
  RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  local SUGGESTED_SWAP
  if   (( RAM_MB <= 512  )); then SUGGESTED_SWAP="1G"
  elif (( RAM_MB <= 2048 )); then SUGGESTED_SWAP="2G"
  elif (( RAM_MB <= 8192 )); then SUGGESTED_SWAP="4G"
  else                             SUGGESTED_SWAP="8G"
  fi

  info "Detected RAM: ${RAM_MB}MB — Recommended swap: ${SUGGESTED_SWAP}"
  read -rp "$(echo -e "${CYAN}Enter swap size (e.g. 2G, 4G) [default: ${SUGGESTED_SWAP}]:${RESET} ")" SWAP_SIZE
  SWAP_SIZE="${SWAP_SIZE:-$SUGGESTED_SWAP}"

  info "Creating ${SWAP_SIZE} swap file at /swapfile..."
  fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || \
    dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE//[^0-9]/}000" status=progress

  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  # Persist across reboots
  echo '/swapfile none swap sw 0 0' >> /etc/fstab

  # Tune swappiness for server workloads
  cat > /etc/sysctl.d/99-swap.conf <<SYSCTL
vm.swappiness=10
vm.vfs_cache_pressure=50
SYSCTL
  sysctl --system &>/dev/null

  log "Swap configured: ${SWAP_SIZE} at /swapfile (swappiness=10)"
  swapon --show
  free -h
}