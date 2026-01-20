# LXC Network Shares Enhanced Script

## Description
This script automates the process of mounting network shares (NFS, SMB/CIFS, etc...) on a Proxmox host and mapping them into LXC containers. It provides advanced features for backup/restore, scheduling, health checks, notifications, template profiles, security, and rollback/undo. The script is interactive and modular, designed for extensibility and ease of use.

## Features
- Add NFS, SMB/CIFS shares (WebDAV/SFTP placeholders for future support)
- Interactive container selection
- Advanced mount options and guest SMB support
- Logging of all actions/errors to `/var/log/lxc-network-shares-enhanced.log`
- Multiple shares can be added/removed in one run
- Backup and restore `/etc/fstab`
- Schedule mounts via cron
- Health checks for mounted shares
- Save/load template profiles for quick reuse
- Mask sensitive info in logs
- Undo last change (restore previous fstab)
- Placeholder for GUI mode
- Notification integration placeholder

## Usage Summary
1. Run the script on your Proxmox host.
2. Select an action from the menu:
   - Add NFS Share
   - Add SMB/CIFS Share (with guest or user credentials)
   - Add WebDAV/SFTP Share (future)
   - Remove/Unmount Share
   - Backup/Restore fstab
   - Schedule Mount
   - Health Check
   - Save/Load Profile
   - Undo Last Change
   - GUI Mode (placeholder)
   - Exit
3. Follow prompts for IP, share details, mount options, and container mapping.
4. Enter custom mount parameters if needed.
5. Repeat actions to add/remove as many shares as needed.
6. All actions/errors are logged to `/var/log/lxc-network-shares-enhanced.log`.
7. Use backup/restore and undo features for safety.
8. Use template profiles for quick setup.
9. Health checks and notifications help monitor share status.

## Customization Ideas
- Support for more protocols (WebDAV, SFTP, cloud storage)
- Automated backup/restore of shares
- Scheduled mounting/unmounting
- Periodic health checks and notifications
- Interactive GUI
- Container selection from list
- Template profiles for quick reuse
- Security enhancements (masking, encrypted credentials)
- Rollback/undo last change

## Requirements
- Proxmox VE host
- Bash shell
- Required utilities: `pct`, `showmount`, `mount`, `umount`, `crontab`, etc.

## License
MIT | Copyright (c) 2021-2025 brandong84

---
## Usage Examples & Step-by-Step Guide

### Example 1: Add NFS Share (Automated User & Permission Setup)
1. Select 'Add Network Share (NFS/SMB)'.
2. Enter 'nfs' for share type.
3. Enter NFS server IP and share directory.
4. Select container (script detects privilege type).
5. Script lists available Linux users and suggests best user/group for the share.
6. Script recommends permissions (770 for private, 755 for public, 700 for secure).
7. Accept defaults or customize UID/GID and permissions.
8. Share is mounted and mapped to the container with correct ownership and permissions.

### Example 2: Add SMB Share (Automated User & Permission Setup)
1. Select 'Add Network Share (NFS/SMB)'.
2. Enter 'smb' for share type.
3. Enter SMB server IP, share name, and credentials.
4. Select container (script detects privilege type).
5. Script lists available Linux users and suggests best user/group for the share.
6. Script recommends permissions (770 for private, 755 for public, 700 for secure).
7. Accept defaults or customize UID/GID and permissions.
8. Share is mounted and mapped to the container with correct ownership and permissions.

### Example 3: Remove/Unmount Share
1. Select 'Remove/Unmount Share'.
2. Select container and enter host directory to remove.
3. Script backs up fstab, unmounts, and removes the entry.

### Example 4: Backup and Restore fstab
1. Select 'Backup fstab' before making changes.
2. If needed, select 'Restore fstab' to revert.

### Example 5: Advanced Mount Options
1. When prompted, enter custom mount options (e.g., `nfs defaults,noexec,uid=1000,gid=1000 0 0`).
2. These options will be used in the fstab entry and mount command.

# LXC Network Shares Manager

## Description
This script automates mounting NFS and SMB/CIFS network shares on a Proxmox host and mapping them into LXC containers. It is designed for maximum usability—even for users unfamiliar with Linux permissions. The script guides you through user and permission setup, lists available users, suggests best practices, and automates ownership and permission settings for both privileged and unprivileged containers.

## Features
- Add NFS or SMB/CIFS shares to LXC containers
- Interactive container selection
- Automated privilege detection (privileged/unprivileged)
- Lists available Linux users and suggests best user/group for the share
- Detects and recommends proper permissions (770/755/700)
- Automates chown/chmod for host directory
- UID/GID mapping for unprivileged containers
- Custom mount options prompt
- Validates share accessibility before mounting
- Backs up and restores `/etc/fstab` for safety
- Secure logging with masked credentials
- Remove/unmount shares

## How User & Permission Management Works

### Privileged Containers
- Can access files as root or any user inside the container.
- UID/GID mapping is optional. Use a user/group that matches your container’s main user for best compatibility.
- Permissions: 770 (private), 755 (public), 700 (secure). Script suggests and automates these settings.

### Unprivileged Containers
- Require UID/GID mapping for the mount to be accessible inside the container.
- Script recommends using the main user of your container (often UID 1000, GID 1000).
- Permissions: 770 (private), 755 (public), 700 (secure). Script suggests and automates these settings.
- If permissions are incorrect, the container may not be able to read/write the share.

### How the Script Helps
- Lists available Linux users and their UID/GID.
- Suggests best user/group for the share based on container type.
- Recommends permissions and explains their meaning.
- Automates chown/chmod for host directory.
- Explains every choice and provides safe defaults.

## Step-by-Step Guide
1. Run the script on your Proxmox host.
2. Select an action:
  - Add Network Share (NFS/SMB)
  - Remove/Unmount Share
  - Backup/Restore fstab
  - Exit
3. For adding a share:
  - Enter share type, server info, and credentials.
  - Select container (script detects privilege type).
  - Script lists users, suggests best user/group, and recommends permissions.
  - Accept defaults or customize UID/GID and permissions.
  - Script automates chown/chmod and UID/GID mapping as needed.
  - Share is validated, mounted, and mapped to the container.

## Best Practices & Troubleshooting
- For unprivileged containers, always use UID/GID mapping that matches the main user inside the container.
- Use 770 for private shares, 755 for public, 700 for secure.
- If the container cannot access the share, check UID/GID and permissions on the host directory.
- Use the script’s suggestions for best compatibility and security.
- For SMB shares, credentials are masked in logs for security.

## Advanced Options
- Specify custom mount options for advanced use cases.
- Supports multiple shares and automated fstab backup/restore.

## Need Help?
The script explains every step and provides safe defaults. If unsure, accept the recommended settings for best results.
- **Dry-run Mode:**
  - Preview changes before applying.
- **Logging Enhancements:**
  - Log all actions, errors, and permission changes for audit.

## License
MIT | Copyright (c) 2021-2025 brandong84

---
For issues or feature requests, open an issue on the GitHub repository.

