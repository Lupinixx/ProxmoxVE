#!/usr/bin/env bash
SCRIPT_BASE_URL="${SCRIPT_BASE_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main}"
source <(curl -fsSL "${SCRIPT_BASE_URL}/misc/build.func" | sed "s|https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main|${SCRIPT_BASE_URL}|g")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: lupinixx
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/sortbek/simcraft

APP="SimHammer"
var_tags="${var_tags:-gaming;wow}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-15}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function preflight_install_script() {
  local install_url="${SCRIPT_BASE_URL}/install/${var_install}.sh"
  if ! curl -fsSL "$install_url" >/dev/null; then
    msg_error "Install script not found: $install_url"
    msg_error "Aborting before container build to avoid false success on missing installer."
    exit
  fi
}

function enable_build_swap() {
  BUILD_SWAP_FILE="${BUILD_SWAP_FILE:-/opt/simhammer/build.swap}"
  BUILD_SWAP_MB="${BUILD_SWAP_MB:-4096}"
  BUILD_SWAP_TRIGGER_MB="${BUILD_SWAP_TRIGGER_MB:-8192}"
  BUILD_SWAP_ENABLED=0

  local mem_total
  mem_total=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  if [[ "$mem_total" -ge "$BUILD_SWAP_TRIGGER_MB" ]]; then
    return
  fi

  msg_info "Low RAM detected (${mem_total}MB). Creating temporary ${BUILD_SWAP_MB}MB swap for build."
  mkdir -p "$(dirname "$BUILD_SWAP_FILE")"
  if command -v fallocate >/dev/null 2>&1; then
    $STD fallocate -l "${BUILD_SWAP_MB}M" "$BUILD_SWAP_FILE" || $STD dd if=/dev/zero of="$BUILD_SWAP_FILE" bs=1M count="$BUILD_SWAP_MB"
  else
    $STD dd if=/dev/zero of="$BUILD_SWAP_FILE" bs=1M count="$BUILD_SWAP_MB"
  fi
  chmod 600 "$BUILD_SWAP_FILE"
  $STD mkswap "$BUILD_SWAP_FILE"
  $STD swapon "$BUILD_SWAP_FILE"
  BUILD_SWAP_ENABLED=1
  msg_ok "Temporary build swap enabled"
}

function disable_build_swap() {
  if [[ "${BUILD_SWAP_ENABLED:-0}" == "1" ]]; then
    msg_info "Removing temporary build swap"
    swapoff "$BUILD_SWAP_FILE" || true
    rm -f "$BUILD_SWAP_FILE" || true
    msg_ok "Removed temporary build swap"
  fi
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/simhammer/source ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Checking for Updates"
  git -C /opt/simhammer/source remote set-url origin https://github.com/sortbek/simcraft
  git -C /opt/simhammer/source fetch origin --quiet
  BRANCH=$(git -C /opt/simhammer/source symbolic-ref --short HEAD 2>/dev/null || echo "main")
  CURRENT=$(git -C /opt/simhammer/source rev-parse HEAD)
  REMOTE=$(git -C /opt/simhammer/source rev-parse "origin/${BRANCH}" 2>/dev/null || echo "")
  if [[ -n "$REMOTE" && "$CURRENT" == "$REMOTE" ]]; then
    msg_ok "No update required. ${APP} is already up to date."
    exit
  fi
  msg_ok "Update available"

  enable_build_swap
  trap 'disable_build_swap' EXIT

  msg_info "Stopping Services"
  systemctl stop simhammer-backend simhammer-frontend
  msg_ok "Stopped Services"

  msg_info "Pulling Latest Source"
  git -C /opt/simhammer/source pull --quiet
  msg_ok "Pulled Latest Source"

  msg_info "Rebuilding Backend"
  source /root/.cargo/env 2>/dev/null || true
  cd /opt/simhammer/source/backend
  $STD cargo build --release -p simhammer-server --features web
  cp /opt/simhammer/source/backend/target/release/simhammer-server /usr/local/bin/simhammer-server
  rm -rf /opt/simhammer/source/backend/target
  msg_ok "Rebuilt Backend"

  msg_info "Rebuilding Frontend"
  LOCAL_IP=$(hostname -I | awk '{print $1}')
  cd /opt/simhammer/source/frontend
  $STD npm ci
  NEXT_PUBLIC_API_URL="http://${LOCAL_IP}:8000" $STD npm run build
  rm -rf /opt/simhammer/frontend
  mkdir -p /opt/simhammer/frontend
  cp -r /opt/simhammer/source/frontend/.next/standalone/. /opt/simhammer/frontend/
  cp -r /opt/simhammer/source/frontend/.next/static /opt/simhammer/frontend/.next/static
  cp -r /opt/simhammer/source/frontend/public /opt/simhammer/frontend/public
  rm -rf /opt/simhammer/source/frontend/.next /opt/simhammer/source/frontend/node_modules
  msg_ok "Rebuilt Frontend"

  msg_info "Starting Services"
  systemctl start simhammer-backend simhammer-frontend
  msg_ok "Started Services"
  disable_build_swap
  trap - EXIT
  msg_ok "Updated successfully!"
  exit
}

start
preflight_install_script
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3000${CL}"
