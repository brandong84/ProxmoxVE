# RomM LXC (Alpine) - Bare-Metal Install Guide

This guide explains what the RomM LXC scripts do, what they need, and how the install is laid out. It is based on RomM's upstream production Docker image and adapts it to a bare-metal Alpine LXC container.

## What You Get
- Alpine-based LXC container (Alpine 3.22 by default).
- RomM backend (FastAPI + Gunicorn) and frontend (Vite build).
- MariaDB for the primary database.
- Valkey (or Redis fallback) for background jobs and cache.
- Nginx for static assets and API proxying.
- RAHasher built from source (optional functionality for RetroAchievements hashes).
- OpenRC service that supervises all RomM processes.

## Scripts Overview
- `ct/romm.sh`: Builds the LXC container and runs the install script.
- `install/romm-install.sh`: Runs inside the container to install and configure everything.
- `ct/headers/romm`: ASCII header shown during container setup.

## Requirements on the Proxmox Host
- Proxmox VE with LXC support enabled.
- Storage for container rootfs and templates.
- Internet access for template and package downloads.
- A working DNS resolver on the Proxmox host.

## Container Defaults
These values can be overridden when running the CT script:
- OS: Alpine 3.22
- vCPU: 2
- RAM: 2048 MB
- Disk: 8 GB
- Unprivileged container: yes

## RomM Runtime Stack
The install script mirrors the upstream container's production build:
- Python 3.13 (via `uv`)
- Node.js (Alpine package, used only for frontend build)
- MariaDB server
- Valkey server (with Redis fallback if Valkey is not available)
- Nginx with the `ngx_http_zip_module` built from source
- RAHasher built from the RetroAchievements RALibretro repository

## Directory Layout
- `/opt/romm`: RomM source code and virtual environment
- `/opt/romm/.version`: Installed RomM release version
- `/etc/romm/romm.env`: Primary environment configuration
- `/root/romm.creds`: Generated database and secret credentials
- `/romm`: Data root for RomM
  - `/romm/library`: ROM library
  - `/romm/resources`: Metadata and media cache
  - `/romm/assets`: Uploads and user assets
  - `/romm/config`: Optional config.yml location
  - `/romm/tmp`: Temporary working directory
- `/var/www/html`: Built frontend assets
- `/redis-data`: Valkey/Redis data directory

## Ports and Services
- Nginx listens on port `8080`.
- Gunicorn binds to a UNIX socket (`/tmp/gunicorn.sock`) and TCP port `5000`.
- Valkey listens on port `6379` (internal only by default).
- OpenRC service name: `romm`.

## Environment Configuration
The primary environment file is `/etc/romm/romm.env`. The installer creates sensible defaults. You should update it for your deployment:
- Database settings: `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWD`
- Redis/Valkey settings: `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`
- RomM authentication: `ROMM_AUTH_SECRET_KEY`
- Optional metadata provider keys: IGDB, Screenscraper, SteamGridDB, etc.
- Scheduled tasks and filesystem watcher toggles

RomM requires `ROMM_AUTH_SECRET_KEY` to be set. The installer generates one and stores it in `/root/romm.creds`.

## Nginx Configuration
Nginx is configured with:
- Static assets served from `/var/www/html`
- API and websocket routes proxied to Gunicorn
- Internal `/library/` alias for ROM downloads
- `decode.js` for internal base64 decoding

Config files installed by the script:
- `/etc/nginx/nginx.conf`
- `/etc/nginx/conf.d/romm.conf`
- `/etc/nginx/js/decode.js`

## Services Started by the Init Script
`/usr/local/bin/romm-init` supervises:
- Valkey (if `REDIS_HOST` is not set)
- Gunicorn (RomM backend)
- RQ worker
- Optional RQ scheduler (if scheduled tasks are enabled)
- Optional filesystem watcher (if enabled)
- Nginx

It also runs database migrations and startup tasks before the main loop.

## Update Flow
The CT update routine in `ct/romm.sh`:
- Detects the latest GitHub release
- Stops the RomM service
- Re-downloads the RomM source
- Rebuilds Python and frontend dependencies
- Restores the environment file
- Restarts the service

## Notes and Limits
- This is a bare-metal LXC install, not Docker.
- The installer compiles `mod_zip` for Nginx; this takes extra time.
- If Valkey is not available in the Alpine repo, Redis is installed and aliased.

