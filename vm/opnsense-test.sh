#!/usr/bin/env bash
set -euo pipefail

msg_info() {
  echo "[INFO] $*"
}

msg_ok() {
  echo "[OK] $*"
}

msg_error() {
  echo "[ERROR] $*" >&2
}

require_cmd() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    msg_error "Required command not found: $cmd"
    exit 1
  fi
}

APT_UPDATED=0

ensure_cmd_or_install() {
  local cmd=$1
  local pkg=$2
  if command -v "$cmd" >/dev/null 2>&1; then
    return
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    msg_error "Missing $cmd and apt-get is not available."
    exit 1
  fi
  if [[ $APT_UPDATED -eq 0 ]]; then
    msg_info "Updating package lists"
    apt-get update -qq
    APT_UPDATED=1
  fi
  msg_info "Installing $pkg"
  apt-get install -y -qq "$pkg"
  require_cmd "$cmd"
}

prompt_default() {
  local prompt=$1
  local default=$2
  local input
  read -r -p "$prompt [$default]: " input
  if [[ -z "$input" ]]; then
    echo "$default"
  else
    echo "$input"
  fi
}

if [[ $EUID -ne 0 ]]; then
  msg_error "Run as root on a Proxmox VE host."
  exit 1
fi

require_cmd qm
require_cmd pvesm

if ! command -v pvesh >/dev/null 2>&1; then
  msg_error "pvesh not found; this script expects Proxmox VE."
  exit 1
fi

DEFAULT_VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
DEFAULT_CORES="2"
DEFAULT_RAM="2048"
DEFAULT_DISK="20G"
DEFAULT_WAN_BRIDGE="vmbr5"
DEFAULT_LAN_BRIDGE="vmbr1"
DEFAULT_HOSTNAME="opnsense"
DEFAULT_DOMAIN="localdomain"
DEFAULT_TZ="Etc/UTC"
DEFAULT_LAN_IP="192.168.1.1"
DEFAULT_LAN_SUBNET="24"
DEFAULT_DHCP_START="192.168.1.100"
DEFAULT_DHCP_END="192.168.1.199"
DEFAULT_WAN_IF="vtnet5"
DEFAULT_LAN_IF="vtnet1"
DEFAULT_ROOT_HASH='$2y$10$YRVoF4SgskIsrXOvOQjGieB9XqHPRra9R7d80B3BZdbY/j21TwBfS'

DEFAULT_ISO_STORAGE=$(pvesm status -content iso | awk 'NR==2 {print $1}')
DEFAULT_DISK_STORAGE=$(pvesm status -content images | awk 'NR==2 {print $1}')

if [[ -z "$DEFAULT_ISO_STORAGE" || -z "$DEFAULT_DISK_STORAGE" ]]; then
  msg_error "No suitable storage found for ISO or VM disks."
  exit 1
fi

msg_info "OPNsense VM builder (Proxmox VE community-style script)."

VMID=$(prompt_default "VM ID" "$DEFAULT_VMID")
VM_NAME=$(prompt_default "VM name" "opnsense")
CORES=$(prompt_default "CPU cores" "$DEFAULT_CORES")
RAM=$(prompt_default "RAM (MiB)" "$DEFAULT_RAM")
DISK_SIZE=$(prompt_default "Disk size" "$DEFAULT_DISK")
ISO_STORAGE=$(prompt_default "ISO storage" "$DEFAULT_ISO_STORAGE")
DISK_STORAGE=$(prompt_default "Disk storage" "$DEFAULT_DISK_STORAGE")
WAN_BRIDGE=$(prompt_default "WAN bridge" "$DEFAULT_WAN_BRIDGE")
LAN_BRIDGE=$(prompt_default "LAN bridge" "$DEFAULT_LAN_BRIDGE")

HOSTNAME=$(prompt_default "OPNsense hostname" "$DEFAULT_HOSTNAME")
DOMAIN=$(prompt_default "OPNsense domain" "$DEFAULT_DOMAIN")
TIMEZONE=$(prompt_default "Timezone" "$DEFAULT_TZ")
LAN_IP=$(prompt_default "LAN IP" "$DEFAULT_LAN_IP")
LAN_SUBNET=$(prompt_default "LAN subnet (CIDR)" "$DEFAULT_LAN_SUBNET")
DHCP_START=$(prompt_default "LAN DHCP start" "$DEFAULT_DHCP_START")
DHCP_END=$(prompt_default "LAN DHCP end" "$DEFAULT_DHCP_END")
WAN_IF=$(prompt_default "WAN interface name" "$DEFAULT_WAN_IF")
LAN_IF=$(prompt_default "LAN interface name" "$DEFAULT_LAN_IF")

if ! pvesm status -content iso | awk 'NR>1 {print $1}' | grep -qx "$ISO_STORAGE"; then
  msg_error "ISO storage '$ISO_STORAGE' is not available for ISO content."
  exit 1
fi

if ! pvesm status -content images | awk 'NR>1 {print $1}' | grep -qx "$DISK_STORAGE"; then
  msg_error "Disk storage '$DISK_STORAGE' is not available for VM images."
  exit 1
fi

if qm status "$VMID" >/dev/null 2>&1; then
  msg_error "VMID $VMID already exists."
  exit 1
fi

msg_info "Provide an ISO filename already present on $ISO_STORAGE, or press Enter to download."
read -r -p "OPNsense ISO filename (e.g. OPNsense-24.7-OpenSSL-dvd-amd64.iso): " ISO_FILENAME
ISO_URL=""
if [[ -z "$ISO_FILENAME" ]]; then
  read -r -p "OPNsense ISO URL (.iso or .bz2): " ISO_URL
  if [[ -z "$ISO_URL" ]]; then
    msg_error "ISO filename or URL is required."
    exit 1
  fi
  ISO_FILENAME=$(basename "$ISO_URL")
  if [[ "$ISO_FILENAME" == *.bz2 ]]; then
    ISO_FILENAME="${ISO_FILENAME%.bz2}"
  fi
fi

ISO_PATH=$(pvesm path "$ISO_STORAGE:iso/$ISO_FILENAME" 2>/dev/null || true)
if [[ -z "$ISO_PATH" ]]; then
  msg_error "Unable to resolve ISO path for storage $ISO_STORAGE."
  exit 1
fi

if [[ ! -f "$ISO_PATH" ]]; then
  if [[ -z "$ISO_URL" ]]; then
    msg_error "ISO not found at $ISO_PATH. Provide a URL to download."
    exit 1
  fi
  msg_info "Downloading ISO to $ISO_PATH"
  ensure_cmd_or_install wget wget
  TMP_PATH="$ISO_PATH"
  if [[ "$ISO_URL" == *.bz2 ]]; then
    TMP_PATH="${ISO_PATH}.bz2"
  fi
  wget -qO "$TMP_PATH" "$ISO_URL"
  if [[ "$TMP_PATH" == *.bz2 ]]; then
    ensure_cmd_or_install bunzip2 bzip2
    bunzip2 -f "$TMP_PATH"
  fi
  msg_ok "ISO download complete"
fi

msg_info "Creating VM $VMID ($VM_NAME)"
qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --cpu host \
  --net0 "virtio,bridge=$WAN_BRIDGE,firewall=1" \
  --net1 "virtio,bridge=$LAN_BRIDGE,firewall=1" \
  --scsihw virtio-scsi-pci \
  --ide2 "$ISO_STORAGE:iso/$ISO_FILENAME,media=cdrom" \
  --boot "order=ide2;scsi0" \
  --serial0 socket \
  --vga serial0

msg_info "Allocating system disk on $DISK_STORAGE ($DISK_SIZE)"
ROOT_VOL=$(pvesm alloc "$DISK_STORAGE" "$VMID" "vm-$VMID-disk-0" "$DISK_SIZE" 2>/dev/null || true)
if [[ -z "$ROOT_VOL" ]]; then
  msg_error "Failed to allocate system disk on $DISK_STORAGE."
  exit 1
fi
qm set "$VMID" --scsi0 "$ROOT_VOL" >/dev/null

CONFIG_DIR="/var/lib/vz/images/$VMID"
CONFIG_XML="$CONFIG_DIR/opnsense-config.xml"
CONFIG_IMG="$CONFIG_DIR/opnsense-config.img"

mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_XML" <<EOF
<?xml version="1.0"?>
<opnsense>
  <trigger_initial_wizard/>
  <theme>opnsense</theme>
  <sysctl/>
  <system>
    <optimization>normal</optimization>
    <hostname>$HOSTNAME</hostname>
    <domain>$DOMAIN</domain>
    <dnsallowoverride>1</dnsallowoverride>
    <dnsallowoverride_exclude/>
    <group>
      <name>admins</name>
      <description>System Administrators</description>
      <scope>system</scope>
      <gid>1999</gid>
      <member>0</member>
      <priv>page-all</priv>
    </group>
    <user>
      <name>root</name>
      <descr>System Administrator</descr>
      <scope>system</scope>
      <groupname>admins</groupname>
      <password>$DEFAULT_ROOT_HASH</password>
      <uid>0</uid>
    </user>
    <timezone>$TIMEZONE</timezone>
    <timeservers>0.opnsense.pool.ntp.org 1.opnsense.pool.ntp.org 2.opnsense.pool.ntp.org 3.opnsense.pool.ntp.org</timeservers>
    <webgui>
      <protocol>https</protocol>
    </webgui>
    <disablenatreflection>yes</disablenatreflection>
    <usevirtualterminal>1</usevirtualterminal>
    <disableconsolemenu/>
    <ipv6allow>1</ipv6allow>
    <powerd_ac_mode>hadp</powerd_ac_mode>
    <powerd_battery_mode>hadp</powerd_battery_mode>
    <powerd_normal_mode>hadp</powerd_normal_mode>
    <bogons>
      <interval>monthly</interval>
    </bogons>
    <pf_share_forward>1</pf_share_forward>
    <lb_use_sticky>1</lb_use_sticky>
    <ssh>
      <group>admins</group>
    </ssh>
    <rrdbackup>-1</rrdbackup>
    <netflowbackup>-1</netflowbackup>
  </system>
  <interfaces>
    <wan>
      <enable>1</enable>
      <if>$WAN_IF</if>
      <mtu/>
      <ipaddr>dhcp</ipaddr>
      <ipaddrv6>dhcp6</ipaddrv6>
      <subnet/>
      <gateway/>
      <blockpriv>1</blockpriv>
      <blockbogons>1</blockbogons>
      <dhcphostname/>
      <media/>
      <mediaopt/>
      <dhcp6-ia-pd-len>0</dhcp6-ia-pd-len>
    </wan>
    <lan>
      <enable>1</enable>
      <if>$LAN_IF</if>
      <ipaddr>$LAN_IP</ipaddr>
      <subnet>$LAN_SUBNET</subnet>
      <ipaddrv6>idassoc6</ipaddrv6>
      <subnetv6>64</subnetv6>
      <media/>
      <mediaopt/>
      <track6-interface>wan</track6-interface>
      <track6-prefix-id>0</track6-prefix-id>
    </lan>
  </interfaces>
  <dnsmasq>
    <enable>1</enable>
    <port>53053</port>
    <interface>lan</interface>
    <dhcp>
      <enable_ra>1</enable_ra>
    </dhcp>
    <dhcp_ranges>
      <interface>lan</interface>
      <start_addr>$DHCP_START</start_addr>
      <end_addr>$DHCP_END</end_addr>
    </dhcp_ranges>
    <dhcp_ranges>
      <interface>lan</interface>
      <start_addr>::1000</start_addr>
      <end_addr>::2000</end_addr>
      <constructor>lan</constructor>
      <ra_mode>slaac</ra_mode>
    </dhcp_ranges>
  </dnsmasq>
  <unbound>
    <enable>1</enable>
  </unbound>
  <nat>
    <outbound>
      <mode>automatic</mode>
    </outbound>
  </nat>
  <filter>
    <rule>
      <type>pass</type>
      <ipprotocol>inet</ipprotocol>
      <descr>Default allow LAN to any rule</descr>
      <interface>lan</interface>
      <source>
        <network>lan</network>
      </source>
      <destination>
        <any/>
      </destination>
    </rule>
    <rule>
      <type>pass</type>
      <ipprotocol>inet6</ipprotocol>
      <descr>Default allow LAN IPv6 to any rule</descr>
      <interface>lan</interface>
      <source>
        <network>lan</network>
      </source>
      <destination>
        <any/>
      </destination>
    </rule>
  </filter>
  <rrd>
    <enable/>
  </rrd>
  <ntpd>
    <prefer>0.opnsense.pool.ntp.org</prefer>
  </ntpd>
</opnsense>
EOF

msg_info "Preparing config disk image"
require_cmd dd
ensure_cmd_or_install mkfs.vfat dosfstools
ensure_cmd_or_install mmd mtools
ensure_cmd_or_install mcopy mtools

dd if=/dev/zero of="$CONFIG_IMG" bs=1M count=16 status=none
mkfs.vfat -n CONFIG "$CONFIG_IMG" >/dev/null
mmd -i "$CONFIG_IMG" ::/conf
mcopy -i "$CONFIG_IMG" "$CONFIG_XML" ::/conf/config.xml

qm importdisk "$VMID" "$CONFIG_IMG" "$DISK_STORAGE" >/dev/null
CONFIG_VOL=$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+: / {print $2; exit}')
if [[ -z "$CONFIG_VOL" ]]; then
  msg_error "Unable to locate imported config disk volume."
  exit 1
fi

qm set "$VMID" --scsi1 "$CONFIG_VOL" >/dev/null
rm -f "$CONFIG_IMG"

msg_ok "VM created with config disk attached."
msg_info "Next steps:"
msg_info "1) Start the VM: qm start $VMID"
msg_info "2) At boot, press any key to start the configuration importer."
msg_info "3) Select the config disk device (likely the second disk; use '?' to list)."
msg_info "4) Run the installer and reboot. Default root password is 'opnsense' (change after login)."
