# LXC Network Share Manager (Proxmox VE)

LXC Network Share Manager adds NFS or SMB/CIFS network shares on the Proxmox host and maps them into LXC containers. It guides new users through share setup, permissions, and container mapping, while offering a non-interactive CLI for install scripts.

Script: `tools/pve/lxc-network-share-manager.sh`

## What It Does

### Core Features
- Adds NFS or SMB/CIFS shares on the host and maps them into LXC containers.
- Validates server IP and tests connectivity (ping + protocol check).
- Detects privileged vs unprivileged containers and applies correct UID/GID mapping.
- Lets you choose permission handling (no changes by default).
- Creates `/etc/fstab` entries with backups and a rollback option.
- Provides a health check for managed shares.
 - Optional scheduled health checks and auto-remount.
 - Profiles for reuse across containers.
 - Dry-run mode to preview changes.
 - Conflict detection for existing mounts and CT mappings.
 - Read-only mount toggle for safety.
 - Access report summary after mapping.

### Ease-of-Use Enhancements
- Lists container users to help pick correct UID/GID.
- Auto-creates host and container mount paths.
- Clear menus and safe defaults for new users.
- Logs all actions to `/var/log/lxc-network-share-manager.log`.

## Requirements
- Run on a Proxmox VE host as root.
- Tools required: `whiptail`, `pct`, `pvesh`, `pvesm`, `mount`, `umount`, `df`, `ping`.
- Installs missing packages when needed:
  - NFS: `nfs-common`
  - SMB/CIFS: `cifs-utils`, `smbclient`

## How Permissions Work

### Privileged Containers
Host and container UID/GID are the same. The script sets ownership directly.

### Unprivileged Containers
Container UID/GID are mapped to host UID/GID by adding 100000.  
Example: container UID 1000 -> host UID 101000.

The script calculates this automatically and applies `chown`/`chmod` on the host mount path.

## Interactive Workflow (Add Share)
1. Select share type (NFS or SMB/CIFS).
2. Enter server IP (validated) and share path/name.
3. Select container and target mount path in the container.
4. Choose a container user (or enter UID/GID).
5. Select a permissions preset and permission handling mode.
6. Optional: enable read-only mode and review the summary.
7. The share is mounted, added to `/etc/fstab`, and mapped into the container.

## CLI Usage (Install Scripts)
Use this mode to add a share from another script:

```bash
tools/pve/lxc-network-share-manager.sh \
  --type nfs \
  --server 10.0.0.10 \
  --share /exports/media \
  --host-path /mnt/shares/media \
  --ct-path /mnt/media \
  --ctid 101 \
  --uid 1000 \
  --gid 1000 \
  --perms 770
```

### CLI Options
- `--type` `nfs` or `cifs`
- `--server` IP address
- `--share` share path (NFS) or share name (SMB)
- `--host-path` mount path on host
- `--ct-path` mount path in container
- `--ctid` container ID
- `--uid` container UID (default: 1000)
- `--gid` container GID (default: 1000)
- `--perms` host permissions (default: 770)
- `--perm-mode` permission handling: `none`, `cifs`, `host`
- `--username` SMB username
- `--password` SMB password
- `--options` mount options
 - `--health-check` run health check and exit
 - `--auto-remount` remount missing shares during health check
 - `--dry-run` print actions without applying changes
 - `--readonly` add read-only mount option

## Safety and Recovery
- `/etc/fstab` is backed up before changes.
- Use "Restore /etc/fstab" from the menu to revert.
- Use "Remove/unmount share" to cleanly unmap.
 - Default permission handling avoids changing remote share permissions.

## Logs
`/var/log/lxc-network-share-manager.log`
