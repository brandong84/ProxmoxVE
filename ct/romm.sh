#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/brandong84/ProxmoxVE/feat/romm-ct/misc/build.func)
#source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Brandon Groves
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/rommapp/romm

APP="RomM"
var_tags="${var_tags:-gaming;roms}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-4}"
var_os="${var_os:-alpine}"
var_version="${var_version:-3.22}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/romm ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  if [[ ! -f /opt/romm/.version ]]; then
    msg_error "Missing /opt/romm/.version; update skipped."
    exit 1
  fi

  msg_info "Checking for RomM updates"
  if ! command -v jq >/dev/null 2>&1; then
    $STD apk add --no-cache jq
  fi
  local current_version
  current_version=$(cat /opt/romm/.version)
  local latest_tag
  latest_tag=$(curl -fsSL https://api.github.com/repos/rommapp/romm/releases/latest | jq -r '.tag_name')
  local latest_version="${latest_tag#v}"

  if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    msg_error "Unable to determine latest version."
    exit 1
  fi

  if [[ "$current_version" == "$latest_version" ]]; then
    msg_ok "RomM is already up to date (v${current_version})"
    exit 0
  fi

  msg_info "Stopping RomM"
  rc-service romm stop
  msg_ok "Stopped RomM"

  msg_info "Backing up configuration"
  mkdir -p /tmp/romm_backup
  cp /opt/romm/.env /tmp/romm_backup/ 2>/dev/null || true
  msg_ok "Backed up configuration"

  msg_info "Installing build dependencies"
  $STD apk add --no-cache --virtual .romm-build \
    build-base \
    linux-headers \
    libffi-dev \
    openssl-dev \
    zlib-dev \
    bzip2-dev \
    xz-dev \
    readline-dev \
    sqlite-dev \
    ncurses-dev \
    libpq-dev \
    mariadb-connector-c-dev
  msg_ok "Installed build dependencies"

  msg_info "Updating RomM"
  rm -rf /opt/romm
  mkdir -p /opt/romm
  curl -fsSL "https://github.com/rommapp/romm/archive/refs/tags/${latest_tag}.tar.gz" | tar -xz -C /opt/romm --strip-components=1
  echo "$latest_version" >/opt/romm/.version
  msg_ok "Updated RomM"

  msg_info "Restoring configuration"
  if [[ -f /etc/romm/romm.env ]]; then
    ln -sfn /etc/romm/romm.env /opt/romm/.env
  elif [[ -f /tmp/romm_backup/.env ]]; then
    cp /tmp/romm_backup/.env /opt/romm/.env
  fi
  rm -rf /tmp/romm_backup
  msg_ok "Restored configuration"

  msg_info "Updating backend dependencies"
  cd /opt/romm || exit 1
  /usr/local/bin/uv python install 3.13
  /usr/local/bin/uv venv --python 3.13
  /usr/local/bin/uv sync --locked --no-cache
  msg_ok "Updated backend dependencies"

  msg_info "Rebuilding frontend"
  cd /opt/romm/frontend || exit 1
  $STD npm ci --ignore-scripts --no-audit --no-fund
  $STD npm run build
  rm -rf /var/www/html/*
  mkdir -p /var/www/html/assets
  cp -a /opt/romm/frontend/dist/. /var/www/html/
  cp -a /opt/romm/frontend/assets/. /var/www/html/assets/
  mkdir -p /var/www/html/assets/romm
  ln -sfn /romm/resources /var/www/html/assets/romm/resources
  ln -sfn /romm/assets /var/www/html/assets/romm/assets
  msg_ok "Rebuilt frontend"

  msg_info "Cleaning up build dependencies"
  $STD apk del .romm-build
  msg_ok "Cleaned up build dependencies"

  msg_info "Starting RomM"
  rc-service romm start
  msg_ok "Started RomM"
  msg_ok "Updated successfully!"
  exit 0
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
