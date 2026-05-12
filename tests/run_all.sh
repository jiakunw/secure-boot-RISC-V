#!/usr/bin/env bash
# Run all negative-test scenarios. Each test self-contained (tampers
# a byte, runs sim, restores originals via trap).

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS=$(find "$TESTS_DIR" -maxdepth 2 -name run.sh | sort)

TOTAL=0
PASSED=0
FAILED_TESTS=()

for s in $SCRIPTS; do
    name=$(basename "$(dirname "$s")")
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "  RUNNING: $name"
    echo "════════════════════════════════════════════════════════════════"
    TOTAL=$((TOTAL + 1))
    if bash "$s"; then
        echo
        echo "  → $name: PASS"
        PASSED=$((PASSED + 1))
    else
        echo
        echo "  → $name: FAIL"
        FAILED_TESTS+=("$name")
    fi
done

echo
echo "════════════════════════════════════════════════════════════════"
echo "  SUMMARY: $PASSED / $TOTAL passed"
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo "  Failed: ${FAILED_TESTS[*]}"
    exit 1
fi
echo "════════════════════════════════════════════════════════════════"
