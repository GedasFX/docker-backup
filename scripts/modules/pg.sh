#!/usr/bin/env bash
# Module: pg — built-in pg_dump support
#
# Activated by: BACKUP_PG_HOST
# Requires:     pg_dump binary (present in -pg image tag)
#               BACKUP_PG_USER, BACKUP_PG_DB
#               Restic prong enabled (dumps are snapshotted)

PGDUMP_DIR="/var/cache/docker-backup/pgdump"

mod_pg_validate() {
  [[ -z "${BACKUP_PG_HOST:-}" ]] && return 0

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

  if [[ -z "${BACKUP_RESTIC_REPOSITORY:-}" || -z "${BACKUP_RESTIC_PASSWORD:-}" ]]; then
    echo "ERROR: BACKUP_RESTIC_REPOSITORY and BACKUP_RESTIC_PASSWORD are required when BACKUP_PG_HOST is set" >&2
    exit 1
  fi

  log "module pg: enabled (host=$BACKUP_PG_HOST db=$BACKUP_PG_DB)"
}

mod_pg_backup() {
  [[ -z "${BACKUP_PG_HOST:-}" ]] && return 0

  log "pg_dump starting"
  rm -rf "$PGDUMP_DIR"
  mkdir -p "$PGDUMP_DIR"

  # password handling
  if [[ -n "${BACKUP_PG_PASSWORD_FILE:-}" ]]; then
    export PGPASSWORD
    PGPASSWORD=$(cat "$BACKUP_PG_PASSWORD_FILE")
  elif [[ -n "${BACKUP_PG_PASSWORD:-}" ]]; then
    export PGPASSWORD="$BACKUP_PG_PASSWORD"
  fi

  pg_args=(-F d -Z 0)
  pg_args+=(-h "$BACKUP_PG_HOST")
  pg_args+=(-p "${BACKUP_PG_PORT:-5432}")
  pg_args+=(-U "$BACKUP_PG_USER")
  pg_args+=(-d "$BACKUP_PG_DB")

  # per-table selection
  if [[ -n "${BACKUP_PG_TABLES:-}" ]]; then
    IFS=',' read -ra tables <<< "$BACKUP_PG_TABLES"
    for t in "${tables[@]}"; do
      pg_args+=(-t "$t")
    done
  fi

  # extra user args
  if [[ -n "${BACKUP_PG_EXTRA_ARGS:-}" ]]; then
    read -ra extra <<< "$BACKUP_PG_EXTRA_ARGS"
    pg_args+=("${extra[@]}")
  fi

  pg_args+=(-f "$PGDUMP_DIR")

  pg_t0=$(date +%s)
  pg_dump "${pg_args[@]}" || fail "pg_dump failed"
  log "pg_dump completed ($(($(date +%s) - pg_t0))s)"
}

mod_pg_sources() {
  [[ -z "${BACKUP_PG_HOST:-}" ]] && return 0
  echo "$PGDUMP_DIR"
}

mod_pg_cleanup() {
  [[ -z "${BACKUP_PG_HOST:-}" ]] && return 0
  rm -rf "$PGDUMP_DIR"
}
