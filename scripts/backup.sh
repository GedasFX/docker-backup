#!/usr/bin/env bash
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────
: "${BACKUP_NAME:=default}"
: "${BACKUP_RESTIC_FORGET:=--keep-daily 7 --keep-weekly 4}"
: "${BACKUP_RESTIC_CHECK_DOW:=7}"
: "${BACKUP_RSYNC_ARGS:=-a --delete}"
: "${BACKUP_WEBHOOK_URL:=}"
: "${BACKUP_WEBHOOK_HEARTBEAT_EVERY:=7}"
: "${BACKUP_VERBOSE:=}"

SUCCESS_FILE="/var/run/docker-backup/last-success"
COUNTER_FILE="/var/run/docker-backup/counter"
MODULE_DIR="/usr/local/lib/docker-backup/modules.d"

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

# ── load modules ────────────────────────────────────────────────────
loaded_modules=()
for mod_file in "$MODULE_DIR"/*.sh; do
  [[ -f "$mod_file" ]] || continue
  mod_name=$(basename "$mod_file" .sh)
  source "$mod_file"
  loaded_modules+=("$mod_name")
done

# ── module backups (dumps) ──────────────────────────────────────────
for mod_name in "${loaded_modules[@]}"; do
  "mod_${mod_name}_backup"
done

# ── collect module sources for restic ───────────────────────────────
module_sources=""
for mod_name in "${loaded_modules[@]}"; do
  ms=$("mod_${mod_name}_sources")
  if [[ -n "$ms" ]]; then
    module_sources="${module_sources:+$module_sources }$ms"
  fi
done

# ── pre-hook ────────────────────────────────────────────────────────
run_hook "pre-hook" BACKUP_PRE BACKUP_PRE_SCRIPT

# ── restic backup ──────────────────────────────────────────────────
if [[ -n "${BACKUP_RESTIC_REPOSITORY:-}" ]]; then
  export RESTIC_REPOSITORY="$BACKUP_RESTIC_REPOSITORY"
  export RESTIC_PASSWORD="$BACKUP_RESTIC_PASSWORD"

  # build sources list: module sources + user-specified sources
  all_sources="$module_sources"
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

# ── module cleanup ──────────────────────────────────────────────────
for mod_name in "${loaded_modules[@]}"; do
  "mod_${mod_name}_cleanup"
done

# ── success ─────────────────────────────────────────────────────────
elapsed=$(( $(date +%s) - t0 ))
date +%s > "$SUCCESS_FILE"
log "completed in ${elapsed}s"

webhook_heartbeat
