#!/usr/bin/env bash
set -euo pipefail

TAG="pbs-backup"
# PBS_ETC_DIR and PBS_LOCK_FILE are overridable for tests; defaults are production paths.
PBS_ETC_DIR="${PBS_ETC_DIR:-/etc/pbs-backup}"
CONFIG_FILE="${PBS_ETC_DIR}/config"
PRE_HOOK_DIR="${PBS_ETC_DIR}/pre-backup.d"
POST_HOOK_DIR="${PBS_ETC_DIR}/post-backup.d"
LOCK_FILE="${PBS_LOCK_FILE:-/run/lock/pbs-backup.lock}"

log() {
  local level="$1"
  shift
  local message="[$level] $*"
  echo "$message"
  logger -t "$TAG" -- "$message"
}

run_hooks() {
  local hook_dir="$1"
  local hook_stage="$2"
  local hook
  local found=0

  if [[ ! -d "$hook_dir" ]]; then
    log "WARN" "Hook directory not found for ${hook_stage}: ${hook_dir}"
    return 0
  fi

  while IFS= read -r -d '' hook; do
    found=1
    if [[ ! -x "$hook" ]]; then
      log "INFO" "Skipping non-executable ${hook_stage} hook: $(basename "$hook")"
      continue
    fi

    log "INFO" "Running ${hook_stage} hook: $(basename "$hook")"
    # Close the lock fd so anything a hook leaves running can't hold the lock.
    if "$hook" 9>&-; then
      log "INFO" "Completed ${hook_stage} hook: $(basename "$hook")"
    else
      log "WARN" "${hook_stage} hook failed (continuing): $(basename "$hook")"
    fi
  done < <(find "$hook_dir" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)

  if [[ "$found" -eq 0 ]]; then
    log "INFO" "No ${hook_stage} hooks discovered in ${hook_dir}"
  fi
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  log "ERROR" "Missing config file: ${CONFIG_FILE}"
  exit 2
fi

# shellcheck source=/etc/pbs-backup/config
source "$CONFIG_FILE"

: "${PBS_REPOSITORY:?PBS_REPOSITORY must be set in config}"
: "${PBS_PASSWORD:?PBS_PASSWORD must be set in config}"
: "${PBS_FINGERPRINT:?PBS_FINGERPRINT must be set in config}"

if ! declare -p EXTRA_EXCLUDES >/dev/null 2>&1; then
  EXTRA_EXCLUDES=()
fi

if [[ "$(declare -p EXTRA_EXCLUDES 2>/dev/null)" != declare\ -a* ]]; then
  log "WARN" "EXTRA_EXCLUDES is not a bash array; ignoring configured value"
  EXTRA_EXCLUDES=()
fi

# Hold an exclusive lock for the whole run (hooks included) so a manual run
# cannot overlap the timer's run. Released automatically when the script exits.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "ERROR" "Another backup run is already running (lock held: ${LOCK_FILE}); exiting"
  exit 3
fi

export PBS_REPOSITORY
export PBS_PASSWORD
export PBS_FINGERPRINT
export DUMP_DIR="${DUMP_DIR:-/var/backups/pbs-dumps}"

log "INFO" "=== PBS backup run started at $(date -Is) ==="
log "INFO" "Preparing package manifests in ${PBS_ETC_DIR}"

apt-mark showmanual > "${PBS_ETC_DIR}/manual-packages.txt"

dpkg --get-selections > "${PBS_ETC_DIR}/package-selections.txt"

run_hooks "$PRE_HOOK_DIR" "pre-backup"

exclude_args=(
  --exclude /proc
  --exclude /sys
  --exclude /dev
  --exclude /run
  --exclude /tmp
  --exclude /var/tmp
  --exclude /var/cache
  --exclude /lost+found
  --exclude /mnt
  --exclude /media
  --exclude /var/lib/proxmox-backup
  --exclude /swap.img
  --exclude '*.swp'
)

if [[ "${#EXTRA_EXCLUDES[@]}" -gt 0 ]]; then
  log "INFO" "Applying ${#EXTRA_EXCLUDES[@]} extra exclude(s) from config"
  for path in "${EXTRA_EXCLUDES[@]}"; do
    exclude_args+=(--exclude "$path")
  done
fi

log "INFO" "Starting proxmox-backup-client backup: root.pxar:/"
backup_result="fail"
if proxmox-backup-client backup root.pxar:/ "${exclude_args[@]}"; then
  backup_result="success"
fi

export PBS_BACKUP_RESULT="$backup_result"
log "INFO" "Backup result: ${PBS_BACKUP_RESULT}"

run_hooks "$POST_HOOK_DIR" "post-backup"

if [[ "$PBS_BACKUP_RESULT" == "success" ]]; then
  log "INFO" "PBS_BACKUP_SUMMARY=success"
  exit 0
fi

log "ERROR" "PBS_BACKUP_SUMMARY=fail"
exit 1
