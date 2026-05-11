# docker-backup

A small Docker image that any docker-compose service can drop in as a sidecar
to get versioned snapshots (restic) + current-state mirror (rsync) of its data,
configured entirely via environment variables.

## Quick start

See `examples/` for compose snippets covering common patterns:

- **restic-only** — versioned snapshots of a small data volume
- **with-mirror** — restic + rsync for services with bulky immutable data
- **with-pgdump** — built-in pg_dump via the `-pg` image tag (recommended for postgres)
- **pg-advanced** — docker.sock exec or external dump sidecar fallbacks

## Image tags

| Tag | Contents |
|-----|----------|
| `:1`, `:latest` | Core image (restic, rsync, hooks) |
| `:1-pg`, `:latest-pg` | Core + postgresql client (`pg_dump`) |

The image runs as a non-root user (uid 1000). See `compose-pg-advanced.yml`
for the `group_add` workaround when mounting `docker.sock`.

## Environment variables

### Scheduling

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_INTERVAL` | `86400` | Seconds between backup runs (24h). |
| `BACKUP_INITIAL_DELAY` | `120` | Seconds to wait before the first backup after container start. Gives services time to initialize. Set to `0` to run immediately. |
| `BACKUP_NAME` | `$HOSTNAME` | Identifier used in logs and webhook payloads. |

### Restic (versioned snapshots)

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_RESTIC_REPOSITORY` | *(required)* | Repository path inside the container (e.g. `/mnt/repo`). Auto-initialized on first run. |
| `BACKUP_RESTIC_PASSWORD` | *(required)* | Encryption password for the restic repository. |
| `BACKUP_RESTIC_SOURCES` | *(required)\** | Space-separated paths to snapshot. \*Can be omitted when a module (e.g. pg) supplies sources. |
| `BACKUP_RESTIC_EXCLUDES` | *(unset)* | Space-separated `--exclude` patterns for restic. |
| `BACKUP_RESTIC_FORGET` | `--keep-daily 7 --keep-weekly 4` | Retention policy flags. `--prune` is always appended. Set empty to skip the forget step entirely. |
| `BACKUP_RESTIC_CHECK_DOW` | `7` | Day of week (1=Mon, 7=Sun) to run `restic check`. `0` disables. |
| `BACKUP_VERBOSE` | *(unset)* | If set to `1`, passes `-v` to restic and rsync. |

### Rsync (current-state mirror)

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_RSYNC_SRC` | *(required)* | Source path inside the container. |
| `BACKUP_RSYNC_DST` | *(required)* | Destination path inside the container. |
| `BACKUP_RSYNC_ARGS` | `-a --delete` | Arguments passed to rsync. |

### Hooks

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_PRE` | *(unset)* | Inline shell script run before restic. Executed with `bash -euo pipefail`. |
| `BACKUP_PRE_SCRIPT` | *(unset)* | Path to a script file (fallback if `BACKUP_PRE` is unset). |
| `BACKUP_POST` | *(unset)* | Inline shell script run after rsync. |
| `BACKUP_POST_SCRIPT` | *(unset)* | Path to a script file (fallback if `BACKUP_POST` is unset). |

### Webhooks

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_WEBHOOK_URL` | *(unset)* | URL to POST JSON on failure and periodic heartbeat. Discord-compatible format. |
| `BACKUP_WEBHOOK_HEARTBEAT_EVERY` | `7` | Send a success heartbeat every Nth run. `0` disables heartbeats. |

### Healthcheck

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_HEALTHCHECK_MAX_AGE` | `93600` | Max seconds since last successful backup before the Docker HEALTHCHECK reports unhealthy (default ~26h). |

### PostgreSQL module (`:1-pg` image only)

Setting `BACKUP_PG_HOST` activates the built-in pg_dump module. Dumps are
written to a scratch directory, automatically added to the restic snapshot,
and cleaned up after each run.

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_PG_HOST` | *(required)* | Database host (e.g. `postgres`, an internal compose hostname). |
| `BACKUP_PG_USER` | *(required)* | Connection user. |
| `BACKUP_PG_DB` | *(required)* | Database to dump. |
| `BACKUP_PG_PORT` | `5432` | TCP port. |
| `BACKUP_PG_PASSWORD` | *(unset)* | Sets `PGPASSWORD` for pg_dump. |
| `BACKUP_PG_PASSWORD_FILE` | *(unset)* | Path to a file containing the password (preferred for Docker secrets). Takes precedence over `BACKUP_PG_PASSWORD`. |
| `BACKUP_PG_TABLES` | *(unset)* | Comma-separated table list. Omitted = full database. |
| `BACKUP_PG_EXTRA_ARGS` | *(unset)* | Extra flags appended to pg_dump. Do not override `-F` or `-Z` (hard-coded to `-F d -Z 0` for optimal restic dedup). |

## License

MIT
