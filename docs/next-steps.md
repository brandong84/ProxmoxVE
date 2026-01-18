# RomM LXC Next Steps

Use this checklist after the scripts finish.

## 1) Get Your Credentials
The installer generates database and RomM secrets:
- File: `/root/romm.creds`
- Contains: `DB_NAME`, `DB_USER`, `DB_PASSWD`, `ROMM_AUTH_SECRET_KEY`

Store these somewhere safe before editing.

## 2) Update Environment Variables
Edit `/etc/romm/romm.env` to fit your setup:
- Add metadata provider keys (IGDB, Screenscraper, SteamGridDB, etc.).
- Update `ROMM_BASE_URL` if you plan to reverse-proxy or use a hostname.
- Toggle optional tasks (scheduled rescans, metadata updates, watchers).

Restart RomM after changes:
```
rc-service romm restart
```

## 3) Mount Your ROM Library
RomM expects data under `/romm`:
- `/romm/library` (ROMs)
- `/romm/resources` (fetched metadata, media)
- `/romm/assets` (uploaded saves, states, etc.)

Recommended: mount a host path or dedicated storage into the container at `/romm/library` and `/romm/assets` to avoid data loss on rebuild.

## 4) Verify Services
Check service status:
```
rc-service romm status
rc-service mariadb status
rc-service nginx status
```

Inspect logs:
- Nginx: `/var/log/nginx/romm-access.log`, `/var/log/nginx/romm-error.log`
- RomM: `rc-service romm status` and `logread` on Alpine

## 5) Open the UI
Browse to:
```
http://<CT-IP>:8080
```

## 6) Configure RomM in the UI
After login:
- Point RomM to your library path under `/romm/library`
- Enable providers you configured
- Trigger a scan

## 7) Optional: External Redis/Valkey
If you want an external Redis/Valkey:
- Set `REDIS_HOST` and related variables in `/etc/romm/romm.env`
- Restart RomM

The internal Valkey instance is only used when `REDIS_HOST` is empty.

## 8) Optional: Reverse Proxy / TLS
If you place RomM behind a proxy:
- Set `ROMM_BASE_URL` to the public URL
- Ensure websockets (`/ws`, `/netplay`) are proxied

## 9) Updates
To update RomM:
- Run `/usr/bin/update` inside the container, or
- Re-run the CT update script from the host

## 10) Backups
Minimum backup targets:
- `/romm` (library, assets, resources)
- `/etc/romm/romm.env`
- MariaDB data in `/var/lib/mysql` (or dump the `romm` database)

