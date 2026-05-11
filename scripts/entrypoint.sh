#!/usr/bin/env bash
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────
: "${BACKUP_NAME:=${HOSTNAME}}"
: "${BACKUP_CRON:=30 1 * * *}"
: "${BACKUP_HEALTHCHECK_MAX_AGE:=93600}"

MODULE_DIR="/usr/local/lib/docker-backup/modules.d"

log() { echo "[$BACKUP_NAME] $*"; }

# ── validate core prongs ────────────────────────────────────────────
restic_enabled=false
rsync_enabled=false

if [[ -n "${BACKUP_RESTIC_REPOSITORY:-}" ]]; then
  restic_enabled=true
  if [[ -z "${BACKUP_RESTIC_PASSWORD:-}" ]]; then
    echo "ERROR: BACKUP_RESTIC_PASSWORD is required when BACKUP_RESTIC_REPOSITORY is set" >&2
    exit 1
  fi
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

# ── load and validate modules ──────────────────────────────────────
loaded_modules=()
for mod_file in "$MODULE_DIR"/*.sh; do
  [[ -f "$mod_file" ]] || continue
  mod_name=$(basename "$mod_file" .sh)
  source "$mod_file"
  "mod_${mod_name}_validate"
  loaded_modules+=("$mod_name")
done

# BACKUP_RESTIC_SOURCES can be empty when modules supply sources
if [[ "$restic_enabled" == "true" && -z "${BACKUP_RESTIC_SOURCES:-}" && ${#loaded_modules[@]} -eq 0 ]]; then
  echo "ERROR: BACKUP_RESTIC_SOURCES is required when no modules are loaded" >&2
  exit 1
fi

# at least one prong or module must be configured
if [[ "$restic_enabled" == "false" && "$rsync_enabled" == "false" ]]; then
  echo "ERROR: at least one prong must be configured (restic or rsync)" >&2
  exit 1
fi

log "prongs: restic=$restic_enabled rsync=$rsync_enabled modules=[${loaded_modules[*]:-}]"

# ── write crontab ───────────────────────────────────────────────────
# busybox crond reads /etc/crontabs/<user>; backup.sh runs as the
# backup user via su-exec so all file access is non-root.
CRONTAB_FILE="/etc/crontabs/backup"
echo "$BACKUP_CRON su-exec backup /usr/local/bin/backup.sh" > "$CRONTAB_FILE"

log "cron: $BACKUP_CRON"

# ── restic repo bootstrap (as backup user) ─────────────────────────
if [[ "$restic_enabled" == "true" ]]; then
  export RESTIC_REPOSITORY="$BACKUP_RESTIC_REPOSITORY"
  export RESTIC_PASSWORD="$BACKUP_RESTIC_PASSWORD"

  # Auto-init if repo is empty / doesn't exist yet
  if ! su-exec backup restic cat config >/dev/null 2>&1; then
    log "initializing restic repository at $RESTIC_REPOSITORY"
    su-exec backup restic init
  fi

  # Remove stale locks (safe: single-writer by design)
  su-exec backup restic unlock --remove-all 2>/dev/null || true

  log "restic repository ready"
fi

# ── hand off to cron ────────────────────────────────────────────────
log "entrypoint complete, starting crond"
exec crond -f -l 2
