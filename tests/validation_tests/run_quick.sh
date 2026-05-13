#!/usr/bin/env bash
# Bundle lives at $REPO/tests/validation_tests/ → go up 2 to reach repo root.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TESTS=(
  "$REPO/tests/validation_tests/tests/00_repo_static_checks.sh"
  "$REPO/tests/validation_tests/tests/01_source_policy_checks.sh"
  "$REPO/tests/validation_tests/tests/02_static_mutation_checks.sh"
  "$REPO/tests/validation_tests/tests/20_static_entry_point_gap.sh"
)
passed=0
total=0
failed=()
for t in "${TESTS[@]}"; do
  total=$((total+1))
  echo
  echo "============================================================"
  echo "RUNNING: ${t#$REPO/}"
  echo "============================================================"
  if bash "$t"; then
    echo "PASS: ${t#$REPO/}"
    passed=$((passed+1))
  else
    echo "FAIL: ${t#$REPO/}"
    failed+=("${t#$REPO/}")
  fi
done

echo
 echo "SUMMARY: $passed / $total passed"
if [ ${#failed[@]} -gt 0 ]; then
  printf 'FAILED TESTS:\n'
  printf '  - %s\n' "${failed[@]}"
  exit 1
fi
