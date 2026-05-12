#!/usr/bin/env bash
# Build the tampered-kernel flash image for the test_tempering_kernel
# negative test. ONE-TIME setup — output is checked into the repo at
# tempered_flash_image/ and consumed by README's run instructions.
#
# This script does NOT modify the main repo state:
#   - metadata/* read-only
#   - flash_image/* not touched
#   - software/* not touched
# The only outputs are this directory's bad_kernel.{riscv,bin,dump} and
# tempered_flash_image/{flash_image.bin, flash_image.hex}.

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
echo "  Building tampered-kernel artifacts for test_tempering_kernel"
echo "════════════════════════════════════════════════════════════════"

# 1) Compile the malicious bad_kernel.c → bad_kernel.bin
echo
echo "[1/3] Compiling bad_kernel.c"
( cd "$TEST_DIR" && make clean && make 2>&1 | tail -5 )
ls -la "$TEST_DIR/bad_kernel.bin"

# 2) Assemble tampered flash_image.bin (manifest+sig+pubkey from main repo
#    + bad_kernel padded to manifest.payload_size)
echo
echo "[2/3] Running assemble_flash.py"
mkdir -p "$TEMPERED_DIR"
python3 "$TOOLS_DIR/assemble_flash.py"

# 3) Convert tampered flash_image.bin → flash_image.hex
echo
echo "[3/3] Converting tampered flash_image.bin → flash_image.hex"
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
