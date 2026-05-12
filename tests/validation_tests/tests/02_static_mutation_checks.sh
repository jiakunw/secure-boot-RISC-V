#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
LOG_DIR="$REPO/tests/validation_tests/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/02_static_mutation_checks.log"
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BASE="$TMP/base_repo"
CASE="$TMP/repo_case"

make_base_copy() {
    rm -rf "$BASE"
    cp -a "$REPO" "$BASE"
    rm -rf "$BASE/.git" "$BASE/validation_tests/logs"
    # Build a fresh flash image in the base copy once. Each mutation starts from this clean base.
    (cd "$BASE/tools" && python3 sign_firmware.py >/dev/null)
    python3 "$BASE/tools/flash_image_to_hex.py" \
        --input "$BASE/flash_image/flash_image.bin" \
        --output "$BASE/flash_image/flash_image.hex" >/dev/null
}

make_case_copy() {
    rm -rf "$CASE"
    cp -a "$BASE" "$CASE"
}

run_expect_fail() {
    local name="$1"
    shift
    make_case_copy
    echo
    echo "-- $name --"
    (cd "$CASE" && "$@")
    if python3 "$CASE/validation_tests/tools/image_tool.py" --repo "$CASE" check-artifacts >/tmp/vt_static_check.out 2>&1; then
        echo "FAIL: artifact checker accepted bad case: $name"
        cat /tmp/vt_static_check.out
        return 1
    else
        echo "PASS: artifact checker rejected bad case: $name"
        grep -E "FAIL:|SUMMARY:" /tmp/vt_static_check.out || true
    fi
}

{
    echo "== static mutation checks =="
    echo "These do not run the CPU. They prove the artifact checker catches bad generated files."
    echo "Each case starts from a freshly signed temp copy so stale repo artifacts do not hide the specific failure."
    make_base_copy

    run_expect_fail "manifest magic byte changed" \
        python3 validation_tests/tools/image_tool.py --repo . patch-flash-byte --offset 0x0 --xor 0xff

    run_expect_fail "public key byte changed in flash" \
        python3 validation_tests/tools/image_tool.py --repo . patch-flash-byte --offset 0xa5 --xor 0xff

    run_expect_fail "kernel byte changed in flash" \
        python3 validation_tests/tools/image_tool.py --repo . patch-flash-byte --offset 0xc0 --xor 0xff

    run_expect_fail "manifest payload_size changed without rebuilding flash/signature" \
        python3 validation_tests/tools/image_tool.py --repo . patch-manifest-field --field payload_size --value 0
} 2>&1 | tee "$LOG"
