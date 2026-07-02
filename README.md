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
- `uninstall.sh` - Removes what install.sh added, with opt-in flags for deeper cleanup.
- `restore.sh` - Snapshot list/mount/unmount and manual-package replay helper.
- `upgrade.sh` - Syncs installed suite files/systemd units to match this checkout.
- `pbs` - Command dispatcher (`pbs run-backup|restore|upgrade|uninstall`); symlinked onto PATH by install.sh.
- `version` - Suite version; compared against `/etc/pbs-backup/version` by upgrade.sh.

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
2. Adds the PBS client APT repo (default suite `bookworm`) and release key.
3. Installs `proxmox-backup-client-static` on Ubuntu 22.04, otherwise `proxmox-backup-client`.
4. Installs files into `/etc/pbs-backup`, including `restore.sh`, `uninstall.sh`,
   and `upgrade.sh` themselves — the VM is self-contained afterwards and
   doesn't depend on this checkout sticking around.
5. Preserves existing `/etc/pbs-backup/config`.
6. Installs and enables `pbs-backup.timer`.

Overrides (if needed):

```bash
PBS_CLIENT_SUITE=bookworm ./install.sh
PBS_KEY_SUITE=bookworm ./install.sh
PBS_APT_BASE_URL=http://download.proxmox.com ./install.sh
PBS_CLIENT_PACKAGE=proxmox-backup-client-static ./install.sh
```

Note: in some networks, HTTPS to `download.proxmox.com` may fail due certificate/hostname issues.
The installer probes endpoints and can fall back to the HTTP mirror URL if needed.

Ubuntu 22.04 note:

- Dynamic `proxmox-backup-client` may not resolve on Jammy due newer shared library requirements.
- The installer uses `proxmox-backup-client-static` by default on Jammy to avoid that dependency mismatch.

## The `pbs` command

`install.sh` deploys `pbs` to `/etc/pbs-backup/pbs` and symlinks it to
`/usr/local/bin/pbs`, so it's a normal command on any installed VM:

```bash
pbs run-backup            # run a backup now
pbs restore list           # ...and any other restore.sh subcommand
pbs uninstall --purge      # ...and any other uninstall.sh flag
pbs upgrade                 # fetch the latest suite from GitHub and upgrade
pbs upgrade --local <dir>   # upgrade from an existing checkout instead
```

`pbs upgrade` clones (or, if `git` isn't installed, downloads a tarball of)
`https://github.com/dopyrory3/pbs-backup` at ref `main` into a temp directory
under `/tmp`, prompts for confirmation before running anything (skip with
`-y`), then runs that checkout's `upgrade.sh` against this host. Override the
source with `PBS_UPGRADE_REPO` / `PBS_UPGRADE_REF` env vars, e.g. to pin a
tag or point at a fork. This downloads and executes code as root, so only
point it at a repo/ref you trust.

## Upgrade

`pbs upgrade` (above) is the normal path. To run `upgrade.sh` directly from
a checkout instead — for example while developing this repo — pull/checkout
the version of this repo you want to deploy, then run as root:

```bash
./upgrade.sh
```

This can also be run as `/etc/pbs-backup/upgrade.sh`, since install.sh deploys
it there — though it only ever syncs *from* whatever checkout you invoke it
from, so run it from an up-to-date checkout, not the installed copy, when
picking up a new version.

This compares this checkout's `version` file against `/etc/pbs-backup/version`
and, if they differ, re-syncs `run-backup.sh`, `config.example`, the repo's
`pre-backup.d`/`post-backup.d` hooks, and the systemd units from this
checkout into place, then reloads systemd. It does not touch
`/etc/pbs-backup/config`, the APT repo, or the installed
`proxmox-backup-client` package — rerun `install.sh` for those. Host-specific
hooks dropped into `pre-backup.d`/`post-backup.d` that aren't part of this
repo are left alone.

Options:

```bash
./upgrade.sh --force      # reinstall files even if versions already match
./upgrade.sh --no-backup  # skip backing up replaced files first
./upgrade.sh -y           # skip the confirmation prompt
```

Replaced files are backed up to a timestamped directory under
`/etc/pbs-backup/.upgrade-backups/` unless `--no-backup` is used.

## Uninstall

Run on a VM as root:

```bash
./uninstall.sh
```

Also available as `/etc/pbs-backup/uninstall.sh` on any installed VM.

By default this only removes what's safe to remove unconditionally: the
`pbs-backup.timer`/`pbs-backup.service` systemd units and the suite's own
scripts in `/etc/pbs-backup`. It preserves `/etc/pbs-backup/config`, package
manifests, and the dump directory.

Options:

```bash
./uninstall.sh --purge            # also remove config, manifests, and DUMP_DIR
./uninstall.sh --remove-package   # also apt-get remove proxmox-backup-client(-static)
./uninstall.sh --remove-repo      # also remove the PBS client APT repo and release key
./uninstall.sh -y                 # skip confirmation prompts
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

`restore.sh` wraps the common restore steps. It sources `/etc/pbs-backup/config`
for repository credentials, same as `run-backup.sh`. It's also available at
`/etc/pbs-backup/restore.sh` on any installed VM, so it works even without
this checkout present.

```bash
./restore.sh list                # list snapshots in the configured repository
./restore.sh mount                # pick a snapshot interactively, mount at /mnt/restore
./restore.sh mount <snapshot-id>  # mount a specific snapshot (as shown by `list`)
./restore.sh status               # check whether /mnt/restore is currently mounted
# Copy what you need from /mnt/restore
./restore.sh unmount              # unmount /mnt/restore
```

Interactive snapshot selection (`mount` with no snapshot argument) requires
`jq`; without it, use `list` and pass a snapshot ID to `mount` explicitly.

## Full VM loss runbook (file-level)

1. Provision fresh Ubuntu LTS VM.
2. Install this suite and `proxmox-backup-client`.
3. Restore required data from snapshot with `./restore.sh mount`.
4. Replay package manifests:

```bash
./restore.sh packages
```

This reinstalls packages listed in the mounted snapshot's (or local)
`manual-packages.txt`, prompting for confirmation first.

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
