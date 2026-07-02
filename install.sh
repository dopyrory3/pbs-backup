#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_RESET=''
fi

step() { echo "${C_CYAN}${C_BOLD}$*${C_RESET}"; }
warn() { echo "${C_YELLOW}Warning:${C_RESET} $*" >&2; }
err() { echo "${C_RED}Error:${C_RESET} $*" >&2; }
ok() { echo "${C_GREEN}$*${C_RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/etc/pbs-backup"
KEYRING_DIR="/etc/apt/keyrings"
PBS_LIST_FILE="/etc/apt/sources.list.d/pbs-client.list"

if [[ "${EUID}" -ne 0 ]]; then
  err "Run this installer as root."
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  err "Cannot detect OS: /etc/os-release is missing."
  exit 1
fi

# shellcheck source=/etc/os-release
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  err "Unsupported OS: ${ID:-unknown}. This installer currently supports Ubuntu LTS only."
  exit 1
fi

case "${VERSION_ID:-}" in
  22.04|24.04|26.04)
    ;;
  *)
    err "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Supported: 22.04, 24.04, 26.04."
    exit 1
    ;;
esac

if [[ "${VERSION_ID}" == "22.04" ]]; then
  PBS_CLIENT_PACKAGE_DEFAULT="proxmox-backup-client-static"
else
  PBS_CLIENT_PACKAGE_DEFAULT="proxmox-backup-client"
fi

PBS_CLIENT_PACKAGE="${PBS_CLIENT_PACKAGE:-$PBS_CLIENT_PACKAGE_DEFAULT}"

PBS_CLIENT_SUITE="${PBS_CLIENT_SUITE:-bookworm}"
PBS_KEY_SUITE="${PBS_KEY_SUITE:-bookworm}"
KEYRING_FILE="${KEYRING_DIR}/proxmox-release-${PBS_KEY_SUITE}.gpg"
PBS_APT_BASE_URL="${PBS_APT_BASE_URL:-https://download.proxmox.com}"

select_repo_base_url() {
  local suite="$1"
  local preferred_base="$2"
  local candidates=()
  local base

  candidates+=("${preferred_base}")
  if [[ "${preferred_base}" != "https://download.proxmox.com" ]]; then
    candidates+=("https://download.proxmox.com")
  fi
  if [[ "${preferred_base}" != "http://download.proxmox.com" ]]; then
    candidates+=("http://download.proxmox.com")
  fi

  for base in "${candidates[@]}"; do
    if curl -fsSIL "${base}/debian/pbs-client/dists/${suite}/Release" >/dev/null; then
      PBS_APT_BASE_URL="$base"
      return 0
    fi
  done

  return 1
}

download_release_key() {
  local key_suite="$1"
  local base="$2"

  if curl -fsSL "${base}/debian/proxmox-release-${key_suite}.gpg" -o "$KEYRING_FILE"; then
    return 0
  fi

  # Some networks break TLS for download.proxmox.com; fallback to HTTP when needed.
  if [[ "$base" == "https://download.proxmox.com" ]]; then
    if curl -fsSL "http://download.proxmox.com/debian/proxmox-release-${key_suite}.gpg" -o "$KEYRING_FILE"; then
      PBS_APT_BASE_URL="http://download.proxmox.com"
      warn "HTTPS to download.proxmox.com failed; using HTTP mirror bootstrap."
      return 0
    fi
  fi

  return 1
}

step "[1/6] Configuring Proxmox PBS client APT repository for Ubuntu ${VERSION_ID} (suite ${PBS_CLIENT_SUITE})"
install -d -m 0755 "$KEYRING_DIR"

if ! select_repo_base_url "$PBS_CLIENT_SUITE" "$PBS_APT_BASE_URL"; then
  err "Failed to find reachable Proxmox repo for suite '${PBS_CLIENT_SUITE}'."
  echo "You can override with PBS_APT_BASE_URL=<base-url> and PBS_CLIENT_SUITE=<suite>." >&2
  exit 1
fi

if ! download_release_key "$PBS_KEY_SUITE" "$PBS_APT_BASE_URL"; then
  err "Failed to download Proxmox release key for key suite '${PBS_KEY_SUITE}'."
  echo "You can override with PBS_KEY_SUITE=<suite> and PBS_APT_BASE_URL=<base-url>." >&2
  exit 1
fi
chmod 0644 "$KEYRING_FILE"

echo "Using Proxmox APT base URL: ${PBS_APT_BASE_URL}"
echo "deb [signed-by=${KEYRING_FILE}] ${PBS_APT_BASE_URL}/debian/pbs-client ${PBS_CLIENT_SUITE} main" > "$PBS_LIST_FILE"

apt-get update

if ! apt-get -s install "$PBS_CLIENT_PACKAGE" >/dev/null 2>&1; then
  err "${PBS_CLIENT_PACKAGE} is not installable with current distro/suite settings."
  echo "Host: Ubuntu ${VERSION_ID}; Suite: ${PBS_CLIENT_SUITE}; Base URL: ${PBS_APT_BASE_URL}" >&2
  echo "Adjust overrides: PBS_CLIENT_PACKAGE / PBS_CLIENT_SUITE / PBS_KEY_SUITE / PBS_APT_BASE_URL" >&2
  exit 1
fi

echo "Installing package: ${PBS_CLIENT_PACKAGE}"
apt-get install -y "$PBS_CLIENT_PACKAGE"

step "[2/6] Installing backup suite into ${TARGET_DIR}"
install -d -m 0755 "$TARGET_DIR"
install -d -m 0755 "${TARGET_DIR}/pre-backup.d"
install -d -m 0755 "${TARGET_DIR}/post-backup.d"

install -m 0755 "${SCRIPT_DIR}/run-backup.sh" "${TARGET_DIR}/run-backup.sh"
install -m 0755 "${SCRIPT_DIR}/restore.sh" "${TARGET_DIR}/restore.sh"
install -m 0755 "${SCRIPT_DIR}/uninstall.sh" "${TARGET_DIR}/uninstall.sh"
install -m 0755 "${SCRIPT_DIR}/upgrade.sh" "${TARGET_DIR}/upgrade.sh"
install -m 0755 "${SCRIPT_DIR}/pbs" "${TARGET_DIR}/pbs"
install -m 0644 "${SCRIPT_DIR}/config.example" "${TARGET_DIR}/config.example"
install -m 0755 "${SCRIPT_DIR}/pre-backup.d/10-marker.sh" "${TARGET_DIR}/pre-backup.d/10-marker.sh"
install -m 0755 "${SCRIPT_DIR}/post-backup.d/90-cleanup-dumps.sh" "${TARGET_DIR}/post-backup.d/90-cleanup-dumps.sh"
if [[ -f "${SCRIPT_DIR}/version" ]]; then
  install -m 0644 "${SCRIPT_DIR}/version" "${TARGET_DIR}/version"
fi

ln -sf "${TARGET_DIR}/pbs" /usr/local/bin/pbs

if [[ -f "${TARGET_DIR}/config" ]]; then
  step "[3/6] Preserving existing ${TARGET_DIR}/config"
else
  install -m 0600 "${SCRIPT_DIR}/config.example" "${TARGET_DIR}/config"
  step "[3/6] Created ${TARGET_DIR}/config from template (edit with real credentials)"
fi

step "[4/6] Installing systemd units"
install -m 0644 "${SCRIPT_DIR}/deploy/pbs-backup.service" "/etc/systemd/system/pbs-backup.service"
install -m 0644 "${SCRIPT_DIR}/deploy/pbs-backup.timer" "/etc/systemd/system/pbs-backup.timer"

systemctl daemon-reload

step "[5/6] Enabling timer"
systemctl enable --now pbs-backup.timer

ok "[6/6] Install complete"
cat <<EOF
${C_BOLD}Next steps:${C_RESET}
1. Edit /etc/pbs-backup/config and set PBS_REPOSITORY, PBS_PASSWORD, PBS_FINGERPRINT.
2. Run a connectivity smoke test backup:
   proxmox-backup-client backup etc.pxar:/etc
3. Run a full backup manually once:
   ${C_CYAN}pbs run-backup${C_RESET}
4. Check logs:
   journalctl -t pbs-backup -n 200 --no-pager

The '${C_CYAN}pbs${C_RESET}' command is now on your PATH (run-backup, restore, upgrade, uninstall).
EOF
