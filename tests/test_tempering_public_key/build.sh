#!/usr/bin/env bash
# Build the tampered-pubkey flash image for the test_tempering_public_key
# negative test. ONE-TIME setup — output is checked into the repo at
# tempered_pubkey_flash_image/ and consumed by README's run instructions.
#
# This script does NOT modify the main repo state:
#   - metadata/* read-only
#   - flash_image/* not touched
#   - software/* not touched
# The only outputs are this directory's tempered_pubkey_flash_image/{public_key.bin,
# flash_image.bin, flash_image.hex}.
#
# To install/refresh the tampered hex into Chipyard's Verilator working
# directory, see README.md (one cp command).

set -e
set -o pipefail
# Not using `set -u`: Chipyard's conda activate scripts reference some
# BACKUP_* variables that may be unset on first activation.

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../.." && pwd)
export CONDA_BACKUP_RISCV=${CONDA_BACKUP_RISCV:-}
source "$REPO/.env"
source "$CHIPYARD_HOME/env.sh"

TOOLS_DIR="$TEST_DIR/tools"
TEMPERED_DIR="$TEST_DIR/tempered_flash_image"

echo "════════════════════════════════════════════════════════════════"
echo "  Building tampered pubkey artifacts for test_tempering_public_key"
echo "════════════════════════════════════════════════════════════════"

# 1) Tamper pubkey + reassemble flash_image.bin
echo
echo "[1/2] Running tamper_pubkey.py"
mkdir -p "$TEMPERED_DIR"
python3 "$TOOLS_DIR/tamper_pubkey.py"

# 2) Convert tampered flash_image.bin → flash_image.hex
echo
echo "[2/2] Converting tampered flash_image.bin → flash_image.hex"
python3 "$REPO/tools/flash_image_to_hex.py" \
    --input  "$TEMPERED_DIR/flash_image.bin" \
    --output "$TEMPERED_DIR/flash_image.hex"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  Build complete. Tampered artifacts:"
echo "════════════════════════════════════════════════════════════════"
ls -la "$TEMPERED_DIR"
echo
echo "  To run the test, see README.md."
