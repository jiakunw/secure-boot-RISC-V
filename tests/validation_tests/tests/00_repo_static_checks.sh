#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
LOG_DIR="$REPO/tests/validation_tests/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/00_repo_static_checks.log"
{
    echo "== static artifact checks =="
    python3 "$REPO/tests/validation_tests/tools/image_tool.py" --repo "$REPO" inspect
    echo
    python3 "$REPO/tests/validation_tests/tools/image_tool.py" --repo "$REPO" check-artifacts
    echo
    echo "== host-side Ed25519 signature check =="
    python3 "$REPO/tools/verify_ed25519_from_files.py" \
        "$REPO/metadata/manifest.bin" \
        "$REPO/metadata/signature.bin" \
        "$REPO/metadata/public_key.bin"
    echo "PASS: metadata manifest/signature/public_key verifies with MonoCypher helper"
} 2>&1 | tee "$LOG"
