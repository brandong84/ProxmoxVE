#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Brandon Groves
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADER_FILE="$SCRIPT_DIR/../headers/template-exporter"
LOG_FILE="/var/log/pve-template-exporter.log"
TEMP_CLONES=()
NOTICE_SHOWN=0
DEBUG="${DEBUG:-0}"
export TERM="${TERM:-xterm}"

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="[OK]"
CROSS="[ERR]"

mkdir -p /var/log
: >"$LOG_FILE" || true

log_line() {
  local level="$1"
  local msg="$2"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >>"$LOG_FILE"
}

header_info() {
  clear
  if [[ -f "$HEADER_FILE" ]]; then
    cat "$HEADER_FILE"
  else
    cat <<'EOF' 
  ______                     __      __          ______                      __           
 /_  __/__  ____ ___  ____  / /___ _/ /____     / ____/  ______  ____  _____/ /____  _____
  / / / _ \/ __ `__ \/ __ \/ / __ `/ __/ _ \   / __/ | |/_/ __ \/ __ \/ ___/ __/ _ \/ ___/
 / / /  __/ / / / / / /_/ / / /_/ / /_/  __/  / /____>  </ /_/ / /_/ / /  / /_/  __/ /    
/_/  \___/_/ /_/ /_/ .___/_/\__,_/\__/\___/  /_____/_/|_/ .___/\____/_/   \__/\___/_/     
                  /_/                                  /_/                                
EOF
  fi
}

msg_info() { echo -ne " ${HOLD} ${YW}${1}...${CL}" >&2; log_line "INFO" "$1"; }
msg_ok() { echo -e "${BFR} ${CM} ${GN}${1}${CL}" >&2; log_line "OK" "$1"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}${1}${CL}" >&2; log_line "ERROR" "$1"; }

ensure_choice() {
  local label="$1" value="$2"
  if [[ -z "$value" ]]; then
    msg_error "$label selection canceled."
    exit 1
  fi
}

register_temp_clone() {
  local type="$1" id="$2"
  TEMP_CLONES+=("${type}:${id}")
}

unregister_temp_clone() {
  local type="$1" id="$2" item new_list=()
  for item in "${TEMP_CLONES[@]}"; do
    if [[ "$item" != "${type}:${id}" ]]; then
      new_list+=("$item")
    fi
  done
  TEMP_CLONES=("${new_list[@]}")
}

cleanup_temp_clones() {
  local item type id
  for item in "${TEMP_CLONES[@]}"; do
    type="${item%%:*}"
    id="${item##*:}"
    if [[ "$type" == "lxc" ]]; then
      pct destroy "$id" >/dev/null 2>&1 || true
    elif [[ "$type" == "vm" ]]; then
      qm destroy "$id" >/dev/null 2>&1 || true
    fi
  done
}

show_clone_notice() {
  if [[ "$NOTICE_SHOWN" -eq 0 ]]; then
    whiptail --msgbox "Exports create a temporary clone and remove it after export. The source guest is not modified." 10 72
    NOTICE_SHOWN=1
  fi
}

toggle_debug() {
  if [[ "$DEBUG" -eq 0 ]]; then
    DEBUG=1
    whiptail --msgbox "Debug output enabled. Commands will print to the screen." 9 60
  else
    DEBUG=0
    whiptail --msgbox "Debug output disabled. Commands will log to ${LOG_FILE} only." 9 68
  fi
}

show_spinner() {
  local pid="$1" label="$2"
  local spin='|/-\\'
  local i=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    printf "\r %s %s" "${spin:i++%4:1}" "$label"
    sleep 0.2
  done
  printf "\r"
}

show_gauge() {
  local pid="$1" label="$2"
  local percent=0
  local frames='|/-\\'
  local i=0
  {
    while kill -0 "$pid" >/dev/null 2>&1; do
      percent=$(( (percent + 3) % 100 ))
      echo "XXX"
      echo "$percent"
      echo "${label} ${frames:i++%4:1}"
      echo "XXX"
      sleep 0.3
    done
    echo "XXX"
    echo "100"
    echo "${label} done"
    echo "XXX"
  } | whiptail --gauge "$label" 8 70 0
}

run_with_progress_allow_fail() {
  local label="$1"
  shift
  local cmd=("$@")

  msg_info "$label"
  if [[ "$DEBUG" -eq 1 ]]; then
    echo "Running: ${cmd[*]}" >&2
    "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
  else
    "${cmd[@]}" >>"$LOG_FILE" 2>&1 &
    local pid=$!
    show_gauge "$pid" "$label"
    wait "$pid"
  fi

  local status=$?
  if [[ "$status" -ne 0 ]]; then
    msg_error "${label} failed"
    return "$status"
  fi
  msg_ok "$label"
  return 0
}

run_with_progress() {
  local label="$1"
  shift
  if ! run_with_progress_allow_fail "$label" "$@"; then
    exit 1
  fi
}

stop_container() {
  local ctid="$1"
  if ! run_with_progress_allow_fail "Stopping container $ctid" pct shutdown "$ctid" --timeout 120; then
    run_with_progress "Force stopping container $ctid" pct stop "$ctid"
  fi
}

stop_vm() {
  local vmid="$1"
  if ! run_with_progress_allow_fail "Stopping VM $vmid" qm shutdown "$vmid" --timeout 120; then
    run_with_progress "Force stopping VM $vmid" qm stop "$vmid"
  fi
}

require_pve() {
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "Run this on a Proxmox VE host."
    exit 1
  fi
}

require_tools() {
  local missing=()
  for tool in whiptail awk sed grep curl pvesm pct qm vzdump pvesh sha256sum du bc; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    msg_error "Missing tools: ${missing[*]}"
    exit 1
  fi
}

storage_path_from_cfg() {
  local storage="$1"
  awk -v s="$storage" '
    $1 ~ /:$/ {type=substr($1,1,length($1)-1); name=$2; inblock=(name==s)}
    inblock && $1=="path" {print $2; exit}
  ' /etc/pve/storage.cfg
}

list_storages_for_content() {
  local content="$1"
  pvesm status -content "$content" | awk 'NR>1{print $1}'
}

select_storage() {
  local content="$1" title="$2"
  local storages menu=()
  mapfile -t storages < <(list_storages_for_content "$content")
  if [[ ${#storages[@]} -eq 0 ]]; then
    msg_error "No storage found with content type: $content"
    exit 1
  fi
  for s in "${storages[@]}"; do
    menu+=("$s" "storage")
  done
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "$title" \
    --menu "Select storage:" 15 60 6 "${menu[@]}" 3>&1 1>&2 2>&3
}

get_vztmpl_dir() {
  local storage="$1"
  local base
  base=$(storage_path_from_cfg "$storage")
  if [[ -n "$base" ]]; then
    echo "$base/template/cache"
    return 0
  fi
  if [[ "$storage" == "local" ]]; then
    echo "/var/lib/vz/template/cache"
    return 0
  fi
  msg_error "Unable to resolve template path for storage: $storage"
  exit 1
}

get_backup_dir() {
  local storage="$1"
  local base
  base=$(storage_path_from_cfg "$storage")
  if [[ -n "$base" ]]; then
    echo "$base/dump"
    return 0
  fi
  if [[ "$storage" == "local" ]]; then
    echo "/var/lib/vz/dump"
    return 0
  fi
  msg_error "Unable to resolve backup path for storage: $storage"
  exit 1
}

parse_size_to_gb() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    echo 0
    return
  fi
  echo "$raw" | awk '
    BEGIN{IGNORECASE=1}
    {
      val=$0
      gsub(/[^0-9.]/,"",val)
      if ($0 ~ /T/) gb=val*1024
      else if ($0 ~ /G/) gb=val
      else if ($0 ~ /M/) gb=val/1024
      else if ($0 ~ /K/) gb=val/1048576
      else gb=val/1024/1024/1024
      printf "%.2f", gb
    }
  '
}

storage_free_gb() {
  local storage="$1"
  local avail
  avail=$(pvesm status -storage "$storage" | awk 'NR>1{print $7}')
  parse_size_to_gb "$avail"
}

preflight_storage() {
  local storage="$1" required_gb="$2" label="$3"
  local free_gb
  free_gb=$(storage_free_gb "$storage")
  if [[ -z "$free_gb" || "$free_gb" == "0" ]]; then
    return 0
  fi
  if (( $(echo "$free_gb < $required_gb" | bc -l) )); then
    whiptail --yesno "${label} storage (${storage}) has ${free_gb}GB free, estimate is ${required_gb}GB. Continue?" 12 70 || exit 1
  fi
}

pick_lxc() {
  local menu=()
  while read -r id name status; do
    menu+=("$id" "$name ($status)")
  done < <(pct list | awk 'NR>1 {print $1" "$3" "$2}')
  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_error "No LXC containers found."
    exit 1
  fi
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select LXC" \
    --menu "Choose a container:" 18 70 10 "${menu[@]}" 3>&1 1>&2 2>&3
}

pick_lxc_multi() {
  local menu=() choice
  while read -r id name status; do
    menu+=("$id" "$name ($status)" OFF)
  done < <(pct list | awk 'NR>1 {print $1" "$3" "$2}')
  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_error "No LXC containers found."
    exit 1
  fi
  choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select LXC" \
    --checklist "Choose containers:" 20 80 12 "${menu[@]}" 3>&1 1>&2 2>&3)
  echo "$choice"
}

pick_vm() {
  local menu=()
  while read -r id name status; do
    menu+=("$id" "$name ($status)")
  done < <(qm list | awk 'NR>1 {print $1" "$2" "$3}')
  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_error "No VMs found."
    exit 1
  fi
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select VM" \
    --menu "Choose a VM:" 18 70 10 "${menu[@]}" 3>&1 1>&2 2>&3
}

pick_vm_multi() {
  local menu=() choice
  while read -r id name status; do
    menu+=("$id" "$name ($status)" OFF)
  done < <(qm list | awk 'NR>1 {print $1" "$2" "$3}')
  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_error "No VMs found."
    exit 1
  fi
  choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select VMs" \
    --checklist "Choose VMs:" 20 80 12 "${menu[@]}" 3>&1 1>&2 2>&3)
  echo "$choice"
}

get_lxc_os_version() {
  local ctid="$1"
  if pct status "$ctid" | grep -q "status: running"; then
    pct exec "$ctid" -- sh -c 'grep -E "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d "\""' 2>/dev/null || true
  fi
}

sanitize_lxc() {
  local ctid="$1"
  local selection

  if ! pct status "$ctid" | grep -q "status: running"; then
    msg_error "Container must be running to sanitize. Start it first."
    exit 1
  fi

  selection=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Sanitize LXC" \
    --checklist "Select cleanup actions (login header preserved):" 22 80 12 \
    "ssh_keys" "Remove SSH host keys" ON \
    "machine_id" "Truncate machine-id" ON \
    "udev_rules" "Remove persistent udev rules" ON \
    "logs" "Clear system logs" ON \
    "temp" "Clear /tmp and /var/tmp" ON \
    "history" "Clear root bash history" ON \
    "hostname" "Reset hostname files" OFF \
    "zero_free" "Zero free space (optional, slow)" OFF \
    3>&1 1>&2 2>&3)

  if [[ -z "$selection" ]]; then
    msg_ok "Sanitize skipped"
    SANITIZE_ACTIONS="none"
    return 0
  fi

  local script=""
  SANITIZE_ACTIONS=""
  for item in $selection; do
    item=$(echo "$item" | tr -d '"')
    case "$item" in
      ssh_keys)
        script+="rm -f /etc/ssh/ssh_host_* 2>/dev/null || true;"
        SANITIZE_ACTIONS+="ssh_keys,"
        ;;
      machine_id)
        script+=": > /etc/machine-id 2>/dev/null || true;"
        SANITIZE_ACTIONS+="machine_id,"
        ;;
      udev_rules)
        script+="rm -f /etc/udev/rules.d/70* 2>/dev/null || true;"
        SANITIZE_ACTIONS+="udev_rules,"
        ;;
      logs)
        script+="find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true;"
        SANITIZE_ACTIONS+="logs,"
        ;;
      temp)
        script+="rm -rf /tmp/* /var/tmp/* 2>/dev/null || true;"
        SANITIZE_ACTIONS+="temp,"
        ;;
      history)
        script+="cat /dev/null > /root/.bash_history 2>/dev/null || true;"
        SANITIZE_ACTIONS+="history,"
        ;;
      hostname)
        script+="echo 'localhost' >/etc/hostname 2>/dev/null || true; sed -i 's/^127.0.1.1.*/127.0.1.1 localhost/' /etc/hosts 2>/dev/null || true;"
        SANITIZE_ACTIONS+="hostname,"
        ;;
      zero_free)
        script+="dd if=/dev/zero of=/zero.fill bs=1M 2>/dev/null || true; rm -f /zero.fill;"
        SANITIZE_ACTIONS+="zero_free,"
        ;;
    esac
  done

  SANITIZE_ACTIONS="${SANITIZE_ACTIONS%,}"
  msg_info "Sanitizing container filesystem"
  pct exec "$ctid" -- sh -c "$script"
  msg_ok "Sanitized container"
}

select_lxc_mode() {
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "LXC Export Mode" \
    --menu "Choose export mode:" 12 60 3 \
    "stop" "Stop container (safe)" \
    "snapshot" "Snapshot (requires storage support)" \
    "suspend" "Suspend (if supported)" 3>&1 1>&2 2>&3
}

select_vm_mode() {
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "VM Export Mode" \
    --menu "Choose export mode:" 12 60 3 \
    "snapshot" "Snapshot (preferred)" \
    "suspend" "Suspend VM" \
    "stop" "Stop VM" 3>&1 1>&2 2>&3
}

select_compression() {
  if command -v zstd >/dev/null 2>&1; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "Compression" \
      --menu "Select compression format:" 12 60 3 \
      "gzip" "Gzip (portable)" \
      "zstd" "Zstd (faster)" 3>&1 1>&2 2>&3
  else
    whiptail --msgbox "zstd is not installed. Defaulting to gzip." 9 60
    echo "gzip"
  fi
}

write_manifest_lxc() {
  local output="$1" source_id="$2" export_id="$3" ostype="$4" osver="$5" arch="$6" name="$7" storage="$8" sanitize="$9"
  cat <<EOF >"${output}.manifest.json"
{
  "type": "lxc",
  "source_id": "${source_id}",
  "export_id": "${export_id}",
  "ostype": "${ostype}",
  "os_version": "${osver}",
  "arch": "${arch}",
  "template_name": "${name}",
  "storage": "${storage}",
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "sanitized_actions": "${sanitize}",
  "notes": "Login header preserved in /etc/profile.d/00_lxc-details.sh"
}
EOF
}

write_manifest_vm() {
  local output="$1" source_id="$2" export_id="$3" storage="$4" mode="$5"
  local name mem cores
  name=$(qm config "$source_id" | awk '/^name:/ {print $2}')
  mem=$(qm config "$source_id" | awk '/^memory:/ {print $2}')
  cores=$(qm config "$source_id" | awk '/^cores:/ {print $2}')
  cat <<EOF >"${output}.manifest.json"
{
  "type": "vm",
  "source_id": "${source_id}",
  "export_id": "${export_id}",
  "name": "${name}",
  "memory_mb": "${mem}",
  "cores": "${cores}",
  "storage": "${storage}",
  "export_mode": "${mode}",
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

checksum_file() {
  local file="$1"
  sha256sum "$file" >"${file}.sha256"
}

verify_checksum() {
  local file="$1"
  local sha_file="${file}.sha256"
  if [[ -f "$sha_file" ]]; then
    msg_info "Verifying checksum"
    sha256sum -c "$sha_file" >/dev/null
    msg_ok "Checksum verified"
  fi
}

export_summary_msg() {
  local title="$1" path="$2"
  local size checksum_file manifest_file
  size=$(du -h "$path" | awk '{print $1}')
  checksum_file="${path}.sha256"
  manifest_file="${path}.manifest.json"
  whiptail --msgbox "${title}\n\nPath: ${path}\nSize: ${size}\nChecksum: ${checksum_file}\nManifest: ${manifest_file}" 14 78
}

lxc_rootfs_gb() {
  local ctid="$1"
  local size
  size=$(pct config "$ctid" | awk -F 'size=' '/^rootfs:/ {print $2}' | awk '{print $1}')
  parse_size_to_gb "$size"
}

vm_total_disk_gb() {
  local vmid="$1"
  local total=0
  while read -r line; do
    local size
    size=$(echo "$line" | awk -F 'size=' '{print $2}' | awk '{print $1}')
    if [[ -n "$size" ]]; then
      total=$(echo "$total + $(parse_size_to_gb "$size")" | bc -l)
    fi
  done < <(qm config "$vmid" | grep -E '^(scsi|sata|virtio)[0-9]+:')
  printf '%.2f' "$total"
}

create_temp_lxc_clone() {
  local source_id="$1" storage="$2"
  local temp_id temp_name status
  temp_id=$(pvesh get /cluster/nextid)
  temp_name="export-${source_id}-${temp_id}"
  status=$(pct status "$source_id" | awk '{print $2}')

  exec 3>&1
  exec 1>&2
  if [[ "$status" == "running" ]]; then
    msg_info "Stopping container $source_id for consistent clone"
    stop_container "$source_id"
    run_with_progress "Cloning container $source_id" pct clone "$source_id" "$temp_id" --hostname "$temp_name" --full --storage "$storage"
    run_with_progress "Starting container $source_id" pct start "$source_id"
  else
    run_with_progress "Cloning container $source_id" pct clone "$source_id" "$temp_id" --hostname "$temp_name" --full --storage "$storage"
  fi
  exec 1>&3
  exec 3>&-

  echo "$temp_id"
}

create_temp_vm_clone() {
  local source_id="$1" storage="$2"
  local temp_id temp_name status stopped=0
  temp_id=$(pvesh get /cluster/nextid)
  temp_name="export-${source_id}-${temp_id}"
  status=$(qm status "$source_id" | awk '{print $2}')

  exec 3>&1
  exec 1>&2
  if [[ "$status" == "running" ]]; then
    msg_info "Stopping VM $source_id for consistent clone"
    stop_vm "$source_id"
    stopped=1
  fi

  run_with_progress "Cloning VM $source_id" qm clone "$source_id" "$temp_id" --name "$temp_name" --full --storage "$storage"
  if [[ "$stopped" -eq 1 ]]; then
    run_with_progress "Starting VM $source_id" qm start "$source_id"
  fi
  exec 1>&3
  exec 3>&-

  echo "$temp_id"
}

export_lxc_single() {
  local ctid="$1"
  local storage template_dir backup_file
  local mode export_id temp_id clone_storage compress
  local source_status
  SANITIZE_ACTIONS="none"
  local ext
  local do_cleanup
  local ostype osver name rev arch new_name default_name

  show_clone_notice
  source_status=$(pct status "$ctid" | awk '{print $2}')
  clone_storage=$(select_storage "rootdir" "Clone Storage")
  ensure_choice "Clone storage" "$clone_storage"
  mode=$(select_lxc_mode)
  compress=$(select_compression)
  ensure_choice "Compression" "$compress"
  storage=$(select_storage "vztmpl" "Template Storage")
  ensure_choice "Template storage" "$storage"

  if [[ "$source_status" != "running" && "$mode" != "stop" ]]; then
    whiptail --msgbox "Source CT is stopped. Export mode will be set to stop for consistency." 10 70
    mode="stop"
  fi

  if whiptail --yesno "Run cleanup inside the clone before export?" 10 60; then
    do_cleanup="yes"
  else
    do_cleanup="no"
  fi

  export_id="$ctid"
  msg_info "Creating temporary clone"
  temp_id=$(create_temp_lxc_clone "$ctid" "$clone_storage")
  if [[ -z "$temp_id" ]]; then
    msg_error "Clone failed. Aborting export."
    exit 1
  fi
  register_temp_clone "lxc" "$temp_id"
  export_id="$temp_id"
  msg_ok "Temporary clone created: $export_id"

  if [[ "$do_cleanup" == "yes" ]]; then
    if ! pct status "$export_id" | grep -q "status: running"; then
      pct start "$export_id" >/dev/null 2>&1 || true
    fi
    sanitize_lxc "$export_id"
    if [[ "$source_status" != "running" ]]; then
      pct shutdown "$export_id" --timeout 60 >/dev/null 2>&1 || pct stop "$export_id" >/dev/null 2>&1 || true
    fi
  fi

  msg_info "Removing net0 from container config"
  pct set "$export_id" --delete net0 >/dev/null 2>&1 || true
  msg_ok "Removed net0"

  template_dir=$(get_vztmpl_dir "$storage")
  mkdir -p "$template_dir"

  preflight_storage "$storage" "$(lxc_rootfs_gb "$export_id")" "Template"

  run_with_progress "Exporting LXC archive" vzdump "$export_id" --mode "$mode" --compress "$compress" --dumpdir "$template_dir"

  backup_file=$(ls -t "$template_dir"/vzdump-lxc-"$export_id"-*.tar.* 2>/dev/null | head -n1)
  if [[ -z "$backup_file" ]]; then
    msg_error "Unable to locate exported archive."
    exit 1
  fi

  ostype=$(pct config "$export_id" | awk '/^ostype:/ {print $2}')
  arch=$(pct config "$export_id" | awk '/^arch:/ {print $2}')
  osver=$(get_lxc_os_version "$export_id")
  osver=$(whiptail --inputbox "OS version (e.g., 24.04, 12, 3.22):" 10 60 "${osver}" 3>&1 1>&2 2>&3)
  name=$(whiptail --inputbox "Template name (identifier):" 10 60 "custom" 3>&1 1>&2 2>&3)
  rev=$(whiptail --inputbox "Revision (e.g., 1):" 10 60 "1" 3>&1 1>&2 2>&3)
  arch=${arch:-amd64}
  ostype=${ostype:-custom}

  if [[ "$compress" == "zstd" ]]; then
    ext="tar.zst"
  else
    ext="tar.gz"
  fi

  default_name="${ostype}-${osver}-${name}_${osver}-${rev}_${arch}.${ext}"
  new_name=$(whiptail --inputbox "Confirm filename:" 10 70 "${default_name}" 3>&1 1>&2 2>&3)
  if [[ -n "$new_name" && "$new_name" != "$(basename "$backup_file")" ]]; then
    mv "$backup_file" "$template_dir/$new_name"
    backup_file="$template_dir/$new_name"
  fi

  checksum_file "$backup_file"
  write_manifest_lxc "$backup_file" "$ctid" "$export_id" "$ostype" "$osver" "$arch" "$name" "$storage" "${SANITIZE_ACTIONS:-none}"

  if [[ -n "${temp_id:-}" ]]; then
    msg_info "Removing temporary clone"
    pct destroy "$temp_id" >/dev/null 2>&1 || true
    unregister_temp_clone "lxc" "$temp_id"
    msg_ok "Temporary clone removed"
  fi

  msg_ok "Template ready: $backup_file"
  export_summary_msg "LXC export completed" "$backup_file"
}

export_lxc_batch() {
  local selected
  selected=$(pick_lxc_multi)
  if [[ -z "$selected" ]]; then
    msg_ok "No containers selected"
    exit 0
  fi
  for ctid in $selected; do
    ctid=$(echo "$ctid" | tr -d '"')
    export_lxc_single "$ctid"
  done
}

import_lxc_template() {
  local storage template_dir source method url dest filename
  storage=$(select_storage "vztmpl" "Template Storage")
  template_dir=$(get_vztmpl_dir "$storage")
  mkdir -p "$template_dir"

  method=$(whiptail --title "Import Method" --menu "Select import source:" 12 60 2 \
    "file" "Copy from local path" \
    "url" "Download from URL" 3>&1 1>&2 2>&3)

  case "$method" in
  file)
    source=$(whiptail --inputbox "Full path to template (.tar.*) file or directory:" 10 76 "" 3>&1 1>&2 2>&3)
    if [[ -d "$source" ]]; then
      for f in "$source"/*.tar.*; do
        [[ -f "$f" ]] || continue
        dest="$template_dir/$(basename "$f")"
        cp "$f" "$dest"
        verify_checksum "$dest"
        msg_ok "Imported template: $dest"
      done
      return 0
    fi
    filename=$(basename "$source")
    dest="$template_dir/$filename"
    cp "$source" "$dest"
    verify_checksum "$dest"
    ;;
  url)
    url=$(whiptail --inputbox "Direct URL to template (.tar.*):" 10 76 "" 3>&1 1>&2 2>&3)
    filename=$(basename "$url")
    dest="$template_dir/$filename"
    curl -fsSL "$url" -o "$dest"
    if whiptail --yesno "Attempt to download checksum from ${url}.sha256?" 10 60; then
      curl -fsSL "${url}.sha256" -o "${dest}.sha256" || true
      verify_checksum "$dest"
    fi
    ;;
  esac

  msg_ok "Imported template: $dest"

  if whiptail --yesno "Create a new container from this template now?" 10 60; then
    create_lxc_from_template "$storage" "$dest"
  fi
}

select_bridge() {
  local bridges menu=()
  mapfile -t bridges < <(ls /sys/class/net 2>/dev/null | grep -E '^vmbr|^bond' || true)
  if [[ ${#bridges[@]} -eq 0 ]]; then
    echo "vmbr0"
    return 0
  fi
  for b in "${bridges[@]}"; do
    menu+=("$b" "bridge")
  done
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select Bridge" \
    --menu "Choose network bridge:" 15 60 6 "${menu[@]}" 3>&1 1>&2 2>&3
}

create_lxc_from_template() {
  local storage="$1" template_path="$2"
  local ctid hostname root_storage disk_size password bridge ipmode ipaddr gateway vlan net0

  ctid=$(pvesh get /cluster/nextid)
  ctid=$(whiptail --inputbox "Container ID:" 10 60 "$ctid" 3>&1 1>&2 2>&3)
  hostname=$(whiptail --inputbox "Hostname:" 10 60 "ct-$ctid" 3>&1 1>&2 2>&3)
  root_storage=$(select_storage "rootdir" "RootFS Storage")
  disk_size=$(whiptail --inputbox "Root disk size (GB):" 10 60 "8" 3>&1 1>&2 2>&3)
  password=$(whiptail --passwordbox "Set root password:" 10 60 3>&1 1>&2 2>&3)
  if [[ -z "$password" ]]; then
    msg_error "Password cannot be empty."
    exit 1
  fi

  bridge=$(select_bridge)
  ipmode=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Network Mode" \
    --menu "Select IP mode:" 12 60 2 \
    "dhcp" "Use DHCP" \
    "static" "Set static IP" 3>&1 1>&2 2>&3)

  if [[ "$ipmode" == "static" ]]; then
    ipaddr=$(whiptail --inputbox "IP/CIDR (e.g., 10.0.0.50/24):" 10 70 "" 3>&1 1>&2 2>&3)
    gateway=$(whiptail --inputbox "Gateway (e.g., 10.0.0.1):" 10 70 "" 3>&1 1>&2 2>&3)
    net0="name=eth0,bridge=${bridge},ip=${ipaddr},gw=${gateway}"
  else
    net0="name=eth0,bridge=${bridge},ip=dhcp"
  fi

  vlan=$(whiptail --inputbox "VLAN tag (optional):" 10 60 "" 3>&1 1>&2 2>&3)
  if [[ -n "$vlan" ]]; then
    net0+=",tag=${vlan}"
  fi

  msg_info "Creating container"
  pct create "$ctid" "$storage:vztmpl/$(basename "$template_path")" \
    -hostname "$hostname" \
    -rootfs "$root_storage:$disk_size" \
    -net0 "$net0" \
    -password "$password" >/dev/null
  msg_ok "Container created: $ctid"
}

export_vm_single() {
  local vmid="$1"
  local storage backup_dir mode export_id temp_id clone_storage compress
  local source_status
  local backup_file

  show_clone_notice
  mode=$(select_vm_mode)
  ensure_choice "Export mode" "$mode"
  compress=$(select_compression)
  ensure_choice "Compression" "$compress"
  storage=$(select_storage "backup" "Backup Storage")
  ensure_choice "Backup storage" "$storage"
  clone_storage=$(select_storage "images" "Clone Storage")
  ensure_choice "Clone storage" "$clone_storage"

  source_status=$(qm status "$vmid" | awk '{print $2}')
  if [[ "$source_status" != "running" && "$mode" != "stop" ]]; then
    whiptail --msgbox "Source VM is stopped. Export mode will be set to stop for consistency." 10 70
    mode="stop"
  fi

  export_id="$vmid"
  msg_info "Creating temporary clone"
  temp_id=$(create_temp_vm_clone "$vmid" "$clone_storage")
  if [[ -z "$temp_id" ]]; then
    msg_error "Clone failed. Aborting export."
    exit 1
  fi
  register_temp_clone "vm" "$temp_id"
  export_id="$temp_id"
  msg_ok "Temporary clone created: $export_id"

  backup_dir=$(get_backup_dir "$storage")
  mkdir -p "$backup_dir"

  preflight_storage "$storage" "$(vm_total_disk_gb "$export_id")" "Backup"

  run_with_progress "Exporting VM backup" vzdump "$export_id" --mode "${mode:-snapshot}" --compress "$compress" --dumpdir "$backup_dir"

  backup_file=$(ls -t "$backup_dir"/vzdump-qemu-"$export_id"-*.vma.* 2>/dev/null | head -n1)
  if [[ -n "$backup_file" ]]; then
    checksum_file "$backup_file"
    write_manifest_vm "$backup_file" "$vmid" "$export_id" "$storage" "${mode:-snapshot}"
  fi

  if [[ -n "${temp_id:-}" ]]; then
    msg_info "Removing temporary clone"
    qm destroy "$temp_id" >/dev/null 2>&1 || true
    unregister_temp_clone "vm" "$temp_id"
    msg_ok "Temporary clone removed"
  fi

  if [[ -n "$backup_file" ]]; then
    export_summary_msg "VM export completed" "$backup_file"
  fi
}

export_vm_batch() {
  local selected
  selected=$(pick_vm_multi)
  if [[ -z "$selected" ]]; then
    msg_ok "No VMs selected"
    exit 0
  fi
  for vmid in $selected; do
    vmid=$(echo "$vmid" | tr -d '"')
    export_vm_single "$vmid"
  done
}

import_vm_backup() {
  local storage backup_dir method source url filename dest new_vmid target_storage
  storage=$(select_storage "backup" "Backup Storage")
  backup_dir=$(get_backup_dir "$storage")
  mkdir -p "$backup_dir"

  method=$(whiptail --title "Import Method" --menu "Select import source:" 12 60 2 \
    "file" "Copy from local path" \
    "url" "Download from URL" 3>&1 1>&2 2>&3)

  case "$method" in
  file)
    source=$(whiptail --inputbox "Full path to backup file or directory:" 10 70 "" 3>&1 1>&2 2>&3)
    if [[ -d "$source" ]]; then
      for f in "$source"/*.vma.*; do
        [[ -f "$f" ]] || continue
        dest="$backup_dir/$(basename "$f")"
        cp "$f" "$dest"
        verify_checksum "$dest"
        msg_ok "Imported VM backup: $dest"
      done
      return 0
    fi
    filename=$(basename "$source")
    dest="$backup_dir/$filename"
    cp "$source" "$dest"
    verify_checksum "$dest"
    ;;
  url)
    url=$(whiptail --inputbox "Direct URL to backup file:" 10 70 "" 3>&1 1>&2 2>&3)
    filename=$(basename "$url")
    dest="$backup_dir/$filename"
    curl -fsSL "$url" -o "$dest"
    if whiptail --yesno "Attempt to download checksum from ${url}.sha256?" 10 60; then
      curl -fsSL "${url}.sha256" -o "${dest}.sha256" || true
      verify_checksum "$dest"
    fi
    ;;
  esac

  msg_ok "Imported VM backup: $dest"

  if whiptail --yesno "Restore this backup to a new VM now?" 10 60; then
    new_vmid=$(pvesh get /cluster/nextid)
    new_vmid=$(whiptail --inputbox "New VM ID:" 10 60 "$new_vmid" 3>&1 1>&2 2>&3)
    target_storage=$(select_storage "images" "VM Storage")
    qmrestore "$dest" "$new_vmid" --storage "$target_storage" >/dev/null
    msg_ok "VM restored: $new_vmid"
  fi
}

template_catalog_cleanup() {
  local storage template_dir templates menu=() selection
  storage=$(select_storage "vztmpl" "Template Storage")
  template_dir=$(get_vztmpl_dir "$storage")
  mapfile -t templates < <(ls -1 "$template_dir"/*.tar.* 2>/dev/null || true)
  if [[ ${#templates[@]} -eq 0 ]]; then
    msg_error "No .tar.* templates found in $template_dir"
    exit 1
  fi
  for t in "${templates[@]}"; do
    menu+=("$(basename "$t")" "$(du -h "$t" | awk '{print $1}')" OFF)
  done
  selection=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Template Catalog" \
    --checklist "Select templates to delete:" 20 80 12 "${menu[@]}" 3>&1 1>&2 2>&3)

  if [[ -z "$selection" ]]; then
    msg_ok "No templates selected"
    exit 0
  fi

  for item in $selection; do
    item=$(echo "$item" | tr -d '"')
    rm -f "$template_dir/$item"
    rm -f "$template_dir/$item.sha256" "$template_dir/$item.manifest.json" 2>/dev/null || true
    msg_ok "Deleted $item"
  done
}

create_vm_from_template() {
  local menu=() templ_id new_vmid name storage
  while read -r id name; do
    if qm config "$id" 2>/dev/null | grep -q "^template: 1"; then
      menu+=("$id" "$name")
    fi
  done < <(qm list | awk 'NR>1 {print $1" "$2}')

  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_error "No VM templates found."
    exit 1
  fi

  templ_id=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select VM Template" \
    --menu "Choose a VM template:" 18 70 10 "${menu[@]}" 3>&1 1>&2 2>&3)

  new_vmid=$(pvesh get /cluster/nextid)
  new_vmid=$(whiptail --inputbox "New VM ID:" 10 60 "$new_vmid" 3>&1 1>&2 2>&3)
  name=$(whiptail --inputbox "New VM name:" 10 60 "vm-$new_vmid" 3>&1 1>&2 2>&3)
  storage=$(select_storage "images" "VM Storage")

  msg_info "Cloning template"
  qm clone "$templ_id" "$new_vmid" --name "$name" --full --storage "$storage" >/dev/null
  msg_ok "VM created: $new_vmid"
}

create_lxc_from_gui_template() {
  local storage template_dir templates menu=() choice
  storage=$(select_storage "vztmpl" "Template Storage")
  template_dir=$(get_vztmpl_dir "$storage")
  mapfile -t templates < <(ls -1 "$template_dir"/*.tar.* 2>/dev/null || true)
  if [[ ${#templates[@]} -eq 0 ]]; then
    msg_error "No .tar.* templates found in $template_dir"
    exit 1
  fi
  for t in "${templates[@]}"; do
    menu+=("$(basename "$t")" "template")
  done
  choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select LXC Template" \
    --menu "Choose a template:" 18 70 10 "${menu[@]}" 3>&1 1>&2 2>&3)
  create_lxc_from_template "$storage" "$template_dir/$choice"
}

main_menu() {
  while true; do
    header_info
    local choice
  choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Template Exporter" --menu \
      "Select an action:" 22 78 12 \
      "D" "Toggle debug output (currently: ${DEBUG})" \
      "1" "Export LXC as shareable archive" \
      "2" "Export VM backup for sharing" \
      "3" "Batch export LXC containers" \
      "4" "Batch export VMs" \
      "5" "Import LXC template (.tar.*)" \
      "6" "Import VM backup (vma.*)" \
      "7" "Create LXC from template" \
      "8" "Create VM from template" \
      "9" "Template catalog / cleanup" \
      "10" "Exit" 3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
      D) toggle_debug ;;
      1) export_lxc_single "$(pick_lxc)" ;;
      2) export_vm_single "$(pick_vm)" ;;
      3) export_lxc_batch ;;
      4) export_vm_batch ;;
      5) import_lxc_template ;;
      6) import_vm_backup ;;
      7) create_lxc_from_gui_template ;;
      8) create_vm_from_template ;;
      9) template_catalog_cleanup ;;
      10) exit 0 ;;
    esac
  done
}

require_pve
require_tools
trap cleanup_temp_clones EXIT
header_info
main_menu
