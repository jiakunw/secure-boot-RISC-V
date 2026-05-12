#!/usr/bin/env bash
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TESTS=(
  "$REPO/validation_tests/tests/10_sim_positive_boot.sh"
  "$REPO/validation_tests/tests/11_sim_manifest_magic_bad.sh"
  "$REPO/validation_tests/tests/12_sim_header_version_bad.sh"
  "$REPO/validation_tests/tests/13_sim_public_key_flip.sh"
  "$REPO/validation_tests/tests/14_sim_public_key_zero.sh"
  "$REPO/validation_tests/tests/15_sim_signature_flip.sh"
  "$REPO/validation_tests/tests/16_sim_signature_zero.sh"
  "$REPO/validation_tests/tests/17_sim_kernel_byte_flip.sh"
  "$REPO/validation_tests/tests/18_sim_zero_payload_resigned.sh"
  "$REPO/validation_tests/tests/19_sim_bad_load_address_resigned.sh"
  "$REPO/validation_tests/tests/21_perf_positive_boot_timing.sh"
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
