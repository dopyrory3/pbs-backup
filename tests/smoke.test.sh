# Sanity checks that every shipped script at least parses.

test_scripts_parse() {
  local f
  for f in "$REPO_ROOT"/pbs "$REPO_ROOT"/*.sh "$REPO_ROOT"/pre-backup.d/*.sh "$REPO_ROOT"/post-backup.d/*.sh; do
    bash -n "$f" 2>/dev/null || fail "syntax error in ${f#"$REPO_ROOT"/}"
  done
}

test_pbs_help() {
  local out
  out="$("$REPO_ROOT/pbs" help)"
  assert_contains "$out" "Usage:"
}

test_pbs_unknown_command_fails() {
  "$REPO_ROOT/pbs" bogus >/dev/null 2>&1 && fail "expected non-zero exit for unknown command"
  true
}
