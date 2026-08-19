# Dashboard

The backup container provides a lightweight dashboard for:

- listing recent backup files from rclone remotes
- validating a restore selection with a dry-run
- starting restore tasks and checking restore status

## Enable

Set these environment variables in the backup container:

- `BACKUP_DASHBOARD_ENABLE=TRUE`
- `BACKUP_DASHBOARD_ADMIN_TOKEN=<vaultwarden admin token or argon2 hash>`

Optional:

- `BACKUP_DASHBOARD_BIND_ADDR=0.0.0.0`
- `BACKUP_DASHBOARD_PORT=8080`

All of these variables support the `_FILE` secret pattern.

## Access

Open:

- `http://<host>:8080/` or `http://<host>:8080/cgi-bin/ui`

The web dashboard interface allows entering your plain-text admin token (which can be saved to browser storage) to authenticate API requests. If `BACKUP_DASHBOARD_ADMIN_TOKEN` is configured as a Vaultwarden Argon2 hash (`$argon2id$...`, `$argon2i$...`), the dashboard verifies the plain-text password against the hash using Argon2.

## API

All endpoints require one of:

- `X-Admin-Token: <token>`
- `Authorization: Bearer <token>`

### Recent backups

`GET /cgi-bin/api/backups/recent?limit=20`

Returns recent supported backup files discovered from configured `RCLONE_REMOTE_LIST` remotes.

### Restore dry-run

`POST /cgi-bin/api/restore/dry-run`

Form fields:

- `remote`
- `file`

Validates the selected backup file and returns `dry_run_id`.

### Restore execute

`POST /cgi-bin/api/restore/execute`

Form fields:

- `dry_run_id`
- `force=true`
- `password` (optional, only for encrypted zip/7z restore)

Starts a background restore and returns `restore_id`.

### Restore status

`GET /cgi-bin/api/restore/status?id=<restore_id>`

Returns queued/running/success/failed status for a restore task.
