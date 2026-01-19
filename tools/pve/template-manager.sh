#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Brandon Groves
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

set -eEuo pipefail

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

function header_info() {
  clear
  cat <<"EOF"
 ______                  __        __  ___                               
/_  __/__  ____ ___  ____/ /___  __/  |/  /___ _____  ____ _____ _____   
 / / / _ \/ __ `__ \/ __  / __ \/ / /|_/ / __ `/ __ \/ __ `/ __ `/ __ \  
/ / /  __/ / / / / / /_/ / /_/ / / /  / / /_/ / / / / /_/ / /_/ / /_/ /  
/_/  \___/_/ /_/ /_/\__,_/\____/_/_/  /_/\__,_/_/ /_/\__,_/\__, /\____/   
                                                        /____/           
EOF
}

function msg_info() { echo -ne " ${HOLD} ${YW}${1}...${CL}"; }
function msg_ok() { echo -e "${BFR} ${CM} ${GN}${1}${CL}"; }
function msg_error() { echo -e "${BFR} ${CROSS} ${RD}${1}${CL}"; }

function require_pve() {
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "Run this on a Proxmox VE host."
    exit 1
  fi
}

function require_tools() {
  local missing=()
  for tool in whiptail awk sed grep curl pvesm pct qm vzdump pvesh; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    msg_error "Missing tools: ${missing[*]}"
    exit 1
  fi
}

function storage_path_from_cfg() {
  local storage="$1"
  awk -v s="$storage" '
    $1 ~ /:$/ {type=substr($1,1,length($1)-1); name=$2; inblock=(name==s)}
    inblock && $1=="path" {print $2; exit}
  ' /etc/pve/storage.cfg
}

function list_storages_for_content() {
  local content="$1"
  pvesm status -content "$content" | awk 'NR>1{print $1}'
}

function select_storage() {
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

function get_vztmpl_dir() {
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

function get_backup_dir() {
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

function pick_lxc() {
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

function pick_vm() {
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

function sanitize_lxc() {
  local ctid="$1"
  if ! pct status "$ctid" | grep -q "status: running"; then
    msg_error "Container must be running to sanitize. Start it first."
    exit 1
  fi
  msg_info "Sanitizing container filesystem"
  pct exec "$ctid" -- sh -c '
    rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
    : > /etc/machine-id 2>/dev/null || true
    rm -f /etc/udev/rules.d/70* 2>/dev/null || true
    find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
    rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
    cat /dev/null > /root/.bash_history 2>/dev/null || true
  '
  msg_ok "Sanitized container"
}

function export_lxc_template() {
  local ctid="$1"
  local storage template_dir backup_file

  if whiptail --yesno "Run cleanup inside CT $ctid before export?" 10 60; then
    sanitize_lxc "$ctid"
  fi

  msg_info "Removing net0 from container config"
  pct set "$ctid" --delete net0 >/dev/null 2>&1 || true
  msg_ok "Removed net0"

  if whiptail --yesno "Convert CT $ctid to a Proxmox template?" 10 60; then
    pct template "$ctid" >/dev/null 2>&1 || true
    msg_ok "Container marked as template"
  fi

  storage=$(select_storage "vztmpl" "Template Storage")
  template_dir=$(get_vztmpl_dir "$storage")
  mkdir -p "$template_dir"

  msg_info "Exporting template (vzdump)"
  vzdump "$ctid" --mode stop --compress gzip --dumpdir "$template_dir" >/dev/null
  msg_ok "Export completed"

  backup_file=$(ls -t "$template_dir"/vzdump-lxc-"$ctid"-*.tar.gz | head -n1)
  if [[ -z "$backup_file" ]]; then
    msg_error "Unable to locate exported tarball."
    exit 1
  fi

  local ostype osver name rev arch new_name
  ostype=$(pct config "$ctid" | awk '/^ostype:/ {print $2}')
  arch=$(pct config "$ctid" | awk '/^arch:/ {print $2}')
  osver=$(whiptail --inputbox "OS version (e.g., 24.04, 12, 3.22):" 10 60 "" 3>&1 1>&2 2>&3)
  name=$(whiptail --inputbox "Template name (identifier):" 10 60 "custom" 3>&1 1>&2 2>&3)
  rev=$(whiptail --inputbox "Revision (e.g., 1):" 10 60 "1" 3>&1 1>&2 2>&3)
  arch=${arch:-amd64}
  ostype=${ostype:-custom}

  new_name="${ostype}-${osver}-${name}_${osver}-${rev}_${arch}.tar.gz"
  if whiptail --yesno "Rename export to:\n${new_name}" 10 70; then
    mv "$backup_file" "$template_dir/$new_name"
    backup_file="$template_dir/$new_name"
  fi

  msg_ok "Template ready: $backup_file"
  whiptail --msgbox "Template saved to:\n$backup_file\n\nThis file will appear in the Proxmox GUI under CT Templates for storage: $storage." 12 70
}

function import_lxc_template() {
  local storage template_dir source method url dest filename
  storage=$(select_storage "vztmpl" "Template Storage")
  template_dir=$(get_vztmpl_dir "$storage")
  mkdir -p "$template_dir"

  method=$(whiptail --title "Import Method" --menu "Choose import method:" 12 60 2 \
    "file" "Copy from local path" \
    "url" "Download from URL" 3>&1 1>&2 2>&3)

  case "$method" in
  file)
    source=$(whiptail --inputbox "Full path to .tar.gz:" 10 70 "" 3>&1 1>&2 2>&3)
    filename=$(basename "$source")
    dest="$template_dir/$filename"
    cp "$source" "$dest"
    ;;
  url)
    url=$(whiptail --inputbox "Direct URL to .tar.gz:" 10 70 "" 3>&1 1>&2 2>&3)
    filename=$(basename "$url")
    dest="$template_dir/$filename"
    curl -fsSL "$url" -o "$dest"
    ;;
  esac

  msg_ok "Imported template: $dest"

  if whiptail --yesno "Create a new container from this template now?" 10 60; then
    create_lxc_from_template "$storage" "$dest"
  fi
}

function create_lxc_from_template() {
  local storage="$1" template_path="$2"
  local ctid hostname root_storage disk_size password

  ctid=$(pvesh get /cluster/nextid)
  ctid=$(whiptail --inputbox "Container ID:" 10 60 "$ctid" 3>&1 1>&2 2>&3)
  hostname=$(whiptail --inputbox "Hostname:" 10 60 "ct-$ctid" 3>&1 1>&2 2>&3)
  root_storage=$(select_storage "rootdir" "RootFS Storage")
  disk_size=$(whiptail --inputbox "Disk size (GB):" 10 60 "8" 3>&1 1>&2 2>&3)
  password=$(whiptail --passwordbox "Root password:" 10 60 3>&1 1>&2 2>&3)
  if [[ -z "$password" ]]; then
    msg_error "Password cannot be empty."
    exit 1
  fi

  msg_info "Creating container"
  pct create "$ctid" "$storage:vztmpl/$(basename "$template_path")" \
    -hostname "$hostname" \
    -rootfs "$root_storage:$disk_size" \
    -net0 name=eth0,bridge=vmbr0,ip=dhcp \
    -password "$password" >/dev/null
  msg_ok "Container created: $ctid"
}

function export_vm_template() {
  local vmid storage backup_dir
  vmid="$1"

  if whiptail --yesno "Stop VM $vmid for export?" 10 60; then
    qm shutdown "$vmid" --timeout 120 >/dev/null 2>&1 || qm stop "$vmid" >/dev/null 2>&1
  fi

  if whiptail --yesno "Convert VM $vmid to a Proxmox template?" 10 60; then
    qm template "$vmid" >/dev/null 2>&1 || true
    msg_ok "VM marked as template"
  fi

  storage=$(select_storage "backup" "Backup Storage")
  backup_dir=$(get_backup_dir "$storage")
  mkdir -p "$backup_dir"

  msg_info "Exporting VM backup"
  vzdump "$vmid" --mode stop --compress gzip --dumpdir "$backup_dir" >/dev/null
  msg_ok "VM backup created in $backup_dir"

  whiptail --msgbox "Backup saved to:\n$backup_dir\n\nVM backups appear in the Proxmox GUI under the selected backup storage." 12 70
}

function import_vm_backup() {
  local storage backup_dir method source url filename dest new_vmid target_storage
  storage=$(select_storage "backup" "Backup Storage")
  backup_dir=$(get_backup_dir "$storage")
  mkdir -p "$backup_dir"

  method=$(whiptail --title "Import Method" --menu "Choose import method:" 12 60 2 \
    "file" "Copy from local path" \
    "url" "Download from URL" 3>&1 1>&2 2>&3)

  case "$method" in
  file)
    source=$(whiptail --inputbox "Full path to .vma.gz or .vma.zst:" 10 70 "" 3>&1 1>&2 2>&3)
    filename=$(basename "$source")
    dest="$backup_dir/$filename"
    cp "$source" "$dest"
    ;;
  url)
    url=$(whiptail --inputbox "Direct URL to backup file:" 10 70 "" 3>&1 1>&2 2>&3)
    filename=$(basename "$url")
    dest="$backup_dir/$filename"
    curl -fsSL "$url" -o "$dest"
    ;;
  esac

  msg_ok "Imported VM backup: $dest"

  if whiptail --yesno "Restore this backup to a new VM now?" 10 60; then
    new_vmid=$(pvesh get /cluster/nextid)
    new_vmid=$(whiptail --inputbox "New VM ID:" 10 60 "$new_vmid" 3>&1 1>&2 2>&3)
    target_storage=$(select_storage "images" "VM Storage")
    qmrestore "$dest" "$new_vmid" --storage "$target_storage" >/dev/null
    msg_ok "VM restored: $new_vmid"

    if whiptail --yesno "Convert VM $new_vmid to a template?" 10 60; then
      qm template "$new_vmid" >/dev/null 2>&1 || true
      msg_ok "VM marked as template"
    fi
  fi
}

function create_vm_from_template() {
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

function create_lxc_from_gui_template() {
  local storage template_dir templates menu=() choice
  storage=$(select_storage "vztmpl" "Template Storage")
  template_dir=$(get_vztmpl_dir "$storage")
  mapfile -t templates < <(ls -1 "$template_dir"/*.tar.gz 2>/dev/null || true)
  if [[ ${#templates[@]} -eq 0 ]]; then
    msg_error "No .tar.gz templates found in $template_dir"
    exit 1
  fi
  for t in "${templates[@]}"; do
    menu+=("$(basename "$t")" "template")
  done
  choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select LXC Template" \
    --menu "Choose a template:" 18 70 10 "${menu[@]}" 3>&1 1>&2 2>&3)
  create_lxc_from_template "$storage" "$template_dir/$choice"
}

function main_menu() {
  while true; do
    header_info
    local choice
    choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Template Manager" --menu \
      "Select an action:" 20 70 10 \
      "1" "Create LXC template + export (.tar.gz)" \
      "2" "Create VM template + export backup" \
      "3" "Import LXC template (.tar.gz)" \
      "4" "Import VM backup (vma.*)" \
      "5" "Create LXC from template" \
      "6" "Create VM from template" \
      "7" "Exit" 3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
    1)
      export_lxc_template "$(pick_lxc)"
      ;;
    2)
      export_vm_template "$(pick_vm)"
      ;;
    3)
      import_lxc_template
      ;;
    4)
      import_vm_backup
      ;;
    5)
      create_lxc_from_gui_template
      ;;
    6)
      create_vm_from_template
      ;;
    7)
      exit 0
      ;;
    esac
  done
}

require_pve
require_tools
main_menu
