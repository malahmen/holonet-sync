#!/usr/bin/env bash
# Run every tests/test-*.sh against the engine (or $HOLONET_SYNC) and exit
# non-zero if any of them fails. No network, no tokens.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
for t in "$TEST_DIR"/test-*.sh; do
    name=$(basename "$t")
    if out=$(bash "$t" 2>&1); then
        echo "PASS  ${name}"
    else
        echo "FAIL  ${name}"; grep -E '^ *FAIL' <<< "$out" | sed 's/^/        /'
        failed+=("$name")
    fi
done
echo
if (( ${#failed[@]} )); then echo "${#failed[@]} test file(s) failed: ${failed[*]}"; exit 1; fi
echo "all test files passed"
