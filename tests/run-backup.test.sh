# Behaviour tests for run-backup.sh. Everything (config, hooks, manifests,
# lock, dump dir) lives under $TEST_TMP; external commands are stubbed.

CASE="${TEST_TMP}/case"

# Fresh config, hooks and stubs for each test.
setup() {
  rm -rf "$CASE"
  mkdir -p "$CASE/etc/pre-backup.d" "$CASE/etc/post-backup.d" "$CASE/dumps"
  cat > "$CASE/etc/config" <<'EOF'
PBS_REPOSITORY="user@pbs@localhost:store"
PBS_PASSWORD="secret"
PBS_FINGERPRINT="00:11"
EXTRA_EXCLUDES=(/srv/scratch "/home/*/.cache")
EOF
  printf '#!/usr/bin/env bash\necho "pre" >> "%s/hooks.log"\n' "$CASE" > "$CASE/etc/pre-backup.d/10-pre.sh"
  printf '#!/usr/bin/env bash\necho "post result=${PBS_BACKUP_RESULT}" >> "%s/hooks.log"\n' "$CASE" > "$CASE/etc/post-backup.d/10-post.sh"
  chmod +x "$CASE"/etc/*-backup.d/*.sh

  stub logger 'exit 0'
  stub apt-mark 'echo "fake-manual-pkg"'
  stub dpkg 'echo "fake-pkg install"'
  # Records each call's args. Fails if $CASE/backup-fail exists. If
  # $CASE/backup-block exists, signals "started" and waits for "release".
  stub proxmox-backup-client "
printf '%s\n' \"\$*\" >> '$CASE/backup-calls.log'
if [[ -e '$CASE/backup-block' ]]; then
  touch '$CASE/backup-started'
  for _ in \$(seq 200); do [[ -e '$CASE/backup-release' ]] && break; sleep 0.05; done
fi
[[ -e '$CASE/backup-fail' ]] && exit 1
exit 0"
}

run_backup() {
  PATH="${STUB_BIN}:${PATH}" \
    PBS_ETC_DIR="$CASE/etc" \
    PBS_LOCK_FILE="$CASE/pbs-backup.lock" \
    DUMP_DIR="$CASE/dumps" \
    "$REPO_ROOT/run-backup.sh" "$@"
}

# Poll up to ~10s for a file to appear.
wait_for_file() {
  local i
  for i in $(seq 200); do
    [[ -e "$1" ]] && return 0
    sleep 0.05
  done
  return 1
}

count_lines() {
  if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}

test_successful_run() {
  setup
  local out rc=0
  out="$(run_backup 2>&1)" || rc=$?
  assert_eq 0 "$rc" "exit code"
  assert_contains "$out" "PBS_BACKUP_SUMMARY=success"
  assert_eq "pre
post result=success" "$(cat "$CASE/hooks.log" 2>/dev/null)" "hook log"
  assert_eq 1 "$(count_lines "$CASE/backup-calls.log")" "backup calls"
  local args
  args="$(cat "$CASE/backup-calls.log" 2>/dev/null)"
  assert_contains "$args" "backup root.pxar:/ --exclude /proc --exclude /sys"
  assert_contains "$args" "--exclude *.swp --exclude /srv/scratch --exclude /home/*/.cache"
  assert_eq "fake-manual-pkg" "$(cat "$CASE/etc/manual-packages.txt" 2>/dev/null)" "manual manifest"
  assert_eq "fake-pkg install" "$(cat "$CASE/etc/package-selections.txt" 2>/dev/null)" "selections manifest"
}

test_failed_backup_exits_1() {
  setup
  touch "$CASE/backup-fail"
  local out rc=0
  out="$(run_backup 2>&1)" || rc=$?
  assert_eq 1 "$rc" "exit code"
  assert_contains "$out" "PBS_BACKUP_SUMMARY=fail"
  assert_contains "$(cat "$CASE/hooks.log" 2>/dev/null)" "post result=fail"
}

test_missing_config_exits_2() {
  setup
  rm -f "$CASE/etc/config"
  local out rc=0
  out="$(run_backup 2>&1)" || rc=$?
  assert_eq 2 "$rc" "exit code"
  assert_contains "$out" "Missing config file"
  assert_eq 0 "$(count_lines "$CASE/backup-calls.log")" "backup calls"
}

test_concurrent_run_exits_3() {
  setup
  touch "$CASE/backup-block"
  run_backup > "$CASE/first.out" 2>&1 &
  local first_pid=$!
  if ! wait_for_file "$CASE/backup-started"; then
    fail "first run never reached the backup step"
    touch "$CASE/backup-release"; wait "$first_pid"
    return
  fi
  # Only the first run's backup should block; without a lock a second run
  # would sail through instead of hanging.
  rm -f "$CASE/backup-block"
  local hooks_before out rc=0
  hooks_before="$(cat "$CASE/hooks.log" 2>/dev/null)"
  out="$(run_backup 2>&1)" || rc=$?
  assert_eq 3 "$rc" "second run exit code"
  assert_contains "$out" "already running"
  assert_eq 1 "$(count_lines "$CASE/backup-calls.log")" "backup calls while locked"
  assert_eq "$hooks_before" "$(cat "$CASE/hooks.log" 2>/dev/null)" "hooks run by second run"

  touch "$CASE/backup-release"
  local first_rc=0
  wait "$first_pid" || first_rc=$?
  assert_eq 0 "$first_rc" "first run exit code"

  rc=0
  run_backup >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "run after lock released"
  assert_eq 2 "$(count_lines "$CASE/backup-calls.log")" "backup calls after release"
}

test_hook_daemon_does_not_hold_lock() {
  setup
  # A hook that leaves a long-lived process behind (e.g. restarting a daemon)
  # must not inherit the lock fd, or every later run would exit 3.
  printf '#!/usr/bin/env bash\nsleep 30 >/dev/null 2>&1 &\necho $! > "%s/daemon.pid"\n' "$CASE" \
    > "$CASE/etc/post-backup.d/20-daemon.sh"
  chmod +x "$CASE/etc/post-backup.d/20-daemon.sh"

  local rc=0
  run_backup >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "first run exit code"

  rm -f "$CASE/etc/post-backup.d/20-daemon.sh"
  rc=0
  run_backup >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "run while hook's background process is alive"

  [[ -f "$CASE/daemon.pid" ]] && kill "$(cat "$CASE/daemon.pid")" 2>/dev/null
  true
}
