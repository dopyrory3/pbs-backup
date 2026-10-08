# `pbs upgrade` fetch path, against a fake upstream git repo under $TEST_TMP.
# The fake upgrade.sh only records its args; the real one is never run.

# Keep git away from the user's and system config.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

UPSTREAM="${TEST_TMP}/upstream"
RECORD="${TEST_TMP}/upgrade.record"
export RECORD

# Fake upstream: each commit's upgrade.sh records "<version> <args>" and exits
# with $FAKE_UPGRADE_RC. v1 is tagged and kept as an older commit on main;
# a branch "next" carries v3.
_commit_version() {
  printf '%s\n' "$1" > "${UPSTREAM}/VERSION"
  git -C "$UPSTREAM" add -A
  git -C "$UPSTREAM" commit --quiet -m "$1"
}
git init --quiet -b main "$UPSTREAM"
cat > "${UPSTREAM}/upgrade.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(cat "$(dirname "$0")/VERSION") $*" > "$RECORD"
exit "${FAKE_UPGRADE_RC:-0}"
EOF
chmod +x "${UPSTREAM}/upgrade.sh"
_commit_version v1
git -C "$UPSTREAM" tag v1
V1_SHA="$(git -C "$UPSTREAM" rev-parse HEAD)"
_commit_version v2
git -C "$UPSTREAM" checkout --quiet -b next
_commit_version v3
git -C "$UPSTREAM" checkout --quiet main
# A file:// remote only serves unadvertised SHAs when this is set (GitHub
# allows it by default).
git -C "$UPSTREAM" config uploadpack.allowReachableSHA1InWant true

# Runs `pbs upgrade "$@"` with a fresh TMPDIR; sets $out and $rc.
run_upgrade() {
  rm -rf "${TEST_TMP}/tmp" "$RECORD"
  mkdir -p "${TEST_TMP}/tmp"
  rc=0
  out="$(TMPDIR="${TEST_TMP}/tmp" PBS_UPGRADE_REPO="file://${UPSTREAM}" \
    "$REPO_ROOT/pbs" upgrade "$@" 2>&1 < "${STDIN_FILE:-/dev/null}")" || rc=$?
}

assert_no_leak() {
  local left
  left="$(find "${TEST_TMP}/tmp" -maxdepth 1 -name 'pbs-upgrade.*')"
  [[ -z "$left" ]] || fail "temp dir left behind: ${left}"
}

recorded() { cat "$RECORD" 2>/dev/null; }

test_upgrade_success_exits_zero_and_cleans_up() {
  PBS_UPGRADE_REF=main run_upgrade -y
  assert_eq 0 "$rc" "exit code (output: ${out})"
  assert_eq "v2 -y" "$(recorded)" "upgrade.sh record"
  assert_no_leak
}

test_upgrade_failure_propagates_and_cleans_up() {
  FAKE_UPGRADE_RC=7 PBS_UPGRADE_REF=main run_upgrade -y
  assert_eq 7 "$rc" "exit code (output: ${out})"
  assert_eq "v2 -y" "$(recorded)" "upgrade.sh record"
  assert_no_leak
}

test_upgrade_branch_ref() {
  PBS_UPGRADE_REF=next run_upgrade -y
  assert_eq 0 "$rc" "exit code (output: ${out})"
  assert_eq "v3 -y" "$(recorded)" "upgrade.sh record"
  assert_no_leak
}

test_upgrade_tag_ref() {
  PBS_UPGRADE_REF=v1 run_upgrade -y
  assert_eq 0 "$rc" "exit code (output: ${out})"
  assert_eq "v1 -y" "$(recorded)" "upgrade.sh record"
  assert_no_leak
}

test_upgrade_commit_sha_ref() {
  PBS_UPGRADE_REF="$V1_SHA" run_upgrade -y
  assert_eq 0 "$rc" "exit code (output: ${out})"
  assert_eq "v1 -y" "$(recorded)" "upgrade.sh record"
  assert_no_leak
}

test_upgrade_yes_passes_args_through() {
  PBS_UPGRADE_REF=main run_upgrade --force -y --extra
  assert_eq 0 "$rc" "exit code (output: ${out})"
  assert_eq "v2 --force -y --extra" "$(recorded)" "upgrade.sh record"
  [[ "$out" == *"Continue?"* ]] && fail "-y should skip the prompt"
  assert_no_leak
}

test_upgrade_prompt_yes_runs() {
  printf 'y\n' > "${TEST_TMP}/stdin"
  STDIN_FILE="${TEST_TMP}/stdin" PBS_UPGRADE_REF=main run_upgrade --force
  assert_eq 0 "$rc" "exit code (output: ${out})"
  assert_eq "v2 --force" "$(recorded)" "upgrade.sh record"
  assert_no_leak
}

test_upgrade_prompt_declined_aborts() {
  printf 'n\n' > "${TEST_TMP}/stdin"
  STDIN_FILE="${TEST_TMP}/stdin" PBS_UPGRADE_REF=main run_upgrade
  assert_eq 0 "$rc" "exit code"
  assert_contains "$out" "Aborted."
  assert_no_file "$RECORD"
  assert_no_leak
}
