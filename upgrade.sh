#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/etc/pbs-backup"

FORCE=0
ASSUME_YES=0
NO_BACKUP=0

usage() {
  cat <<'EOF'
Usage: upgrade.sh [OPTIONS]

Updates the files under /etc/pbs-backup and the systemd units to match
what's in this repo checkout (SCRIPT_DIR), the same way install.sh does
on first install. Pull/checkout the version of this repo you want to
deploy before running this script.

Never touches /etc/pbs-backup/config, the APT repo, or the installed
proxmox-backup-client package -- use install.sh for those.

Options:
  --force      Reinstall files even if the installed version already
               matches the repo version.
  --no-backup  Skip backing up replaced files before overwriting them.
  -y, --yes    Do not prompt for confirmation.
  -h, --help   Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --no-backup) NO_BACKUP=1 ;;
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
  echo "Run this upgrader as root."
  exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "${TARGET_DIR} not found; nothing to upgrade. Run install.sh first."
  exit 1
fi

REPO_VERSION="unknown"
if [[ -f "${SCRIPT_DIR}/version" ]]; then
  REPO_VERSION="$(<"${SCRIPT_DIR}/version")"
fi

INSTALLED_VERSION="unknown"
if [[ -f "${TARGET_DIR}/version" ]]; then
  INSTALLED_VERSION="$(<"${TARGET_DIR}/version")"
fi

echo "Installed version: ${INSTALLED_VERSION}"
echo "Repo version:       ${REPO_VERSION}"

if [[ "$INSTALLED_VERSION" == "$REPO_VERSION" && "$REPO_VERSION" != "unknown" && "$FORCE" -ne 1 ]]; then
  echo "Already up to date. Use --force to reinstall files anyway."
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Upgrade ${TARGET_DIR} from ${INSTALLED_VERSION} to ${REPO_VERSION}? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

if systemctl is-active --quiet pbs-backup.service; then
  echo "Warning: pbs-backup.service is currently running a backup; files will still be replaced."
fi

if [[ "$NO_BACKUP" -ne 1 ]]; then
  BACKUP_DIR="${TARGET_DIR}/.upgrade-backups/$(date +%Y%m%d%H%M%S)"
  echo "[1/4] Backing up current suite files to ${BACKUP_DIR}"
  install -d -m 0700 "$BACKUP_DIR"
  for f in run-backup.sh config.example restore.sh uninstall.sh upgrade.sh pbs; do
    [[ -f "${TARGET_DIR}/${f}" ]] && cp -a "${TARGET_DIR}/${f}" "${BACKUP_DIR}/"
  done
  [[ -d "${TARGET_DIR}/pre-backup.d" ]] && cp -a "${TARGET_DIR}/pre-backup.d" "${BACKUP_DIR}/"
  [[ -d "${TARGET_DIR}/post-backup.d" ]] && cp -a "${TARGET_DIR}/post-backup.d" "${BACKUP_DIR}/"
  for f in /etc/systemd/system/pbs-backup.service /etc/systemd/system/pbs-backup.timer; do
    [[ -f "$f" ]] && cp -a "$f" "${BACKUP_DIR}/"
  done
else
  echo "[1/4] Skipping backup (--no-backup)"
fi

echo "[2/4] Syncing suite scripts into ${TARGET_DIR}"
# install(1) unlinks the destination before writing, so it's safe even when
# overwriting the copy of this very script at ${TARGET_DIR}/upgrade.sh mid-run.
install -d -m 0755 "${TARGET_DIR}/pre-backup.d"
install -d -m 0755 "${TARGET_DIR}/post-backup.d"

install -m 0755 "${SCRIPT_DIR}/run-backup.sh" "${TARGET_DIR}/run-backup.sh"
install -m 0755 "${SCRIPT_DIR}/restore.sh" "${TARGET_DIR}/restore.sh"
install -m 0755 "${SCRIPT_DIR}/uninstall.sh" "${TARGET_DIR}/uninstall.sh"
install -m 0755 "${SCRIPT_DIR}/upgrade.sh" "${TARGET_DIR}/upgrade.sh"
install -m 0755 "${SCRIPT_DIR}/pbs" "${TARGET_DIR}/pbs"
install -m 0644 "${SCRIPT_DIR}/config.example" "${TARGET_DIR}/config.example"

# Sync every hook the repo ships, without touching host-specific hooks that
# were dropped into these directories outside of this repo.
shopt -s nullglob
for hook in "${SCRIPT_DIR}"/pre-backup.d/*.sh; do
  install -m 0755 "$hook" "${TARGET_DIR}/pre-backup.d/$(basename "$hook")"
done
for hook in "${SCRIPT_DIR}"/post-backup.d/*.sh; do
  install -m 0755 "$hook" "${TARGET_DIR}/post-backup.d/$(basename "$hook")"
done
shopt -u nullglob

ln -sf "${TARGET_DIR}/pbs" /usr/local/bin/pbs

echo "[3/4] Syncing systemd units"
install -m 0644 "${SCRIPT_DIR}/deploy/pbs-backup.service" "/etc/systemd/system/pbs-backup.service"
install -m 0644 "${SCRIPT_DIR}/deploy/pbs-backup.timer" "/etc/systemd/system/pbs-backup.timer"
systemctl daemon-reload
systemctl enable --now pbs-backup.timer

echo "[4/4] Recording installed version"
if [[ -f "${SCRIPT_DIR}/version" ]]; then
  install -m 0644 "${SCRIPT_DIR}/version" "${TARGET_DIR}/version"
fi

echo "Upgrade complete: ${INSTALLED_VERSION} -> ${REPO_VERSION}"
echo "Config at ${TARGET_DIR}/config was not touched."
