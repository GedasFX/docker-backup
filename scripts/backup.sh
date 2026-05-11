#!/usr/bin/env bash
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────
: "${BACKUP_NAME:=${HOSTNAME}}"
: "${BACKUP_RESTIC_FORGET:=--keep-daily 7 --keep-weekly 4}"
: "${BACKUP_RESTIC_CHECK_DOW:=7}"
: "${BACKUP_RSYNC_ARGS:=-a --delete}"
: "${BACKUP_WEBHOOK_URL:=}"
: "${BACKUP_WEBHOOK_HEARTBEAT_EVERY:=7}"
: "${BACKUP_VERBOSE:=}"

PGDUMP_DIR="/var/cache/docker-backup/pgdump"
SUCCESS_FILE="/var/run/last-success"
COUNTER_FILE="/var/run/backup-counter"

t0=$(date +%s)
total_bytes=0

log()  { echo "[$(date -u +%H:%M:%S)] [$BACKUP_NAME] $*"; }
fail() { log "FAILED: $*"; webhook_failure "$*"; exit 1; }

# ── webhook helpers ─────────────────────────────────────────────────
webhook_failure() {
  [[ -z "$BACKUP_WEBHOOK_URL" ]] && return 0
  local detail
  detail=$(echo "$1" | tail -c 200)
  local payload
  payload=$(printf '{"content":"[%s] failure — %s","username":"docker-backup"}' \
    "$BACKUP_NAME" "$detail")
  curl -sf -X POST -H "Content-Type: application/json" \
    -d "$payload" "$BACKUP_WEBHOOK_URL" >/dev/null 2>&1 || true
}

webhook_heartbeat() {
  [[ -z "$BACKUP_WEBHOOK_URL" ]] && return 0
  [[ "$BACKUP_WEBHOOK_HEARTBEAT_EVERY" == "0" ]] && return 0

  local count
  count=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  count=$((count + 1))
  echo "$count" > "$COUNTER_FILE"

  if (( count % BACKUP_WEBHOOK_HEARTBEAT_EVERY == 0 )); then
    local elapsed=$(( $(date +%s) - t0 ))
    local payload
    payload=$(printf '{"content":"[%s] heartbeat — run #%d, %ds, %d bytes","username":"docker-backup"}' \
      "$BACKUP_NAME" "$count" "$elapsed" "$total_bytes")
    curl -sf -X POST -H "Content-Type: application/json" \
      -d "$payload" "$BACKUP_WEBHOOK_URL" >/dev/null 2>&1 || true
    log "heartbeat sent (run #$count)"
  fi
}

# ── run a hook (inline string or script file) ──────────────────────
run_hook() {
  local name="$1" inline_var="$2" script_var="$3"
  local inline="${!inline_var:-}"
  local script="${!script_var:-}"

  if [[ -n "$inline" ]]; then
    log "$name (inline)"
    bash -euo pipefail -c "$inline" || fail "$name hook failed"
  elif [[ -n "$script" ]]; then
    log "$name ($script)"
    bash -euo pipefail "$script" || fail "$name hook failed"
  fi
}

# ── pg_dump prong ───────────────────────────────────────────────────
pg_sources=""
if [[ -n "${BACKUP_PG_HOST:-}" ]]; then
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

  pg_sources="$PGDUMP_DIR"
fi

# ── pre-hook ────────────────────────────────────────────────────────
run_hook "pre-hook" BACKUP_PRE BACKUP_PRE_SCRIPT

# ── restic backup ──────────────────────────────────────────────────
if [[ -n "${BACKUP_RESTIC_REPOSITORY:-}" ]]; then
  export RESTIC_REPOSITORY="$BACKUP_RESTIC_REPOSITORY"
  export RESTIC_PASSWORD="$BACKUP_RESTIC_PASSWORD"

  # build sources list: pg dump dir (if active) + user-specified sources
  all_sources="$pg_sources"
  if [[ -n "${BACKUP_RESTIC_SOURCES:-}" ]]; then
    all_sources="${all_sources:+$all_sources }$BACKUP_RESTIC_SOURCES"
  fi

  if [[ -n "$all_sources" ]]; then
    restic_args=(backup --tag "$BACKUP_NAME")

    # excludes
    if [[ -n "${BACKUP_RESTIC_EXCLUDES:-}" ]]; then
      read -ra excludes <<< "$BACKUP_RESTIC_EXCLUDES"
      for e in "${excludes[@]}"; do
        restic_args+=(--exclude "$e")
      done
    fi

    [[ -n "$BACKUP_VERBOSE" ]] && restic_args+=(-v)

    read -ra src_array <<< "$all_sources"
    restic_args+=("${src_array[@]}")

    restic_t0=$(date +%s)
    log "restic backup starting: $all_sources"
    restic_output=$(restic "${restic_args[@]}" 2>&1) || fail "restic backup failed: $restic_output"

    # extract bytes added from restic summary line
    bytes=$(echo "$restic_output" | sed -n 's/.*Added to the repository: *\([0-9.]*\s*[A-Za-z]*\).*/\1/p' || true)
    : "${bytes:=unknown}"
    log "restic backup completed ($(($(date +%s) - restic_t0))s, $bytes)"
  fi

  # ── restic forget ──────────────────────────────────────────────
  if [[ -n "$BACKUP_RESTIC_FORGET" ]]; then
    log "restic forget"
    read -ra forget_args <<< "$BACKUP_RESTIC_FORGET"
    restic forget --tag "$BACKUP_NAME" "${forget_args[@]}" --prune 2>&1 || fail "restic forget failed"
    log "restic forget completed"
  fi

  # ── restic check (weekly) ─────────────────────────────────────
  if [[ "$BACKUP_RESTIC_CHECK_DOW" != "0" ]]; then
    current_dow=$(date +%u)
    if [[ "$current_dow" == "$BACKUP_RESTIC_CHECK_DOW" ]]; then
      log "restic check (weekly)"
      restic check 2>&1 || fail "restic check failed"
      log "restic check completed"
    fi
  fi
fi

# ── rsync mirror ────────────────────────────────────────────────────
if [[ -n "${BACKUP_RSYNC_SRC:-}" && -n "${BACKUP_RSYNC_DST:-}" ]]; then
  rsync_cmd_args=()
  read -ra rsync_cmd_args <<< "$BACKUP_RSYNC_ARGS"
  [[ -n "$BACKUP_VERBOSE" ]] && rsync_cmd_args+=(-v)

  rsync_t0=$(date +%s)
  log "rsync starting: ${BACKUP_RSYNC_SRC} → ${BACKUP_RSYNC_DST}"
  rsync "${rsync_cmd_args[@]}" "${BACKUP_RSYNC_SRC}/" "${BACKUP_RSYNC_DST}/" || fail "rsync failed"
  log "rsync completed ($(($(date +%s) - rsync_t0))s)"
fi

# ── post-hook ───────────────────────────────────────────────────────
run_hook "post-hook" BACKUP_POST BACKUP_POST_SCRIPT

# ── pg cleanup ──────────────────────────────────────────────────────
if [[ -n "${BACKUP_PG_HOST:-}" ]]; then
  rm -rf "$PGDUMP_DIR"
fi

# ── success ─────────────────────────────────────────────────────────
elapsed=$(( $(date +%s) - t0 ))
date +%s > "$SUCCESS_FILE"
log "completed in ${elapsed}s"

webhook_heartbeat
