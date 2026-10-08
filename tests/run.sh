#!/usr/bin/env bash
# Runs every tests/*.test.sh. The suite's scripts insist on root, so when not
# already root this re-execs inside an unprivileged user namespace
# (`unshare -r`), where EUID is 0 but nothing outside the test's own temp
# dirs is writable. Tests must still only touch paths under $TEST_TMP.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  if unshare -r true 2>/dev/null; then
    exec unshare -r "$0" "$@"
  fi
  echo "tests/run.sh: need root or unprivileged user namespaces (unshare -r)" >&2
  exit 1
fi

shopt -s nullglob
files=("$@")
[[ ${#files[@]} -eq 0 ]] && files=("${TESTS_DIR}"/*.test.sh)

failed=0
for f in "${files[@]}"; do
  echo "$(basename "$f")"
  if ! bash -c 'source "$1"; source "$2"; rc=0; run_tests || rc=1; rm -rf "$TEST_TMP"; exit $rc' \
      _ "${TESTS_DIR}/lib.sh" "$f"; then
    failed=1
  fi
done

if [[ $failed -ne 0 ]]; then
  echo "Some tests FAILED"
  exit 1
fi
echo "All tests passed"
