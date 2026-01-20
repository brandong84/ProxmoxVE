#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Brandon Groves
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADER_FILE="$SCRIPT_DIR/../headers/lxc-network-share-manager"
LOG_FILE="/var/log/lxc-network-share-manager.log"
BACKUP_DIR="/var/backups/lxc-network-share-manager"
PROFILE_DIR="/var/lib/lxc-network-share-manager/profiles"
DRY_RUN="${DRY_RUN:-0}"
AUTO_REMOUNT="${AUTO_REMOUNT:-0}"
READ_ONLY_DEFAULT="${READ_ONLY_DEFAULT:-0}"

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="[OK]"
CROSS="[ERR]"

mkdir -p /var/log "$BACKUP_DIR" "$PROFILE_DIR"
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
 _     __   ______        __        __     __          ____  __                       
| |   / /  / ____/_______/ /_____  / /_   / /_  ____  / __ \/ /___ _____  ____  _____
| |  / /  / /   / ___/ __  / __ \/ __/  / __ \/ __ \/ / / / / __ `/ __ \/ __ \/ ___/
| | / /  / /___/ /  / /_/ / /_/ / /_   / /_/ / /_/ / /_/ / / /_/ / / / / /_/ / /    
|_|/_/   \____/_/   \__,_/\____/\__/  /_.___/\____/\____/_/\__,_/_/ /_/\____/_/     
EOF
  fi
}

msg_info() { echo -ne " ${HOLD} ${YW}${1}...${CL}" >&2; log_line "INFO" "$1"; }
msg_ok() { echo -e "${BFR} ${CM} ${GN}${1}${CL}" >&2; log_line "OK" "$1"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}${1}${CL}" >&2; log_line "ERROR" "$1"; }

mask_secret() {
  local input="$1"
  if [[ -z "$input" ]]; then
    echo ""
  else
    echo "****"
  fi
}

run_cmd() {
  local cmd="$*"
  log_line "INFO" "cmd: $cmd"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY RUN: $cmd"
    return 0
  fi
  eval "$cmd"
}

run_cmd_allow_fail() {
  local cmd="$*"
  log_line "INFO" "cmd: $cmd"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY RUN: $cmd"
    return 0
  fi
  eval "$cmd" || return 1
}

append_ro_option() {
  local opts="$1"
  if echo "$opts" | grep -qE '(^|,)ro(,|$)'; then
    echo "$opts"
  elif echo "$opts" | grep -qE '(^|,)rw(,|$)'; then
    echo "$opts" | sed 's/\(^\|,\)rw\($\|,\)/\1ro\2/'
  else
    if [[ -n "$opts" ]]; then
      echo "ro,${opts}"
    else
      echo "ro"
    fi
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
  for tool in whiptail pct pvesh pvesm awk sed grep mount umount df ping; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    msg_error "Missing tools: ${missing[*]}"
    exit 1
  fi
}

ensure_pkg() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if whiptail --yesno "Install missing package: ${pkg}?" 10 60; then
      run_cmd "apt-get update >/dev/null 2>&1"
      run_cmd "apt-get install -y \"$pkg\" >/dev/null 2>&1"
    else
      msg_error "Required package missing: $pkg"
      exit 1
    fi
  fi
}

backup_fstab() {
  local ts
  ts="$(date '+%Y%m%d-%H%M%S')"
  run_cmd "cp /etc/fstab \"$BACKUP_DIR/fstab.$ts\""
  run_cmd "ln -sf \"$BACKUP_DIR/fstab.$ts\" \"$BACKUP_DIR/fstab.last\""
  msg_ok "Backed up /etc/fstab"
}

restore_fstab() {
  if [[ -f "$BACKUP_DIR/fstab.last" ]]; then
    run_cmd "cp -f \"$BACKUP_DIR/fstab.last\" /etc/fstab"
    msg_ok "Restored /etc/fstab from last backup"
  else
    msg_error "No fstab backup found."
  fi
}

validate_ip() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  local octet
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    if ((octet < 0 || octet > 255)); then
      return 1
    fi
  done
  return 0
}

test_host() {
  local ip="$1"
  if ! ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
    whiptail --yesno "Ping to ${ip} failed. Continue anyway?" 10 60 || return 1
  fi
  return 0
}

select_container() {
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

is_unprivileged() {
  local ctid="$1"
  pct config "$ctid" | awk '/^unprivileged:/ {print $2}' | grep -q '^1$'
}

get_container_users() {
  local ctid="$1"
  if pct status "$ctid" | grep -q "status: running"; then
    pct exec "$ctid" -- sh -c "getent passwd | awk -F: '\$3>=1000 && \$3<60000 {print \$1\":\"\$3\":\"\$4}'" 2>/dev/null || true
  fi
}

prompt_uid_gid() {
  local ctid="$1" unpriv="$2"
  local default_uid=1000 default_gid=1000
  local list users selected uid gid

  users=$(get_container_users "$ctid")
  if [[ -n "$users" ]]; then
    list=$(printf "%s\n" "$users" | awk -F: '{print $1" "$2" "$3}')
    selected=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select User" \
      --menu "Select a container user (UID:GID):" 20 70 10 $list 3>&1 1>&2 2>&3) || true
    if [[ -n "$selected" ]]; then
      uid=$(printf "%s\n" "$users" | awk -F: -v u="$selected" '$1==u{print $2}')
      gid=$(printf "%s\n" "$users" | awk -F: -v u="$selected" '$1==u{print $3}')
      default_uid="${uid:-1000}"
      default_gid="${gid:-1000}"
    fi
  fi

  default_uid=$(whiptail --inputbox "Container UID:" 10 60 "$default_uid" 3>&1 1>&2 2>&3)
  default_gid=$(whiptail --inputbox "Container GID:" 10 60 "$default_gid" 3>&1 1>&2 2>&3)

  if [[ "$unpriv" == "yes" ]]; then
    echo "$default_uid $default_gid $((default_uid + 100000)) $((default_gid + 100000))"
  else
    echo "$default_uid $default_gid $default_uid $default_gid"
  fi
}

prompt_permissions() {
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Permissions" \
    --menu "Select permissions for the host mountpoint:" 15 70 5 \
    "770" "Private (rw for owner/group)" \
    "755" "Public (rw for owner, r for others)" \
    "700" "Secure (rw for owner only)" \
    "775" "Shared (rw for owner/group, r for others)" \
    "750" "Team (rw for owner, r for group)" 3>&1 1>&2 2>&3
}

detect_conflicts() {
  local host_path="$1"
  local conflicts=""

  if mountpoint -q "$host_path"; then
    conflicts+="Host path is already mounted: ${host_path}\n"
  fi

  if grep -q " ${host_path} " /etc/fstab; then
    conflicts+="Host path exists in /etc/fstab: ${host_path}\n"
  fi

  while read -r id; do
    if pct config "$id" | grep -qE "mp[0-9]+:.*${host_path}"; then
      conflicts+="Host path is already mapped to CT ${id}\n"
    fi
  done < <(pct list | awk 'NR>1 {print $1}')

  if [[ -n "$conflicts" ]]; then
    whiptail --yesno "Potential conflicts found:\n\n${conflicts}\nContinue anyway?" 15 72 || return 1
  fi
  return 0
}

show_access_report() {
  local ctid="$1" host_path="$2" ct_path="$3" uid="$4" gid="$5" host_uid="$6" host_gid="$7" perm_mode="$8" perms="$9" unpriv="${10}"
  local report=""
  report+="CTID: ${ctid}\n"
  report+="Container path: ${ct_path}\n"
  report+="Host path: ${host_path}\n"
  report+="Container UID:GID: ${uid}:${gid}\n"
  report+="Host UID:GID: ${host_uid}:${host_gid}\n"
  report+="Unprivileged: ${unpriv}\n"
  report+="Permission mode: ${perm_mode}\n"
  report+="Permissions: ${perms}\n"
  whiptail --msgbox "$report" 16 70
}

preview_summary() {
  local share_type="$1" server="$2" share="$3" host_path="$4" ct_path="$5" ctid="$6"
  local opts="$7" perm_mode="$8" perms="$9" ro="${10}"
  local summary=""
  summary+="Type: ${share_type}\n"
  summary+="Server: ${server}\n"
  summary+="Share: ${share}\n"
  summary+="Host path: ${host_path}\n"
  summary+="Container: ${ctid}:${ct_path}\n"
  summary+="Options: ${opts}\n"
  summary+="Permissions mode: ${perm_mode}\n"
  summary+="Permissions: ${perms}\n"
  summary+="Read-only: ${ro}\n"
  whiptail --yesno "$summary\n\nProceed?" 18 70
}

prompt_permission_mode() {
  local share_type="$1"
  if [[ "$share_type" == "cifs" ]]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "Permission Handling" \
      --menu "How should permissions be handled?" 14 72 4 \
      "none" "Do not change permissions (recommended)" \
      "cifs" "Set UID/GID in mount options (safe)" \
      "host" "Apply chown/chmod on host mountpoint (advanced)" 3>&1 1>&2 2>&3
  else
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "Permission Handling" \
      --menu "How should permissions be handled?" 12 72 3 \
      "none" "Do not change permissions (recommended)" \
      "host" "Apply chown/chmod on host mountpoint (advanced)" 3>&1 1>&2 2>&3
  fi
}

creds_file_path() {
  local ctid="$1" share="$2"
  local safe_share
  safe_share=$(echo "$share" | tr '/\\' '_' | tr -cd 'A-Za-z0-9._-')
  echo "/root/.smbcredentials-lxcshare-${ctid}-${safe_share}"
}

write_creds_file() {
  local path="$1" user="$2" pass="$3"
  run_cmd "printf \"username=%s\\npassword=%s\\n\" \"$user\" \"$pass\" >\"$path\""
  run_cmd "chmod 600 \"$path\""
}

test_write_access() {
  local path="$1"
  local test_file="${path}/.lxc_share_manager_test"
  if run_cmd_allow_fail "touch \"$test_file\""; then
    run_cmd "rm -f \"$test_file\""
    return 0
  fi
  return 1
}

next_mp_index() {
  local ctid="$1"
  local max=-1
  while read -r line; do
    local idx
    idx=$(echo "$line" | sed -n 's/^mp\([0-9]\+\):.*/\1/p')
    if [[ -n "$idx" && "$idx" -gt "$max" ]]; then
      max="$idx"
    fi
  done < <(pct config "$ctid" | grep -E '^mp[0-9]+:')
  echo $((max + 1))
}

add_ct_mount() {
  local ctid="$1" host_path="$2" ct_path="$3"
  local mp_idx
  mp_idx=$(next_mp_index "$ctid")
  run_cmd "pct set \"$ctid\" -mp${mp_idx} \"${host_path},mp=${ct_path},backup=0\" >/dev/null"
}

remove_ct_mount() {
  local ctid="$1" host_path="$2"
  local line mp_idx
  line=$(pct config "$ctid" | grep -E "^mp[0-9]+:.*${host_path}" || true)
  if [[ -n "$line" ]]; then
    mp_idx=$(echo "$line" | sed -n 's/^mp\([0-9]\+\):.*/\1/p')
    run_cmd "pct set \"$ctid\" --delete \"mp${mp_idx}\" >/dev/null"
  fi
}

mount_nfs() {
  local server="$1" share="$2" host_path="$3" options="$4"
  ensure_pkg showmount nfs-common
  if ! showmount -e "$server" 2>/dev/null | grep -q "$share"; then
    whiptail --yesno "NFS export not found via showmount. Continue anyway?" 10 70 || return 1
  fi
  run_cmd "mkdir -p \"$host_path\""
  run_cmd "mount -t nfs -o \"$options\" \"${server}:${share}\" \"$host_path\""
}

mount_cifs() {
  local server="$1" share="$2" host_path="$3" user="$4" pass="$5" options="$6"
  ensure_pkg mount.cifs cifs-utils
  ensure_pkg smbclient smbclient
  if [[ -n "$user" ]]; then
    smbclient -L "//$server" -U "${user}%${pass}" -m SMB3 >/dev/null 2>&1 || true
  else
    smbclient -L "//$server" -N -m SMB3 >/dev/null 2>&1 || true
  fi
  run_cmd "mkdir -p \"$host_path\""
  if [[ -n "$user" ]]; then
    run_cmd "mount -t cifs -o \"username=${user},password=${pass},${options}\" \"//${server}/${share}\" \"$host_path\""
  else
    run_cmd "mount -t cifs -o \"guest,${options}\" \"//${server}/${share}\" \"$host_path\""
  fi
}

add_fstab_entry() {
  local line="$1"
  backup_fstab
  run_cmd "echo \"$line\" >>/etc/fstab"
}

remove_fstab_entry() {
  local marker="$1"
  backup_fstab
  run_cmd "sed -i \"\\|$marker|d\" /etc/fstab"
}

health_check() {
  local marker="lxc-share-manager"
  local entries
  entries=$(grep "$marker" /etc/fstab || true)
  if [[ -z "$entries" ]]; then
    whiptail --msgbox "No managed shares found in /etc/fstab." 10 60
    return 0
  fi
  local report=""
  while read -r line; do
    local src target status
    src=$(echo "$line" | awk '{print $1}')
    target=$(echo "$line" | awk '{print $2}')
    if mountpoint -q "$target"; then
      status="mounted"
    else
      status="not mounted"
      if [[ "$AUTO_REMOUNT" -eq 1 ]]; then
        run_cmd_allow_fail "mount \"$target\" >/dev/null 2>&1" || true
      fi
    fi
    report+="$target ($src): $status\n"
  done <<<"$entries"
  whiptail --msgbox "$report" 18 70
}

schedule_health_check() {
  local cron_file="/etc/cron.d/lxc-network-share-manager"
  local interval
  interval=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Schedule Health Check" \
    --menu "Select interval:" 12 60 4 \
    "5m" "Every 5 minutes" \
    "15m" "Every 15 minutes" \
    "1h" "Hourly" \
    "1d" "Daily" 3>&1 1>&2 2>&3)
  local cron_expr="*/5 * * * *"
  case "$interval" in
    5m) cron_expr="*/5 * * * *" ;;
    15m) cron_expr="*/15 * * * *" ;;
    1h) cron_expr="0 * * * *" ;;
    1d) cron_expr="0 3 * * *" ;;
  esac
  if whiptail --yesno "Enable auto-remount for missing mounts?" 10 60; then
    AUTO_REMOUNT=1
  else
    AUTO_REMOUNT=0
  fi
  run_cmd "printf \"%s root AUTO_REMOUNT=%s /usr/local/bin/lxc-network-share-manager --health-check\\n\" \"$cron_expr\" \"$AUTO_REMOUNT\" > \"$cron_file\""
  run_cmd "chmod 644 \"$cron_file\""
  msg_ok "Scheduled health check"
}

save_profile() {
  local name="$1" type="$2" server="$3" share="$4" host_path="$5" ct_path="$6" ctid="$7"
  local uid="$8" gid="$9" perms="${10}" perm_mode="${11}" opts="${12}" user="${13}" pass="${14}"
  local file="$PROFILE_DIR/${name}.conf"
  run_cmd "cat >\"$file\" <<EOF
type=$type
server=$server
share=$share
host_path=$host_path
ct_path=$ct_path
ctid=$ctid
uid=$uid
gid=$gid
perms=$perms
perm_mode=$perm_mode
options=$opts
username=$user
password=
EOF"
  if [[ -n "$pass" ]] && whiptail --yesno "Save SMB password in profile (not recommended)?" 10 68; then
    run_cmd "sed -i \"s|^password=.*|password=$pass|\" \"$file\""
  fi
  run_cmd "chmod 600 \"$file\""
}

load_profile() {
  local file="$1"
  # shellcheck disable=SC1090
  source "$file"
}

select_profile() {
  local menu=() choice
  for f in "$PROFILE_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    menu+=("$(basename "$f" .conf)" "$f")
  done
  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_error "No profiles found."
    exit 1
  fi
  choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Profiles" \
    --menu "Select a profile:" 18 70 10 "${menu[@]}" 3>&1 1>&2 2>&3)
  echo "$choice"
}

apply_profile() {
  local name
  name=$(select_profile)
  local file="$PROFILE_DIR/${name}.conf"
  load_profile "$file"

  local pass=""
  if [[ -n "${username:-}" && -n "${password:-}" ]]; then
    pass="$password"
  elif [[ -n "${username:-}" ]]; then
    pass=$(whiptail --passwordbox "SMB password for ${username}:" 10 60 3>&1 1>&2 2>&3)
  fi

  non_interactive_add "$type" "$server" "$share" "$host_path" "$ct_path" "$ctid" \
    "$uid" "$gid" "$perms" "$perm_mode" "$username" "$pass" "$options"
}

add_share_interactive() {
  local share_type server_ip share host_path ct_path ctid unpriv
  local uid gid host_uid host_gid perms
  local opts user pass
  local marker perm_mode test_write use_creds creds_file
  local read_only

  share_type=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Share Type" \
    --menu "Select share type:" 12 60 2 \
    "nfs" "NFS" \
    "cifs" "SMB/CIFS" 3>&1 1>&2 2>&3)

  server_ip=$(whiptail --inputbox "Server IP address:" 10 60 "" 3>&1 1>&2 2>&3)
  if ! validate_ip "$server_ip"; then
    msg_error "Invalid IP address."
    exit 1
  fi
  test_host "$server_ip"

  if [[ "$share_type" == "nfs" ]]; then
    share=$(whiptail --inputbox "NFS export path (e.g., /export/share):" 10 70 "" 3>&1 1>&2 2>&3)
    opts=$(whiptail --inputbox "NFS mount options:" 10 70 "rw,vers=4" 3>&1 1>&2 2>&3)
  else
    share=$(whiptail --inputbox "SMB share name (e.g., data):" 10 70 "" 3>&1 1>&2 2>&3)
    if whiptail --yesno "Use guest access?" 10 50; then
      user=""
      pass=""
    else
      user=$(whiptail --inputbox "SMB username:" 10 60 "" 3>&1 1>&2 2>&3)
      pass=$(whiptail --passwordbox "SMB password:" 10 60 3>&1 1>&2 2>&3)
    fi
    opts=$(whiptail --inputbox "SMB mount options:" 10 70 "rw,vers=3.0" 3>&1 1>&2 2>&3)
  fi

  host_path=$(whiptail --inputbox "Host mount path:" 10 70 "/mnt/shares/${share}" 3>&1 1>&2 2>&3)
  detect_conflicts "$host_path"
  ctid=$(select_container)
  ct_path=$(whiptail --inputbox "Container mount path:" 10 70 "/mnt/${share}" 3>&1 1>&2 2>&3)

  if is_unprivileged "$ctid"; then
    unpriv="yes"
  else
    unpriv="no"
  fi

  read -r uid gid host_uid host_gid < <(prompt_uid_gid "$ctid" "$unpriv")
  perms=$(prompt_permissions)
  perm_mode=$(prompt_permission_mode "$share_type")
  if [[ "$READ_ONLY_DEFAULT" -eq 1 ]] || whiptail --yesno "Mount share read-only?" 10 55; then
    read_only="yes"
    opts=$(append_ro_option "$opts")
  else
    read_only="no"
  fi
  if whiptail --yesno "Test write access after mount?" 10 55; then
    test_write="yes"
  else
    test_write="no"
  fi

  preview_summary "$share_type" "$server_ip" "$share" "$host_path" "$ct_path" "$ctid" "$opts" "$perm_mode" "$perms" "$read_only" || return 0

  msg_info "Mounting share on host"
  if [[ "$share_type" == "nfs" ]]; then
    mount_nfs "$server_ip" "$share" "$host_path" "$opts"
  else
    if [[ -n "$user" ]]; then
      if whiptail --yesno "Store SMB credentials in a secure file (recommended)?" 10 68; then
        use_creds="yes"
        creds_file=$(creds_file_path "$ctid" "$share")
        write_creds_file "$creds_file" "$user" "$pass"
        opts="credentials=${creds_file},${opts}"
        user=""
        pass=""
      fi
    fi
    if [[ "$perm_mode" == "cifs" ]]; then
      opts="uid=${host_uid},gid=${host_gid},dir_mode=0${perms},file_mode=0${perms},${opts}"
    fi
    mount_cifs "$server_ip" "$share" "$host_path" "$user" "$pass" "$opts"
  fi
  msg_ok "Mounted share"

  if [[ "$perm_mode" == "host" ]]; then
    run_cmd "chown \"$host_uid:$host_gid\" \"$host_path\""
    run_cmd "chmod \"$perms\" \"$host_path\""
    msg_ok "Applied ownership and permissions"
  else
    msg_ok "Permissions left unchanged"
  fi

  marker="# lxc-share-manager ctid=${ctid} host=${host_path} ct=${ct_path}"
  if [[ "$share_type" == "nfs" ]]; then
    add_fstab_entry "${server_ip}:${share} ${host_path} nfs ${opts} 0 0 ${marker}"
  else
    if [[ -n "$user" ]]; then
      add_fstab_entry "//${server_ip}/${share} ${host_path} cifs username=${user},password=${pass},${opts} 0 0 ${marker}"
    else
      add_fstab_entry "//${server_ip}/${share} ${host_path} cifs guest,${opts} 0 0 ${marker}"
    fi
  fi

  if pct status "$ctid" | grep -q "status: running"; then
    pct exec "$ctid" -- mkdir -p "$ct_path" >/dev/null 2>&1 || true
  else
    if whiptail --yesno "Container is stopped. Start it to create the mount path?" 10 60; then
      pct start "$ctid" >/dev/null 2>&1 || true
      pct exec "$ctid" -- mkdir -p "$ct_path" >/dev/null 2>&1 || true
      pct shutdown "$ctid" --timeout 30 >/dev/null 2>&1 || true
    fi
  fi

  add_ct_mount "$ctid" "$host_path" "$ct_path"
  msg_ok "Mapped share into container"

  if [[ "$test_write" == "yes" ]]; then
    if test_write_access "$host_path"; then
      msg_ok "Write test succeeded"
    else
      msg_error "Write test failed"
    fi
  fi

  whiptail --msgbox "Share mounted and mapped.\n\nHost: ${host_path}\nContainer: ${ctid}:${ct_path}" 12 70
  show_access_report "$ctid" "$host_path" "$ct_path" "$uid" "$gid" "$host_uid" "$host_gid" "$perm_mode" "$perms" "$unpriv"

  if whiptail --yesno "Save this configuration as a profile?" 10 60; then
    local profile_name
    profile_name=$(whiptail --inputbox "Profile name:" 10 60 "share-${ctid}" 3>&1 1>&2 2>&3)
    save_profile "$profile_name" "$share_type" "$server_ip" "$share" "$host_path" "$ct_path" "$ctid" \
      "$uid" "$gid" "$perms" "$perm_mode" "$opts" "$user" "$pass"
    msg_ok "Profile saved"
  fi
}

remove_share_interactive() {
  local entries menu=() selection marker host_path ctid
  entries=$(grep "lxc-share-manager" /etc/fstab || true)
  if [[ -z "$entries" ]]; then
    whiptail --msgbox "No managed shares found." 10 60
    return 0
  fi
  while read -r line; do
    local target
    target=$(echo "$line" | awk '{print $2}')
    menu+=("$target" "$line")
  done <<<"$entries"

  selection=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Remove Share" \
    --menu "Select a share to remove:" 20 78 10 "${menu[@]}" 3>&1 1>&2 2>&3) || return 0

  marker=$(grep "lxc-share-manager" /etc/fstab | grep -F " ${selection} " || true)
  host_path="$selection"
  ctid=$(echo "$marker" | sed -n 's/.*ctid=\([0-9]\+\).*/\1/p')

  run_cmd "umount \"$host_path\" >/dev/null 2>&1 || true"
  remove_fstab_entry "host=${host_path}"
  if [[ -n "$ctid" ]]; then
    remove_ct_mount "$ctid" "$host_path"
  fi
  msg_ok "Share removed"
}

non_interactive_add() {
  local type="$1" server="$2" share="$3" host_path="$4" ct_path="$5" ctid="$6"
  local uid="$7" gid="$8" perms="$9" perm_mode="${10:-none}"
  local user="${11:-}" pass="${12:-}" opts="${13:-}" readonly="${14:-0}"
  local unpriv host_uid host_gid marker
  local creds_file

  if ! validate_ip "$server"; then
    msg_error "Invalid IP address."
    exit 1
  fi
  test_host "$server"

  if is_unprivileged "$ctid"; then
    unpriv="yes"
  else
    unpriv="no"
  fi

  if [[ "$unpriv" == "yes" ]]; then
    host_uid=$((uid + 100000))
    host_gid=$((gid + 100000))
  else
    host_uid="$uid"
    host_gid="$gid"
  fi

  detect_conflicts "$host_path"
  run_cmd "mkdir -p \"$host_path\""
  if [[ "$type" == "nfs" ]]; then
    if [[ "$readonly" -eq 1 ]]; then
      opts=$(append_ro_option "${opts:-rw,vers=4}")
    fi
    mount_nfs "$server" "$share" "$host_path" "${opts:-rw,vers=4}"
    marker="# lxc-share-manager ctid=${ctid} host=${host_path} ct=${ct_path}"
    add_fstab_entry "${server}:${share} ${host_path} nfs ${opts:-rw,vers=4} 0 0 ${marker}"
  else
    if [[ "$readonly" -eq 1 ]]; then
      opts=$(append_ro_option "${opts:-rw,vers=3.0}")
    fi
    if [[ "$perm_mode" == "cifs" ]]; then
      opts="uid=${host_uid},gid=${host_gid},dir_mode=0${perms},file_mode=0${perms},${opts}"
    fi
    if [[ -n "$user" ]]; then
      creds_file=$(creds_file_path "$ctid" "$share")
      write_creds_file "$creds_file" "$user" "$pass"
      opts="credentials=${creds_file},${opts}"
      user=""
      pass=""
    fi
    mount_cifs "$server" "$share" "$host_path" "$user" "$pass" "${opts:-rw,vers=3.0}"
    marker="# lxc-share-manager ctid=${ctid} host=${host_path} ct=${ct_path}"
    if [[ -n "$user" ]]; then
      add_fstab_entry "//${server}/${share} ${host_path} cifs username=${user},password=${pass},${opts:-rw,vers=3.0} 0 0 ${marker}"
    else
      add_fstab_entry "//${server}/${share} ${host_path} cifs guest,${opts:-rw,vers=3.0} 0 0 ${marker}"
    fi
  fi

  if [[ "$perm_mode" == "host" ]]; then
    run_cmd "chown \"$host_uid:$host_gid\" \"$host_path\""
    run_cmd "chmod \"$perms\" \"$host_path\""
  fi
  add_ct_mount "$ctid" "$host_path" "$ct_path"
  msg_ok "Share mounted and mapped"
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    return 1
  fi

  local type="" server="" share="" host_path="" ct_path="" ctid="" uid="1000" gid="1000" perms="770" perm_mode="none" user="" pass="" opts="" readonly=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) type="$2"; shift 2 ;;
      --server) server="$2"; shift 2 ;;
      --share) share="$2"; shift 2 ;;
      --host-path) host_path="$2"; shift 2 ;;
      --ct-path) ct_path="$2"; shift 2 ;;
      --ctid) ctid="$2"; shift 2 ;;
      --uid) uid="$2"; shift 2 ;;
      --gid) gid="$2"; shift 2 ;;
      --perms) perms="$2"; shift 2 ;;
      --perm-mode) perm_mode="$2"; shift 2 ;;
      --username) user="$2"; shift 2 ;;
      --password) pass="$2"; shift 2 ;;
      --options) opts="$2"; shift 2 ;;
      --health-check) health_check; exit 0 ;;
      --auto-remount) AUTO_REMOUNT=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --readonly) readonly=1; shift ;;
      --help)
        cat <<'EOF'
Usage: lxc-network-share-manager.sh --type nfs|cifs --server <ip> --share <path> \
  --host-path <host_mount> --ct-path <ct_mount> --ctid <id> [options]

Options:
  --uid <uid>            Container UID (default: 1000)
  --gid <gid>            Container GID (default: 1000)
  --perms <mode>         Host permissions (default: 770)
  --perm-mode <mode>     none|host|cifs (default: none)
  --username <user>      SMB username
  --password <pass>      SMB password
  --options <opts>       Mount options (protocol-specific)
  --health-check         Run health check and exit
  --auto-remount         Remount missing shares during health check
  --dry-run              Print actions without applying changes
  --readonly             Add read-only mount option
EOF
        exit 0
        ;;
      *) shift ;;
    esac
  done

  if [[ -z "$type" || -z "$server" || -z "$share" || -z "$host_path" || -z "$ct_path" || -z "$ctid" ]]; then
    msg_error "Missing required arguments. Use --help for usage."
    exit 1
  fi

  non_interactive_add "$type" "$server" "$share" "$host_path" "$ct_path" "$ctid" "$uid" "$gid" "$perms" "$perm_mode" "$user" "$pass" "$opts" "$readonly"
  exit 0
}

main_menu() {
  while true; do
    header_info
    local choice
    choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "LXC Network Share Manager" --menu \
      "Select an action:" 20 78 10 \
      "1" "Add network share (NFS/SMB)" \
      "2" "Remove/unmount share" \
      "3" "Health check" \
      "4" "Schedule health check" \
      "5" "Load profile and add share" \
      "6" "Backup /etc/fstab" \
      "7" "Restore /etc/fstab" \
      "8" "Exit" 3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
      1) add_share_interactive ;;
      2) remove_share_interactive ;;
      3) health_check ;;
      4) schedule_health_check ;;
      5) apply_profile ;;
      6) backup_fstab ;;
      7) restore_fstab ;;
      8) exit 0 ;;
    esac
  done
}

require_pve
require_tools
parse_args "$@" || true
header_info
main_menu
