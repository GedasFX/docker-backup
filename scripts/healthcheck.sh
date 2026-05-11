#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_HEALTHCHECK_MAX_AGE:=93600}"

SUCCESS_FILE="/var/run/last-success"

# No success recorded yet — healthy until first expected run window passes
if [[ ! -f "$SUCCESS_FILE" ]]; then
  exit 0
fi

last=$(cat "$SUCCESS_FILE")
now=$(date +%s)
age=$(( now - last ))

if (( age > BACKUP_HEALTHCHECK_MAX_AGE )); then
  echo "unhealthy: last success ${age}s ago (max ${BACKUP_HEALTHCHECK_MAX_AGE}s)"
  exit 1
fi

exit 0
