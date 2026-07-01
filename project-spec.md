# Project: PBS Backup Client Suite

## Goal
A generic, hook-based backup script suite deployed identically across ~10 Ubuntu LTS
Linux VMs in Azure, pushing file-level backups to a self-hosted Proxmox Backup Server
(PBS) over a private network path. The same code deploys to every VM; the only
per-VM artifact is a credentials/config file.

## Non-goals
- No Docker/container backup logic (container workloads live on AKS; out of scope).
- No database dump hooks yet (postgres/mysql/mongodb deferred). The hook mechanism
  is validated now with a trivial marker hook; real DB hooks slot in later with no
  runner changes.
- No image/block-level or bare-metal restore. This is file + config backup only.
  VM loss recovery = reprovision OS, reinstall packages, restore data.
- No config-management layer, no DSL, no central orchestrator. Keep it proportionate:
  bash + systemd. Deploy is manual or via simple push (scp/ansible ad-hoc).

## Architecture

/etc/pbs-backup/
├── config                  # per-VM: PBS repo, token secret, fingerprint, overrides
├── config.example          # committed template with placeholders
├── run-backup.sh           # generic runner — identical on every VM
├── pre-backup.d/           # hooks run BEFORE backup, in filename (numeric) order
│   └── 10-marker.sh        # trivial validation hook (proves the mechanism)
└── post-backup.d/          # cleanup hooks run AFTER backup
    └── 90-cleanup-dumps.sh

## Components

### run-backup.sh (the generic runner)
- `set -euo pipefail`, but hook failures must NOT abort the whole run — a failing
  hook should log a warning and still let the file backup proceed.
- Source `/etc/pbs-backup/config`.
- Export PBS_REPOSITORY, PBS_PASSWORD, PBS_FINGERPRINT from config.
- Capture package manifest into /etc so it rides along in the backup:
    - `apt-mark showmanual > /etc/pbs-backup/manual-packages.txt`
    - `dpkg --get-selections > /etc/pbs-backup/package-selections.txt`
- Run all executable `pre-backup.d/*.sh` in sorted order (log each; continue on error).
- Run the proxmox-backup-client backup of `root.pxar:/` with the standard exclude list
  (see below). Allow extra excludes to be appended from config ($EXTRA_EXCLUDES array).
- Run all executable `post-backup.d/*.sh` in sorted order. Pass the backup result to
  post hooks via env var $PBS_BACKUP_RESULT=success|fail.
- Log everything to journald via `logger -t pbs-backup` AND stdout. Every run emits a
  clear start line, per-hook lines, the backup result, and a final greppable
  success/fail summary line.
- Exit non-zero if the proxmox-backup-client backup itself failed (so the systemd
  timer/OnFailure can catch it), but not merely because a hook warned.

### Standard exclude list (universal, same on every VM)
/proc /sys /dev /run /tmp /var/tmp /var/cache /lost+found /mnt /media
/var/lib/proxmox-backup /swap.img and *.swp
Plus any paths in $EXTRA_EXCLUDES from config.
Also support per-directory `.pxarexclude` files (native to proxmox-backup-client) —
document this in the README as the per-VM override mechanism that needs no code change.

### pre-backup.d/10-marker.sh (validation hook)
Purpose: validate the hook mechanism end-to-end without building real DB logic.
Exercises the same machinery a future DB hook will use (runs in pre-backup.d, writes
into $DUMP_DIR, logs to journald, output gets swept into root.pxar).

Behaviour:
- `DUMP_DIR="${DUMP_DIR:-/var/backups/pbs-dumps}"`, `mkdir -p`.
- Write `$DUMP_DIR/backup-marker.txt` containing: timestamp (`date -Is`), hostname,
  kernel (`uname -r`), uptime.
- Also append one line to `$DUMP_DIR/hook-order.log`:
  `"$(date -Is) $(basename "$0") ran"` — so multi-hook ordering can be verified later
  by dropping in additional numbered marker hooks.
- `logger -t pbs-backup` a confirmation line.
This is a real, restorable artifact: after a backup, mounting the snapshot and reading
backup-marker.txt should show a timestamp from THIS run — proving hook-ran-before-capture.

### post-backup.d/90-cleanup-dumps.sh
- Remove marker/dump files from $DUMP_DIR after a SUCCESSFUL backup (they're already
  captured), to avoid leaving stale files on disk. Only clean if $PBS_BACKUP_RESULT
  is success. (Keeping hook-order.log is fine, or clean it too — document the choice.)

### config / config.example
Shell-sourced. Contains:
- PBS_REPOSITORY='root@pam!<token-name>@<PBS-PRIVATE-IP>:store1'
- PBS_PASSWORD='<token-secret>'
- PBS_FINGERPRINT='<sha256>'
- DUMP_DIR (optional, default /var/backups/pbs-dumps)
- EXTRA_EXCLUDES (optional bash array)
config.example has placeholders and is committed; real config is 0600, git-ignored.

### systemd units (deploy/ dir)
- `pbs-backup.service` (Type=oneshot, runs run-backup.sh, User=root).
- `pbs-backup.timer` (daily, with RandomizedDelaySec to stagger the 10 VMs so they
  don't all hit PBS at once; Persistent=true to catch missed runs).
- OnFailure wiring or documented failure surfacing (journald tag + optional
  email/webhook — keep the hook, leave endpoint as TODO).

### install.sh
Idempotent single-VM installer:
- Adds the pbs-client apt repo + key from download.proxmox.com (default suite: bookworm,
  with override support via environment variables).
- `apt install proxmox-backup-client`.
- Copies /etc/pbs-backup/ tree, sets perms (config 0600, *.sh 0755).
- Installs + enables the systemd timer.
- Does NOT overwrite an existing config file if present.
- Prints next steps (edit config, run a manual test).

## Testing / acceptance
- Documented manual first-run: back up `etc.pxar:/etc` only, to prove
  connectivity/auth/TLS before the full root backup.
- Marker-hook validation: run a full backup, then mount the snapshot and confirm
  `backup-marker.txt` shows a timestamp from the just-completed run:
    proxmox-backup-client mount <snapshot-id> root.pxar /mnt/restore
    cat /mnt/restore/var/backups/pbs-dumps/backup-marker.txt
    proxmox-backup-client unmount /mnt/restore
  This proves: runner found hook → executed it → hook wrote file → backup captured
  fresh file → restore retrieves it.
- README: how to verify a snapshot (`snapshot list`), how to mount+restore, and the
  full-VM-loss recovery runbook (provision fresh Ubuntu LTS → install client → restore →
  replay manual-packages.txt → restore data → restore selective /etc, leaving
  fstab/network/machine-id/ssh host keys freshly generated).

## Constraints & conventions
- Target: Ubuntu LTS hosts with proxmox-backup-client from pbs-client repo.
  For Ubuntu 22.04, use proxmox-backup-client-static to avoid shared-library dependency mismatch.
- Bash, shellcheck-clean.
- No secrets in logs. No secrets committed. Secrets are 0600 files only.
- Every script logs to `logger -t pbs-backup`.
- Keep it small and readable — 6-month interim, not a product.
- Design invariant: hooks are SELF-CONTAINED and discovered by directory scan. The
  runner must never hardcode hook names or per-VM logic — dropping a new numbered
  script into pre-backup.d/ is the only way hooks are added. (This is what lets the
  full suite deploy identically to all 10 VMs.)

## Deliverables
1. run-backup.sh
2. pre-backup.d/10-marker.sh
3. post-backup.d/90-cleanup-dumps.sh
4. config.example
5. deploy/pbs-backup.{service,timer}
6. install.sh
7. README.md (setup, per-VM config, testing, marker validation, restore runbook,
   package-manifest replay)
8. .gitignore (ignore real config, dumps)