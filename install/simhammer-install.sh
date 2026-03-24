#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: lupinixx
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/sortbek/simcraft

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

SIMHAMMER_REPO="${SIMHAMMER_REPO:-sortbek/simcraft}"
SIMC_VERSION="${SIMC_VERSION:-HEAD}"

enable_build_swap() {
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

disable_build_swap() {
  if [[ "${BUILD_SWAP_ENABLED:-0}" == "1" ]]; then
    msg_info "Removing temporary build swap"
    swapoff "$BUILD_SWAP_FILE" || true
    rm -f "$BUILD_SWAP_FILE" || true
    msg_ok "Removed temporary build swap"
  fi
}

msg_info "Installing Dependencies"
$STD apt-get install -y \
  git \
  build-essential \
  libssl-dev \
  libcurl4-openssl-dev \
  pkg-config \
  jq
msg_ok "Installed Dependencies"

setup_rust
NODE_VERSION="20" setup_nodejs
source /root/.cargo/env

enable_build_swap
trap 'disable_build_swap' EXIT

get_lxc_ip

msg_info "Cloning SimHammer"
$STD git clone --depth 1 "https://github.com/${SIMHAMMER_REPO}" /opt/simhammer/source
msg_ok "Cloned SimHammer"

msg_info "Building SimulationCraft (this takes several minutes)"
$STD git clone --depth 1 https://github.com/simulationcraft/simc.git /tmp/simc
if [[ "${SIMC_VERSION}" != "HEAD" ]]; then
  git -C /tmp/simc fetch --depth 1 origin "${SIMC_VERSION}"
  git -C /tmp/simc checkout FETCH_HEAD
fi
cd /tmp/simc/engine
$STD make NO_DEBUG=1 SC_NO_NETWORKING=1 -j"$(nproc)"
cp /tmp/simc/engine/simc /usr/local/bin/simc
chmod +x /usr/local/bin/simc
rm -rf /tmp/simc
msg_ok "Built SimulationCraft"

msg_info "Building SimHammer Backend (this takes several minutes)"
cd /opt/simhammer/source/backend
$STD cargo build --release -p simhammer-server
cp /opt/simhammer/source/backend/target/release/simhammer-server /usr/local/bin/simhammer-server
chmod +x /usr/local/bin/simhammer-server
rm -rf /opt/simhammer/source/backend/target
msg_ok "Built SimHammer Backend"

msg_info "Fetching Game Data from Raidbots"
mkdir -p /tmp/simhammer-data-full
cd /tmp/simhammer-data-full
curl -fsSL -o metadata.json https://www.raidbots.com/static/data/live/metadata.json
for f in $(jq -r '.files[]' metadata.json); do
  $STD curl -fsSL -o "${f}" "https://www.raidbots.com/static/data/live/${f}"
done
cp /opt/simhammer/source/backend/core/season-config.json /tmp/simhammer-data-full/season-config.json
mkdir -p /opt/simhammer/resources/data
$STD node /opt/simhammer/source/backend/scripts/compact-data.js \
  /tmp/simhammer-data-full \
  /opt/simhammer/resources/data
rm -rf /tmp/simhammer-data-full
msg_ok "Fetched Game Data"

msg_info "Building SimHammer Frontend"
cd /opt/simhammer/source/frontend
$STD npm ci
NEXT_PUBLIC_API_URL="http://${LOCAL_IP}:8000" $STD npm run build

mkdir -p /opt/simhammer/frontend
cp -r /opt/simhammer/source/frontend/.next/standalone/. /opt/simhammer/frontend/
cp -r /opt/simhammer/source/frontend/.next/static /opt/simhammer/frontend/.next/static
cp -r /opt/simhammer/source/frontend/public /opt/simhammer/frontend/public

rm -rf /opt/simhammer/source/frontend/.next /opt/simhammer/source/frontend/node_modules
msg_ok "Built SimHammer Frontend"

mkdir -p /opt/simhammer/db

msg_info "Configuring SimHammer"
cat <<EOF >/opt/simhammer/backend.env
DATA_DIR=/opt/simhammer/resources/data
DATABASE_URL=/opt/simhammer/db/simhammer.db
PORT=8000
SIMC_PATH=/usr/local/bin/simc
EOF
msg_ok "Configured SimHammer"

msg_info "Creating Services"
NODE_BIN=$(command -v node)

cat <<EOF >/etc/systemd/system/simhammer-backend.service
[Unit]
Description=SimHammer Backend
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=/opt/simhammer/backend.env
ExecStart=/usr/local/bin/simhammer-server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/simhammer-frontend.service
[Unit]
Description=SimHammer Frontend
After=network.target simhammer-backend.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/simhammer/frontend
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOSTNAME=0.0.0.0
ExecStart=${NODE_BIN} server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now simhammer-backend
systemctl enable -q --now simhammer-frontend
msg_ok "Created Services"

disable_build_swap
trap - EXIT

motd_ssh
customize
cleanup_lxc
