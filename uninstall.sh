#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/etc/pbs-backup"
KEYRING_DIR="/etc/apt/keyrings"
PBS_LIST_FILE="/etc/apt/sources.list.d/pbs-client.list"
PBS_KEY_SUITE="${PBS_KEY_SUITE:-bookworm}"
KEYRING_FILE="${KEYRING_DIR}/proxmox-release-${PBS_KEY_SUITE}.gpg"

PURGE=0
REMOVE_PACKAGE=0
REMOVE_REPO=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [OPTIONS]

By default, removes only what install.sh added that is safe to remove
unconditionally: the systemd service/timer and the suite's own scripts
in /etc/pbs-backup. Your config, dump directory, and package manifests
are left in place.

Options:
  --purge            Also remove /etc/pbs-backup/config, package manifest
                      files, and the DUMP_DIR contents (default: /var/backups/pbs-dumps).
  --remove-package    Also uninstall the proxmox-backup-client package.
  --remove-repo       Also remove the PBS client APT repo and its release key.
  -y, --yes           Do not prompt for confirmation on destructive steps.
  -h, --help          Show this help.
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
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this uninstaller as root."
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

echo "[1/5] Stopping and disabling timer/service"
systemctl disable --now pbs-backup.timer 2>/dev/null || true
systemctl stop pbs-backup.service 2>/dev/null || true

echo "[2/5] Removing systemd units"
rm -f /etc/systemd/system/pbs-backup.service /etc/systemd/system/pbs-backup.timer
systemctl daemon-reload

echo "[3/5] Removing installed scripts from ${TARGET_DIR}"
# rm unlinks rather than truncating, so this is safe even when removing the
# copy of this very script at ${TARGET_DIR}/uninstall.sh mid-run.
rm -f \
  "${TARGET_DIR}/run-backup.sh" \
  "${TARGET_DIR}/restore.sh" \
  "${TARGET_DIR}/uninstall.sh" \
  "${TARGET_DIR}/upgrade.sh" \
  "${TARGET_DIR}/config.example" \
  "${TARGET_DIR}/pre-backup.d/10-marker.sh" \
  "${TARGET_DIR}/post-backup.d/90-cleanup-dumps.sh"
rmdir --ignore-fail-on-non-empty "${TARGET_DIR}/pre-backup.d" "${TARGET_DIR}/post-backup.d" 2>/dev/null || true

if [[ "$PURGE" -eq 1 ]]; then
  DUMP_DIR="/var/backups/pbs-dumps"
  if [[ -f "${TARGET_DIR}/config" ]]; then
    # shellcheck source=/dev/null
    source "${TARGET_DIR}/config" 2>/dev/null || true
    DUMP_DIR="${DUMP_DIR:-/var/backups/pbs-dumps}"
  fi

  if confirm "Purge ${TARGET_DIR} (including config) and ${DUMP_DIR}?"; then
    rm -rf "${TARGET_DIR}" "${DUMP_DIR}"
    echo "Purged ${TARGET_DIR} and ${DUMP_DIR}"
  else
    echo "Skipped purge."
  fi
else
  echo "Preserving ${TARGET_DIR}/config, package manifests, and dump directory (use --purge to remove)."
  rmdir --ignore-fail-on-non-empty "${TARGET_DIR}" 2>/dev/null || true
fi

if [[ "$REMOVE_REPO" -eq 1 ]]; then
  echo "[4/5] Removing PBS client APT repo and release key"
  rm -f "$PBS_LIST_FILE" "$KEYRING_FILE"
  apt-get update
else
  echo "[4/5] Leaving PBS client APT repo in place (use --remove-repo to remove)"
fi

if [[ "$REMOVE_PACKAGE" -eq 1 ]]; then
  echo "[5/5] Removing proxmox-backup-client package"
  for pkg in proxmox-backup-client proxmox-backup-client-static; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      if confirm "Remove installed package '${pkg}'?"; then
        apt-get remove -y "$pkg"
      fi
    fi
  done
else
  echo "[5/5] Leaving proxmox-backup-client package installed (use --remove-package to remove)"
fi

echo "Uninstall complete."
