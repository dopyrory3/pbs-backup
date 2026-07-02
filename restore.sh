#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_RESET=''
fi

# When invoked as `pbs restore ...`, the pbs dispatcher sets PBS_CMD_NAME so
# usage/help text points users back at the pbs subcommand, not this filename.
PROG="${PBS_CMD_NAME:-$(basename "$0")}"

CONFIG_FILE="/etc/pbs-backup/config"
DEFAULT_MOUNTPOINT="/mnt/restore"
ARCHIVE="root.pxar"

warn() { echo "${C_YELLOW}Warning:${C_RESET} $*" >&2; }
err() { echo "${C_RED}Error:${C_RESET} $*" >&2; }
ok() { echo "${C_GREEN}$*${C_RESET}"; }

usage() {
  cat <<EOF
${C_BOLD}Usage:${C_RESET} ${PROG} <command> [args]

${C_BOLD}Commands:${C_RESET}
  ${C_CYAN}list${C_RESET}                          List snapshots in the configured PBS repository.
  ${C_CYAN}mount${C_RESET} [snapshot] [mountpoint] Mount a snapshot (default archive: root.pxar).
                                 Omit snapshot to pick from an interactive list.
                                 Default mountpoint: /mnt/restore
  ${C_CYAN}unmount${C_RESET} [mountpoint]          Unmount a previously mounted snapshot.
                                 Default mountpoint: /mnt/restore
  ${C_CYAN}packages${C_RESET} [manifest]           Reinstall manually-installed packages from a
                                 manual-packages.txt manifest. Defaults to
                                 <mountpoint>/etc/pbs-backup/manual-packages.txt
                                 if a snapshot is mounted there, else falls
                                 back to /etc/pbs-backup/manual-packages.txt.
  ${C_CYAN}status${C_RESET} [mountpoint]           Show whether a restore mount is active.

${C_BOLD}Examples:${C_RESET}
  ${PROG} list
  ${PROG} mount                        # pick a snapshot interactively
  ${PROG} mount host/myhost/2026-07-01T03:12:45Z
  ${PROG} packages
  ${PROG} unmount
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this command as root."
    exit 1
  fi
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Missing config file: ${CONFIG_FILE}"
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
    err "jq is required for interactive snapshot selection (apt-get install jq)."
    echo "Alternatively, run '${PROG} list' and pass a snapshot ID to '${PROG} mount' directly." >&2
    exit 1
  fi

  local json
  json="$(proxmox-backup-client snapshot list --output-format json)"

  local count
  count="$(jq 'length' <<<"$json")"
  if [[ "$count" -eq 0 ]]; then
    err "No snapshots found in ${PBS_REPOSITORY}."
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

  echo "${C_BOLD}Available snapshots:${C_RESET}" >&2
  local sel
  PS3="${C_CYAN}Select a snapshot to mount:${C_RESET} "
  select sel in "${labels[@]}"; do
    if [[ -n "${sel:-}" ]]; then
      echo "${ids[$((REPLY - 1))]}"
      return 0
    fi
    warn "Invalid selection, try again."
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
    err "${mountpoint} is already a mount point; unmount it first."
    exit 1
  fi

  mkdir -p "$mountpoint"
  echo "${C_CYAN}Mounting ${snapshot} (${ARCHIVE}) at ${mountpoint}${C_RESET}"
  proxmox-backup-client mount "$snapshot" "$ARCHIVE" "$mountpoint"
  ok "Mounted. Unmount later with: ${PROG} unmount ${mountpoint}"
}

cmd_unmount() {
  local mountpoint="${1:-$DEFAULT_MOUNTPOINT}"
  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    err "${mountpoint} is not currently mounted."
    exit 1
  fi
  proxmox-backup-client unmount "$mountpoint"
  ok "Unmounted ${mountpoint}"
}

cmd_packages() {
  local manifest="${1:-}"

  if [[ -z "$manifest" ]]; then
    if [[ -f "${DEFAULT_MOUNTPOINT}/etc/pbs-backup/manual-packages.txt" ]]; then
      manifest="${DEFAULT_MOUNTPOINT}/etc/pbs-backup/manual-packages.txt"
    elif [[ -f /etc/pbs-backup/manual-packages.txt ]]; then
      manifest="/etc/pbs-backup/manual-packages.txt"
    else
      err "No manifest found at ${DEFAULT_MOUNTPOINT}/etc/pbs-backup/manual-packages.txt"
      echo "or /etc/pbs-backup/manual-packages.txt. Pass a path explicitly." >&2
      exit 1
    fi
  fi

  if [[ ! -f "$manifest" ]]; then
    err "Manifest not found: ${manifest}"
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
    ok "${mountpoint} is mounted."
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
    err "Unknown command: ${command}"
    usage >&2
    exit 1
    ;;
esac
