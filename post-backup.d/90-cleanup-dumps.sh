#!/usr/bin/env bash
set -euo pipefail

TAG="pbs-backup"
DUMP_DIR="${DUMP_DIR:-/var/backups/pbs-dumps}"
MARKER_FILE="${DUMP_DIR}/backup-marker.txt"

log() {
  local message="$*"
  echo "$message"
  logger -t "$TAG" -- "$message"
}

if [[ "${PBS_BACKUP_RESULT:-fail}" != "success" ]]; then
  log "Skipping dump cleanup because PBS_BACKUP_RESULT=${PBS_BACKUP_RESULT:-unset}"
  exit 0
fi

if [[ -f "$MARKER_FILE" ]]; then
  rm -f "$MARKER_FILE"
  log "Removed ${MARKER_FILE} after successful backup"
else
  log "No marker file to remove at ${MARKER_FILE}"
fi

log "Preserving ${DUMP_DIR}/hook-order.log for hook-order diagnostics"
