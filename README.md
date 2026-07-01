# PBS Backup Client Suite

Hook-based file backup suite for Ubuntu LTS VMs (22.04, 24.04, 26.04) using `proxmox-backup-client`.
The same code is deployed to every VM. Only `/etc/pbs-backup/config` is per-VM.

## Repository layout

- `run-backup.sh` - Generic backup runner.
- `pre-backup.d/10-marker.sh` - Validation hook that writes a fresh marker file.
- `post-backup.d/90-cleanup-dumps.sh` - Cleanup hook that removes marker file after successful backup.
- `config.example` - Template config with placeholders.
- `deploy/pbs-backup.service` - systemd oneshot service.
- `deploy/pbs-backup.timer` - Daily timer with randomized delay.
- `install.sh` - Idempotent installer for a single VM.

## Config file

The runner reads `/etc/pbs-backup/config` as a shell file.

Required values:

- `PBS_REPOSITORY='root@pam!<token-name>@<PBS-PRIVATE-IP>:store1'`
- `PBS_PASSWORD='<token-secret>'`
- `PBS_FINGERPRINT='<sha256-fingerprint>'`

Optional values:

- `DUMP_DIR='/var/backups/pbs-dumps'`
- `EXTRA_EXCLUDES=( '/path/one' '/path/two' )`

Security:

- Keep `/etc/pbs-backup/config` at mode `0600`.
- Do not commit real secrets.

## Install

Run on each Ubuntu LTS VM as root:

```bash
./install.sh
```

Installer actions:

1. Detects Ubuntu release and validates support (`22.04`, `24.04`, `26.04`).
2. Adds the matching PBS client APT repo and key for that Ubuntu codename.
3. Installs `proxmox-backup-client`.
4. Installs files into `/etc/pbs-backup`.
5. Preserves existing `/etc/pbs-backup/config`.
6. Installs and enables `pbs-backup.timer`.

If needed, override the suite used for the Proxmox repo/key:

```bash
PBS_CLIENT_SUITE=noble ./install.sh
```

## Backup behavior

`run-backup.sh` does the following:

1. Sources `/etc/pbs-backup/config`.
2. Exports `PBS_REPOSITORY`, `PBS_PASSWORD`, and `PBS_FINGERPRINT`.
3. Captures package manifests:
   - `apt-mark showmanual > /etc/pbs-backup/manual-packages.txt`
   - `dpkg --get-selections > /etc/pbs-backup/package-selections.txt`
4. Runs executable `pre-backup.d/*.sh` hooks in sorted order.
5. Runs `proxmox-backup-client backup root.pxar:/` with standard excludes plus `EXTRA_EXCLUDES`.
6. Runs executable `post-backup.d/*.sh` hooks in sorted order with `PBS_BACKUP_RESULT=success|fail`.
7. Emits clear summary lines to stdout and journald (`logger -t pbs-backup`).

Hook failures are logged as warnings and do not abort the backup run.
Only backup command failure causes non-zero exit.

## Standard excludes

Default excludes used by the runner:

- `/proc`
- `/sys`
- `/dev`
- `/run`
- `/tmp`
- `/var/tmp`
- `/var/cache`
- `/lost+found`
- `/mnt`
- `/media`
- `/var/lib/proxmox-backup`
- `/swap.img`
- `*.swp`

Per-VM fine-grained excludes can also be done with `.pxarexclude` files, natively supported by `proxmox-backup-client`.

## Marker hook validation

The pre-hook writes:

- `${DUMP_DIR}/backup-marker.txt` with timestamp, hostname, kernel, and uptime.
- `${DUMP_DIR}/hook-order.log` append-only hook execution line.

After a successful backup, the post-hook removes `backup-marker.txt` from local disk.
`hook-order.log` is intentionally kept for hook-order diagnostics.

Validation flow:

1. Run one full backup.
2. Mount snapshot and inspect marker file content from the snapshot:

```bash
proxmox-backup-client snapshot list
proxmox-backup-client mount <snapshot-id> root.pxar /mnt/restore
cat /mnt/restore/var/backups/pbs-dumps/backup-marker.txt
proxmox-backup-client unmount /mnt/restore
```

The timestamp should match the just-completed run.

## First-run smoke test (connectivity/auth/TLS)

Before full root backup, run a small test:

```bash
proxmox-backup-client backup etc.pxar:/etc
```

Then run:

```bash
/etc/pbs-backup/run-backup.sh
```

## Observability and failure checks

- Log tag: `pbs-backup`
- Last logs:

```bash
journalctl -t pbs-backup -n 200 --no-pager
```

- Service status:

```bash
systemctl status pbs-backup.service
systemctl list-timers pbs-backup.timer
```

## Restore basics

List snapshots:

```bash
proxmox-backup-client snapshot list
```

Mount and restore files:

```bash
mkdir -p /mnt/restore
proxmox-backup-client mount <snapshot-id> root.pxar /mnt/restore
# Copy what you need from /mnt/restore
proxmox-backup-client unmount /mnt/restore
```

## Full VM loss runbook (file-level)

1. Provision fresh Ubuntu LTS VM.
2. Install this suite and `proxmox-backup-client`.
3. Restore required data from snapshot.
4. Replay package manifests:

```bash
xargs -a /etc/pbs-backup/manual-packages.txt apt-get install -y
```

5. Restore selected `/etc` files only as needed.
6. Keep host-specific items fresh on rebuild:
   - `/etc/fstab`
   - network config
   - `/etc/machine-id`
   - SSH host keys

## Notes

- Keep hooks self-contained and discovered by directory scan.
- Do not hardcode hook names in the runner.
- Add new hooks by dropping numbered executable scripts into `pre-backup.d/` or `post-backup.d/`.
