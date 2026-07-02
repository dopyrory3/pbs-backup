#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/pbs-backup/config"
DEFAULT_MOUNTPOINT="/mnt/restore"
ARCHIVE="root.pxar"

usage() {
  cat <<'EOF'
Usage: restore.sh <command> [args]

Commands:
  list                          List snapshots in the configured PBS repository.
  mount [snapshot] [mountpoint] Mount a snapshot (default archive: root.pxar).
                                 Omit snapshot to pick from an interactive list.
                                 Default mountpoint: /mnt/restore
  unmount [mountpoint]          Unmount a previously mounted snapshot.
                                 Default mountpoint: /mnt/restore
  packages [manifest]           Reinstall manually-installed packages from a
                                 manual-packages.txt manifest. Defaults to
                                 <mountpoint>/etc/pbs-backup/manual-packages.txt
                                 if a snapshot is mounted there, else falls
                                 back to /etc/pbs-backup/manual-packages.txt.
  status [mountpoint]           Show whether a restore mount is active.

Examples:
  ./restore.sh list
  ./restore.sh mount                        # pick a snapshot interactively
  ./restore.sh mount host/myhost/2026-07-01T03:12:45Z
  ./restore.sh packages
  ./restore.sh unmount
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this command as root." >&2
    exit 1
  fi
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing config file: ${CONFIG_FILE}" >&2
    exit 1
  fi
  # shellcheck source=/etc/pbs-backup/config
  source "$CONFIG_FILE"
  : "${PBS_REPOSITORY:?PBS_REPOSITORY must be set in config}"
  : "${PBS_PASSWORD:?PBS_PASSWORD must be set in config}"
  : "${PBS_FINGERPRINT:?PBS_FINGERPRINT must be set in config}"
  export PBS_REPOSITORY PBS_PASSWORD PBS_FINGERPRINT
}

cmd_list() {
  load_config
  proxmox-backup-client snapshot list
}

# Interactive picker needs machine-readable output to build stable snapshot
# IDs (list's human table wraps/truncates columns), so this shells out to jq.
select_snapshot() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for interactive snapshot selection (apt-get install jq)." >&2
    echo "Alternatively, run '$0 list' and pass a snapshot ID to '$0 mount' directly." >&2
    exit 1
  fi

  local json
  json="$(proxmox-backup-client snapshot list --output-format json)"

  local count
  count="$(jq 'length' <<<"$json")"
  if [[ "$count" -eq 0 ]]; then
    echo "No snapshots found in ${PBS_REPOSITORY}." >&2
    exit 1
  fi

  local -a ids=()
  local -a labels=()
  local i btype bid btime iso
  for ((i = 0; i < count; i++)); do
    btype="$(jq -r ".[$i][\"backup-type\"]" <<<"$json")"
    bid="$(jq -r ".[$i][\"backup-id\"]" <<<"$json")"
    btime="$(jq -r ".[$i][\"backup-time\"]" <<<"$json")"
    iso="$(date -u -d "@${btime}" +%Y-%m-%dT%H:%M:%SZ)"
    ids+=("${btype}/${bid}/${iso}")
    labels+=("${btype}/${bid}/${iso}")
  done

  echo "Available snapshots:" >&2
  local sel
  PS3="Select a snapshot to mount: "
  select sel in "${labels[@]}"; do
    if [[ -n "${sel:-}" ]]; then
      echo "${ids[$((REPLY - 1))]}"
      return 0
    fi
    echo "Invalid selection, try again." >&2
  done
}

cmd_mount() {
  load_config
  local snapshot="${1:-}"
  local mountpoint="${2:-$DEFAULT_MOUNTPOINT}"

  if [[ -z "$snapshot" ]]; then
    snapshot="$(select_snapshot)"
  fi

  if mountpoint -q "$mountpoint" 2>/dev/null; then
    echo "${mountpoint} is already a mount point; unmount it first." >&2
    exit 1
  fi

  mkdir -p "$mountpoint"
  echo "Mounting ${snapshot} (${ARCHIVE}) at ${mountpoint}"
  proxmox-backup-client mount "$snapshot" "$ARCHIVE" "$mountpoint"
  echo "Mounted. Unmount later with: $0 unmount ${mountpoint}"
}

cmd_unmount() {
  local mountpoint="${1:-$DEFAULT_MOUNTPOINT}"
  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    echo "${mountpoint} is not currently mounted." >&2
    exit 1
  fi
  proxmox-backup-client unmount "$mountpoint"
  echo "Unmounted ${mountpoint}"
}

cmd_packages() {
  local manifest="${1:-}"

  if [[ -z "$manifest" ]]; then
    if [[ -f "${DEFAULT_MOUNTPOINT}/etc/pbs-backup/manual-packages.txt" ]]; then
      manifest="${DEFAULT_MOUNTPOINT}/etc/pbs-backup/manual-packages.txt"
    elif [[ -f /etc/pbs-backup/manual-packages.txt ]]; then
      manifest="/etc/pbs-backup/manual-packages.txt"
    else
      echo "No manifest found at ${DEFAULT_MOUNTPOINT}/etc/pbs-backup/manual-packages.txt" >&2
      echo "or /etc/pbs-backup/manual-packages.txt. Pass a path explicitly." >&2
      exit 1
    fi
  fi

  if [[ ! -f "$manifest" ]]; then
    echo "Manifest not found: ${manifest}" >&2
    exit 1
  fi

  echo "This will run: apt-get install -y \$(cat ${manifest})"
  local count
  count="$(wc -l < "$manifest")"
  echo "Manifest lists ${count} package(s)."
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  apt-get update
  xargs -a "$manifest" apt-get install -y
}

cmd_status() {
  local mountpoint="${1:-$DEFAULT_MOUNTPOINT}"
  if mountpoint -q "$mountpoint" 2>/dev/null; then
    echo "${mountpoint} is mounted."
  else
    echo "${mountpoint} is not mounted."
  fi
}

command="${1:-}"
[[ $# -gt 0 ]] && shift

case "$command" in
  list) require_root; cmd_list "$@" ;;
  mount) require_root; cmd_mount "$@" ;;
  unmount) require_root; cmd_unmount "$@" ;;
  packages) require_root; cmd_packages "$@" ;;
  status) cmd_status "$@" ;;
  -h|--help|"") usage ;;
  *)
    echo "Unknown command: ${command}" >&2
    usage >&2
    exit 1
    ;;
esac
