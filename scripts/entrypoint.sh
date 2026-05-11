#!/usr/bin/env bash
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────
: "${BACKUP_NAME:=${HOSTNAME}}"
: "${BACKUP_CRON:=30 1 * * *}"
: "${BACKUP_HEALTHCHECK_MAX_AGE:=93600}"

# ── validate: at least one prong must be configured ─────────────────
restic_enabled=false
rsync_enabled=false
pg_enabled=false

if [[ -n "${BACKUP_RESTIC_REPOSITORY:-}" ]]; then
  restic_enabled=true
  for var in BACKUP_RESTIC_PASSWORD BACKUP_RESTIC_SOURCES; do
    if [[ -z "${!var:-}" ]]; then
      # BACKUP_RESTIC_SOURCES can be empty when pg prong supplies it
      if [[ "$var" == "BACKUP_RESTIC_SOURCES" && -n "${BACKUP_PG_HOST:-}" ]]; then
        continue
      fi
      echo "ERROR: $var is required when BACKUP_RESTIC_REPOSITORY is set" >&2
      exit 1
    fi
  done
fi

if [[ -n "${BACKUP_RSYNC_SRC:-}" || -n "${BACKUP_RSYNC_DST:-}" ]]; then
  rsync_enabled=true
  for var in BACKUP_RSYNC_SRC BACKUP_RSYNC_DST; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: $var is required when rsync prong is enabled" >&2
      exit 1
    fi
  done
fi

if [[ -n "${BACKUP_PG_HOST:-}" ]]; then
  pg_enabled=true
  if ! command -v pg_dump >/dev/null 2>&1; then
    echo "ERROR: BACKUP_PG_HOST is set but pg_dump is not installed. Use the -pg image tag." >&2
    exit 1
  fi
  for var in BACKUP_PG_USER BACKUP_PG_DB; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: $var is required when BACKUP_PG_HOST is set" >&2
      exit 1
    fi
  done
  # pg prong requires restic to snapshot the dump
  if [[ "$restic_enabled" == "false" ]]; then
    echo "ERROR: BACKUP_RESTIC_REPOSITORY and BACKUP_RESTIC_PASSWORD are required when BACKUP_PG_HOST is set" >&2
    exit 1
  fi
fi

if [[ "$restic_enabled" == "false" && "$rsync_enabled" == "false" ]]; then
  echo "ERROR: at least one prong must be configured (restic or rsync)" >&2
  exit 1
fi

echo "[$BACKUP_NAME] prongs: restic=$restic_enabled rsync=$rsync_enabled pg=$pg_enabled"

# ── write crontab ───────────────────────────────────────────────────
crontab_line="$BACKUP_CRON /usr/local/bin/backup.sh >> /proc/1/fd/1 2>> /proc/1/fd/2"
echo "$crontab_line" | crontab -

echo "[$BACKUP_NAME] cron: $BACKUP_CRON"

# ── restic repo bootstrap ──────────────────────────────────────────
if [[ "$restic_enabled" == "true" ]]; then
  export RESTIC_REPOSITORY="$BACKUP_RESTIC_REPOSITORY"
  export RESTIC_PASSWORD="$BACKUP_RESTIC_PASSWORD"

  # Auto-init if repo is empty / doesn't exist yet
  if ! restic cat config >/dev/null 2>&1; then
    echo "[$BACKUP_NAME] initializing restic repository at $RESTIC_REPOSITORY"
    restic init
  fi

  # Remove stale locks (safe: single-writer by design)
  restic unlock --remove-all 2>/dev/null || true

  echo "[$BACKUP_NAME] restic repository ready"
fi

# ── hand off to cron ────────────────────────────────────────────────
echo "[$BACKUP_NAME] entrypoint complete, starting crond"
exec crond -f -l 2
