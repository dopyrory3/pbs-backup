# Shared helpers for tests/*.test.sh. Sourced by tests/run.sh; each test file
# runs in its own bash process with these functions available.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Per-test-file scratch dir, removed by run.sh after the file finishes.
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pbs-test.XXXXXX")"
export TEST_TMP

_failures=0

fail() {
  echo "    FAIL: $*" >&2
  _failures=$((_failures + 1))
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  [[ "$expected" == "$actual" ]] || fail "${msg:+$msg: }expected '${expected}', got '${actual}'"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  [[ "$haystack" == *"$needle"* ]] || fail "${msg:+$msg: }expected output to contain '${needle}'; got: ${haystack}"
}

assert_file_exists() {
  [[ -e "$1" ]] || fail "expected file to exist: $1"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "expected file to be absent: $1"
}

# Put an executable stub named $1 with body $2 on a stub PATH dir. Use this to
# fake proxmox-backup-client, apt-mark, logger, etc. so nothing real runs.
STUB_BIN="${TEST_TMP}/bin"
mkdir -p "$STUB_BIN"
stub() {
  local name="$1" body="${2:-exit 0}"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "${STUB_BIN}/${name}"
  chmod +x "${STUB_BIN}/${name}"
}

# Run each function named test_* in this file, reporting pass/fail per test.
run_tests() {
  local t before
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    before=$_failures
    "$t"
    if [[ $_failures -eq $before ]]; then
      echo "  ok   $t"
    else
      echo "  FAIL $t"
    fi
  done
  [[ $_failures -eq 0 ]]
}
