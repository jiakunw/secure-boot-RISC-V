#!/usr/bin/env bash
# Build the version-tampered SoC for test_tempering_version:
#   1. Build regular BootROM + kernel + recovery via the main integrate script
#   2. Generate the TAMPERED manifest (VERSION=1) via this test's
#      manifest_generators.py (output to tempered_flash_image/)
#   3. Sign + assemble tempered flash_image.bin / .hex
#   4. Stage the tempered hex under $CHIPYARD/sims/verilator/tempered_rollback_flash_image/
#   5. Symlink TamperedRollbackSecureBootConfig.scala into chipyard
#   6. Build Verilator with CONFIG=TamperedRollbackSecureBootConfig
#
# The main repo tree is NOT modified by this script. Only changes:
#   - inside $CHIPYARD_HOME (which is regenerated each build anyway):
#     one symlink + one tempered hex file + one extra simulator binary
#   - inside this test dir: tempered_flash_image/* artifacts
# The regular SecureBootConfig and TemperedSecureBootConfig sim binaries
# are untouched.

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
CHIPYARD_TEMPERED_DIR="$CHIPYARD_HOME/sims/verilator/tempered_rollback_flash_image"

echo "════════════════════════════════════════════════════════════════"
echo "  Building TamperedRollbackSecureBootConfig negative test"
echo "════════════════════════════════════════════════════════════════"

# 1. Regular BootROM + kernel + recovery (uses main software/, no tampering here)
echo
echo "[1/6] Building regular bootrom + kernel + recovery via main integrate script"
bash "$REPO/scripts/integrate_to_chipyard.sh" | tail -8

# 2. Tampered manifest (VERSION=1)
echo
echo "[2/6] Running tampered manifest_generators.py (VERSION=1)"
mkdir -p "$TEMPERED_DIR"
python3 "$TOOLS_DIR/manifest_generators.py"

# 3. Sign tampered manifest + assemble flash_image.bin
echo
echo "[3/6] Signing tampered manifest + assembling tempered flash_image.bin"
python3 "$TOOLS_DIR/sign_firmware.py"

# 4. Convert tempered flash_image.bin → flash_image.hex
echo
echo "[4/6] Converting tempered flash_image.bin → flash_image.hex"
python3 "$REPO/tools/flash_image_to_hex.py" \
    --input  "$TEMPERED_DIR/flash_image.bin" \
    --output "$TEMPERED_DIR/flash_image.hex"

# 5. Stage tempered hex under Verilator working dir (path matches the
#    imageHexFile field in TamperedRollbackSecureBootConfig.scala)
echo
echo "[5/6] Staging tempered hex under \$CHIPYARD_HOME/sims/verilator/tempered_rollback_flash_image/"
mkdir -p "$CHIPYARD_TEMPERED_DIR"
cp "$TEMPERED_DIR/flash_image.hex" "$CHIPYARD_TEMPERED_DIR/"

# 6. Symlink the Scala config into chipyard + build Verilator
echo
echo "[6/6] Symlinking TamperedRollbackSecureBootConfig.scala + building Verilator"
SCALA_DEST="$CHIPYARD_HOME/generators/chipyard/src/main/scala/secureboot/TamperedRollbackSecureBootConfig.scala"
mkdir -p "$(dirname "$SCALA_DEST")"
ln -sf "$TEST_DIR/TamperedRollbackSecureBootConfig.scala" "$SCALA_DEST"

# Force re-elaboration so the parameter override (resetValue=5 on the
# rollback counter peripheral) takes effect.
touch "$REPO/hardware/secureboot/SecureBootConfig.scala"
cd "$CHIPYARD_HOME/sims/verilator"
make -j"$(nproc)" CONFIG=TamperedRollbackSecureBootConfig 2>&1 | tail -5

echo
echo "════════════════════════════════════════════════════════════════"
echo "  Build complete."
echo "════════════════════════════════════════════════════════════════"
echo "  Sim binary:        $CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-TamperedRollbackSecureBootConfig"
echo "  Tempered hex:      $CHIPYARD_TEMPERED_DIR/flash_image.hex"
echo "  Config (symlink):  $SCALA_DEST"
echo
echo "  To run the test:   bash $TEST_DIR/run.sh"
echo "════════════════════════════════════════════════════════════════"
