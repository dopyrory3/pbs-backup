#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_RESET=''
fi

# When invoked as `pbs uninstall ...`, the pbs dispatcher sets PBS_CMD_NAME so
# usage/help text points users back at the pbs subcommand, not this filename.
PROG="${PBS_CMD_NAME:-$(basename "$0")}"

TARGET_DIR="/etc/pbs-backup"
KEYRING_DIR="/etc/apt/keyrings"
PBS_LIST_FILE="/etc/apt/sources.list.d/pbs-client.list"
PBS_KEY_SUITE="${PBS_KEY_SUITE:-bookworm}"
KEYRING_FILE="${KEYRING_DIR}/proxmox-release-${PBS_KEY_SUITE}.gpg"

PURGE=0
REMOVE_PACKAGE=0
REMOVE_REPO=0
ASSUME_YES=0

step() { echo "${C_CYAN}${C_BOLD}$*${C_RESET}"; }
warn() { echo "${C_YELLOW}Warning:${C_RESET} $*" >&2; }
err() { echo "${C_RED}Error:${C_RESET} $*" >&2; }
ok() { echo "${C_GREEN}$*${C_RESET}"; }

usage() {
  cat <<EOF
${C_BOLD}Usage:${C_RESET} ${PROG} [OPTIONS]

By default, removes only what install.sh added that is safe to remove
unconditionally: the systemd service/timer and the suite's own scripts
in /etc/pbs-backup. Your config, dump directory, and package manifests
are left in place.

${C_BOLD}Options:${C_RESET}
  ${C_CYAN}--purge${C_RESET}            Also remove /etc/pbs-backup/config, package manifest
                      files, and the DUMP_DIR contents (default: /var/backups/pbs-dumps).
  ${C_CYAN}--remove-package${C_RESET}    Also uninstall the proxmox-backup-client package.
  ${C_CYAN}--remove-repo${C_RESET}       Also remove the PBS client APT repo and its release key.
  ${C_CYAN}-y, --yes${C_RESET}           Do not prompt for confirmation on destructive steps.
  ${C_CYAN}-h, --help${C_RESET}          Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --remove-package) REMOVE_PACKAGE=1 ;;
    --remove-repo) REMOVE_REPO=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      err "Unknown option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  err "Run this uninstaller as root."
  exit 1
fi

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

step "[1/5] Stopping and disabling timer/service"
systemctl disable --now pbs-backup.timer 2>/dev/null || true
systemctl stop pbs-backup.service 2>/dev/null || true

step "[2/5] Removing systemd units"
rm -f /etc/systemd/system/pbs-backup.service /etc/systemd/system/pbs-backup.timer
systemctl daemon-reload

step "[3/5] Removing installed scripts from ${TARGET_DIR}"
# rm unlinks rather than truncating, so this is safe even when removing the
# copy of this very script at ${TARGET_DIR}/uninstall.sh mid-run.
rm -f \
  "${TARGET_DIR}/run-backup.sh" \
  "${TARGET_DIR}/restore.sh" \
  "${TARGET_DIR}/uninstall.sh" \
  "${TARGET_DIR}/upgrade.sh" \
  "${TARGET_DIR}/pbs" \
  "${TARGET_DIR}/config.example" \
  "${TARGET_DIR}/pre-backup.d/10-marker.sh" \
  "${TARGET_DIR}/post-backup.d/90-cleanup-dumps.sh"
rmdir --ignore-fail-on-non-empty "${TARGET_DIR}/pre-backup.d" "${TARGET_DIR}/post-backup.d" 2>/dev/null || true

if [[ -L /usr/local/bin/pbs && "$(readlink /usr/local/bin/pbs)" == "${TARGET_DIR}/pbs" ]]; then
  rm -f /usr/local/bin/pbs
fi

if [[ "$PURGE" -eq 1 ]]; then
  DUMP_DIR="/var/backups/pbs-dumps"
  if [[ -f "${TARGET_DIR}/config" ]]; then
    # shellcheck source=/dev/null
    source "${TARGET_DIR}/config" 2>/dev/null || true
    DUMP_DIR="${DUMP_DIR:-/var/backups/pbs-dumps}"
  fi

  if confirm "Purge ${TARGET_DIR} (including config) and ${DUMP_DIR}?"; then
    rm -rf "${TARGET_DIR}" "${DUMP_DIR}"
    ok "Purged ${TARGET_DIR} and ${DUMP_DIR}"
  else
    echo "Skipped purge."
  fi
else
  echo "Preserving ${TARGET_DIR}/config, package manifests, and dump directory (use --purge to remove)."
  rmdir --ignore-fail-on-non-empty "${TARGET_DIR}" 2>/dev/null || true
fi

if [[ "$REMOVE_REPO" -eq 1 ]]; then
  step "[4/5] Removing PBS client APT repo and release key"
  rm -f "$PBS_LIST_FILE" "$KEYRING_FILE"
  apt-get update
else
  step "[4/5] Leaving PBS client APT repo in place (use --remove-repo to remove)"
fi

if [[ "$REMOVE_PACKAGE" -eq 1 ]]; then
  step "[5/5] Removing proxmox-backup-client package"
  for pkg in proxmox-backup-client proxmox-backup-client-static; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      if confirm "Remove installed package '${pkg}'?"; then
        apt-get remove -y "$pkg"
      fi
    fi
  done
else
  step "[5/5] Leaving proxmox-backup-client package installed (use --remove-package to remove)"
fi

ok "Uninstall complete."
