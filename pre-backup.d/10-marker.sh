#!/usr/bin/env bash
set -euo pipefail

TAG="pbs-backup"
DUMP_DIR="${DUMP_DIR:-/var/backups/pbs-dumps}"
MARKER_FILE="${DUMP_DIR}/backup-marker.txt"
ORDER_FILE="${DUMP_DIR}/hook-order.log"

log() {
  local message="$*"
  echo "$message"
  logger -t "$TAG" -- "$message"
}

mkdir -p "$DUMP_DIR"

{
  echo "timestamp=$(date -Is)"
  echo "hostname=$(hostname -f 2>/dev/null || hostname)"
  echo "kernel=$(uname -r)"
  echo "uptime=$(uptime -p 2>/dev/null || uptime)"
} > "$MARKER_FILE"

echo "$(date -Is) $(basename "$0") ran" >> "$ORDER_FILE"

log "Marker hook created ${MARKER_FILE} and updated ${ORDER_FILE}"
