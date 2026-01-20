# Template Exporter (Proxmox VE)

Template Exporter is a Proxmox host tool to export LXC containers and VM backups for sharing or migration, import them into the correct storage locations, and optionally create new CTs/VMs. It focuses on portable artifacts and does not convert guests into Proxmox templates.

Script: `tools/pve/template-exporter.sh`

## What It Does

### LXC Exports
- Creates a temporary clone (on selected storage) so the source container stays usable and unmodified.
- Optional in-container cleanup with a selectable checklist.
- Removes `net0` from the export target to avoid IP conflicts in new deployments.
- Exports a `.tar.gz` or `.tar.zst` with `vzdump` directly into CT template storage so it shows in the Proxmox GUI.
- Compression selection: gzip or zstd.
- Prompts for a Proxmox-friendly filename, then writes a `.manifest.json` and `.sha256`.
- Batch export support for multiple containers.

### VM Exports
- Creates a temporary clone (on selected storage) so the source VM stays usable and unmodified.
- Exports a compressed VM backup with `vzdump` to backup storage.
- Export mode selection: snapshot, suspend, or stop.
- Compression selection: gzip or zstd.
- Writes a `.manifest.json` and `.sha256` alongside the backup.
- Batch export support for multiple VMs.

### Imports and Creation
- Import LXC templates from local paths or direct URLs into `vztmpl` storage.
- Import VM backups from local paths or direct URLs into `backup` storage.
- Optional immediate creation of a new LXC or VM after import.
- LXC creation supports bridge selection, VLAN tag, DHCP or static IP.
- VM creation clones from existing VM templates.

### Catalog and Cleanup
- Lists and removes old LXC templates (also deletes related manifests and checksums).

## Requirements
- Run on a Proxmox VE host as root.
- Tools required: `whiptail`, `pvesm`, `pct`, `qm`, `vzdump`, `pvesh`, `curl`, `sha256sum`, `du`, `bc`, `awk`, `sed`, `grep`.
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

### 1) Export LXC as shareable archive
1. Select a container.
2. A temporary clone is created for export (storage is selectable).
3. Optional: sanitize the container filesystem (checklist).
4. `net0` is removed from the export target to avoid network conflicts.
5. Export with `vzdump` to the selected `vztmpl` storage.
6. Optional: rename using Proxmox filename format.
7. Generate `.manifest.json` and `.sha256`.

### 2) Export VM backup for sharing
1. Select a VM.
2. A temporary clone is created for export (storage is selectable).
3. Choose export mode (snapshot, suspend, stop).
4. Export with `vzdump` to the selected `backup` storage.
5. Generate `.manifest.json` and `.sha256`.

### 3) Batch export LXC containers
1. Select multiple containers.
2. Repeat the export flow per container.

### 4) Batch export VMs
1. Select multiple VMs.
2. Repeat the export flow per VM.

### 5) Import LXC template (.tar.*)
1. Choose storage for `vztmpl`.
2. Import from local path or URL (directory imports supported).
3. Optional: create a new LXC immediately.

### 6) Import VM backup (vma.*)
1. Choose backup storage.
2. Import from local path or URL (directory imports supported).
3. Optional: restore to a new VM immediately.

### 7) Create LXC from template
1. Select a template from storage.
2. Provide CT ID, hostname, root storage, disk size, and password.
3. Choose bridge, VLAN tag, and DHCP or static IP.

### 8) Create VM from template
1. Select a VM template.
2. Choose new VM ID, name, and target storage.
3. Clone to a full VM.

### 9) Template catalog / cleanup
1. Choose a storage.
2. Select templates to remove.

## Cleanup Details (LXC)
The sanitize option can perform:
- Delete SSH host keys (`/etc/ssh/ssh_host_*`)
- Truncate machine-id (`/etc/machine-id`)
- Remove persistent udev rules (`/etc/udev/rules.d/70*`)
- Truncate log files under `/var/log`
- Clear `/tmp` and `/var/tmp`
- Clear root bash history
- Optional hostname reset
- Optional zero free space for better compression

The login header file `/etc/profile.d/00_lxc-details.sh` is preserved and is not removed or sanitized.

## Manifests, Checksums, and Logs
- `*.manifest.json` stores metadata (guest ID, mode, OS details, storage, time).
- `source_id` is the original guest, `export_id` is the clone when used.
- `*.sha256` allows verification on import if present.
- Logs are written to `/var/log/pve-template-exporter.log`.
## Reports and Cleanup
- Each export shows a summary with path, size, checksum, and manifest.
- Temporary clones are removed after export, and also cleaned up on failure.

## Debug and Progress
- Toggle debug output from the main menu to show live command output in the terminal.
- Non-debug mode uses a progress gauge; debug mode runs commands in the foreground.

## Example Workflows

### Workflow A: Export and Share a Custom LXC
1. Build a container with your app stack.
2. Run Template Exporter and select "Export LXC as shareable .tar.gz".
3. Choose cleanup actions.
4. Export to `local` storage.
5. Rename to `debian-12-myapp_12-1_amd64.tar.gz`.
6. Share the `.tar.gz`, `.manifest.json`, and `.sha256`.

### Workflow B: Import a Template and Deploy an LXC
1. Run Template Exporter and select "Import LXC template (.tar.gz)".
2. Choose URL import and provide the direct file link.
3. Choose to create a new container when prompted.
4. Select bridge, VLAN tag, and DHCP or static IP.

### Workflow C: Export a VM for Migration
1. Run Template Exporter and select "Export VM backup for sharing".
2. Choose snapshot mode (preferred).
3. Export to `backup` storage.
4. On the target host, import and restore the backup.

## Files and Locations
- LXC templates: storage path `.../template/cache/*.tar.gz`
- VM backups: storage path `.../dump/*vma*`
- GUI visibility:
  - LXC templates show up under Storage -> CT Templates
  - VM backups show up under Storage -> Backups
