# Template Manager (Proxmox VE)

The Template Manager is a Proxmox host-side tool that exports LXC containers or VMs into reusable templates and supports importing and cloning them. It also makes sure the resulting LXC `.tar.gz` ends up in the correct storage path so the Proxmox Web UI can see it under **CT Templates**.

Script: `tools/pve/template-manager.sh`

## What It Does

### LXC Templates
- Optional in-container cleanup to remove host-specific data (SSH keys, machine-id, logs, tmp).
- Removes `net0` from the container config to avoid network conflicts in new deployments.
- Exports a `.tar.gz` using `vzdump` into CT template storage.
- Optionally renames the tarball using the Proxmox filename schema.
- Imports a `.tar.gz` from local path or URL into CT template storage.
- Creates a new LXC directly from an imported template.

### VM Templates
- Exports a compressed VM backup using `vzdump` (stored in backup storage).
- Optionally converts VM to a template (`qm template`).
- Imports a VM backup file (`vma.*`) from local path or URL.
- Restores the backup to a new VM and optionally converts it to a template.
- Clones a VM template into a new VM.

## Requirements
- Run on a Proxmox VE host as root.
- Tools required: `whiptail`, `pvesm`, `pct`, `qm`, `vzdump`, `pvesh`, `curl`.
- Storage must be configured for:
  - LXC templates (`vztmpl`)
  - Backups (`backup`)
  - VM images (`images`)

## Filename Schema for LXC Templates
Proxmox uses the filename for OS detection:

`<OS>-<OS_VERSION>-<NAME>_<VERSION>-<REVISION>_<ARCH>.tar.gz`

Example:

`debian-12-webserver_12-1_amd64.tar.gz`

If the name does not follow this schema, the template may still import, but Proxmox can mis-detect OS defaults.

## Menu Actions

### 1) Create LXC template + export
1. Select a container.
2. Optional: sanitize the container filesystem.
3. `net0` is removed from the config to avoid IP conflicts.
4. Optional: mark the container as a template.
5. Export with `vzdump` to the selected `vztmpl` storage.
6. Optional: rename using Proxmox template filename format.

### 2) Create VM template + export
1. Select a VM.
2. Optional: stop the VM.
3. Optional: mark VM as template.
4. Export with `vzdump` to the selected `backup` storage.

### 3) Import LXC template
1. Choose storage for `vztmpl`.
2. Import from local path or URL.
3. Optional: immediately create a new LXC.

### 4) Import VM backup
1. Choose backup storage.
2. Import from local path or URL.
3. Optional: restore to a new VM.
4. Optional: convert restored VM to template.

### 5) Create LXC from template
1. Select storage and template tarball.
2. Provide container ID, hostname, storage, disk size, and password.
3. Creates CT with DHCP on `vmbr0`.

### 6) Create VM from template
1. Select a VM template.
2. Choose new VM ID, name, and storage.
3. Clones the template to a full VM.

## Cleanup Details (LXC)
The sanitize option performs:
- Delete SSH host keys (`/etc/ssh/ssh_host_*`)
- Truncate machine-id (`/etc/machine-id`)
- Remove persistent udev rules (`/etc/udev/rules.d/70*`)
- Truncate log files under `/var/log`
- Clear `/tmp` and `/var/tmp`
- Clear root bash history

This is optional but recommended for shareable templates.

## Example Workflows

### Workflow A: Export and Share a Custom LXC Template
1. Build a container with your app stack.
2. Run Template Manager → `Create LXC template + export`.
3. Select sanitize.
4. Export to `local` storage.
5. Rename to `debian-12-myapp_12-1_amd64.tar.gz`.
6. Share the `.tar.gz` with others.

### Workflow B: Import a Template and Deploy an LXC
1. Run Template Manager → `Import LXC template`.
2. Choose URL import and provide direct file link.
3. Select “Create new container” when prompted.
4. Provide CT ID, hostname, disk, and password.

### Workflow C: Turn a VM into a Template
1. Run Template Manager → `Create VM template + export`.
2. Choose stop VM, then convert to template.
3. Export to `backup` storage.
4. Clone the template with `Create VM from template`.

## Tips
- Prefer `local` or a dedicated template storage for CT exports.
- Use a meaningful template name and revision number.
- Always sanitize before sharing publicly.
- Keep a copy of the original container/VM until you validate the template works.

## Files and Locations
- LXC templates: storage path `.../template/cache/*.tar.gz`
- VM backups: storage path `.../dump/*vma*`
- GUI visibility:
  - LXC templates show up under **Storage → CT Templates**
  - VM backups show up under **Storage → Backups**

