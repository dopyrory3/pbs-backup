#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/etc/pbs-backup"
KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/proxmox-release-bookworm.gpg"
PBS_LIST_FILE="/etc/apt/sources.list.d/pbs-client.list"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root."
  exit 1
fi

echo "[1/6] Configuring Proxmox PBS client APT repository"
install -d -m 0755 "$KEYRING_DIR"
curl -fsSL https://download.proxmox.com/debian/proxmox-release-bookworm.gpg -o "$KEYRING_FILE"
chmod 0644 "$KEYRING_FILE"

echo "deb [signed-by=${KEYRING_FILE}] https://download.proxmox.com/debian/pbs-client bookworm main" > "$PBS_LIST_FILE"

apt-get update
apt-get install -y proxmox-backup-client

echo "[2/6] Installing backup suite into ${TARGET_DIR}"
install -d -m 0755 "$TARGET_DIR"
install -d -m 0755 "${TARGET_DIR}/pre-backup.d"
install -d -m 0755 "${TARGET_DIR}/post-backup.d"

install -m 0755 "${SCRIPT_DIR}/run-backup.sh" "${TARGET_DIR}/run-backup.sh"
install -m 0644 "${SCRIPT_DIR}/config.example" "${TARGET_DIR}/config.example"
install -m 0755 "${SCRIPT_DIR}/pre-backup.d/10-marker.sh" "${TARGET_DIR}/pre-backup.d/10-marker.sh"
install -m 0755 "${SCRIPT_DIR}/post-backup.d/90-cleanup-dumps.sh" "${TARGET_DIR}/post-backup.d/90-cleanup-dumps.sh"

if [[ -f "${TARGET_DIR}/config" ]]; then
  echo "[3/6] Preserving existing ${TARGET_DIR}/config"
else
  install -m 0600 "${SCRIPT_DIR}/config.example" "${TARGET_DIR}/config"
  echo "[3/6] Created ${TARGET_DIR}/config from template (edit with real credentials)"
fi

echo "[4/6] Installing systemd units"
install -m 0644 "${SCRIPT_DIR}/deploy/pbs-backup.service" "/etc/systemd/system/pbs-backup.service"
install -m 0644 "${SCRIPT_DIR}/deploy/pbs-backup.timer" "/etc/systemd/system/pbs-backup.timer"

systemctl daemon-reload

echo "[5/6] Enabling timer"
systemctl enable --now pbs-backup.timer

echo "[6/6] Install complete"
cat <<'EOF'
Next steps:
1. Edit /etc/pbs-backup/config and set PBS_REPOSITORY, PBS_PASSWORD, PBS_FINGERPRINT.
2. Run a connectivity smoke test backup:
   proxmox-backup-client backup etc.pxar:/etc
3. Run a full backup manually once:
   /etc/pbs-backup/run-backup.sh
4. Check logs:
   journalctl -t pbs-backup -n 200 --no-pager
EOF
