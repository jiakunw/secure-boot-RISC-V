#!/usr/bin/env bash
# Build the tempered-firmware SoC for the negative test:
#   1. Build regular BootROM + kernel + recovery via the main integrate script
#   2. Generate the TAMPERED manifest using this test's tools/manifest_generators.py
#   3. Sign + assemble tampered flash_image.bin / .hex
#   4. Stage the tampered hex under $CHIPYARD/sims/verilator/tempered_flash_image/
#   5. Symlink TemperedSecureBootConfig.scala into chipyard's secureboot dir
#   6. Build Verilator with CONFIG=TemperedSecureBootConfig
#
# The main repo tree is NOT modified by this script. The only state
# changes are inside $CHIPYARD_HOME (which is regenerated each build
# anyway): one symlink + one tempered hex file + one extra simulator
# binary. The regular SecureBootConfig sim binary is untouched.

set -e
set -o pipefail
# Deliberately NOT using `set -u`: Chipyard's conda-env activation scripts
# (deactivate-riscv-tools.sh in particular) reference some BACKUP variables
# that may be unset on first activation, and `set -u` would abort here.

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../.." && pwd)
# Pre-define any conda BACKUP vars in case we're re-entering an env that
# was partially activated earlier in this shell.
export CONDA_BACKUP_RISCV=${CONDA_BACKUP_RISCV:-}
source "$REPO/.env"
source "$CHIPYARD_HOME/env.sh"

TOOLS_DIR="$TEST_DIR/tools"
TEMPERED_DIR="$TEST_DIR/tempered_flash_image"
CHIPYARD_TEMPERED_DIR="$CHIPYARD_HOME/sims/verilator/tempered_flash_image"

echo "════════════════════════════════════════════════════════════════"
echo "  Building TemperedSecureBootConfig negative test"
echo "════════════════════════════════════════════════════════════════"

# 1. Regular BootROM + kernel + recovery (uses main software/, no tampering here)
echo
echo "[1/6] Building regular bootrom + kernel + recovery via main integrate script"
bash "$REPO/scripts/integrate_to_chipyard.sh" | tail -8

# 2. Tampered manifest (bad magic)
echo
echo "[2/6] Running TAMPERED manifest_generators.py"
mkdir -p "$TEMPERED_DIR"
( cd "$TOOLS_DIR" && python3 manifest_generators.py )

# 3. Sign tampered manifest + assemble tampered flash_image.bin
echo
echo "[3/6] Signing tampered manifest + assembling tempered flash_image.bin"
( cd "$TOOLS_DIR" && python3 sign_firmware.py )

# 4. Convert tampered flash_image.bin → flash_image.hex
echo
echo "[4/6] Converting tempered flash_image.bin → flash_image.hex"
( cd "$TOOLS_DIR" && python3 flash_image_to_hex.py \
    --input  "$TEMPERED_DIR/flash_image.bin" \
    --output "$TEMPERED_DIR/flash_image.hex" )

# 5. Stage tempered hex under Verilator working dir
echo
echo "[5/6] Staging tempered hex under \$CHIPYARD_HOME/sims/verilator/tempered_flash_image/"
mkdir -p "$CHIPYARD_TEMPERED_DIR"
cp "$TEMPERED_DIR/flash_image.hex" "$CHIPYARD_TEMPERED_DIR/"

# 6. Symlink TemperedSecureBootConfig.scala into chipyard + build Verilator
echo
echo "[6/6] Symlinking TemperedSecureBootConfig.scala + building Verilator (CONFIG=TemperedSecureBootConfig)"
SCALA_DEST="$CHIPYARD_HOME/generators/chipyard/src/main/scala/secureboot/TemperedSecureBootConfig.scala"
mkdir -p "$(dirname "$SCALA_DEST")"
ln -sf "$TEST_DIR/TemperedSecureBootConfig.scala" "$SCALA_DEST"

# Force re-elaboration so the parameter override takes effect
touch "$REPO/hardware/secureboot/SecureBootConfig.scala"
cd "$CHIPYARD_HOME/sims/verilator"
make -j"$(nproc)" CONFIG=TemperedSecureBootConfig 2>&1 | tail -5

echo
echo "════════════════════════════════════════════════════════════════"
echo "  Build complete."
echo "════════════════════════════════════════════════════════════════"
echo "  Sim binary:        $CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-TemperedSecureBootConfig"
echo "  Tampered hex:      $CHIPYARD_TEMPERED_DIR/flash_image.hex"
echo "  Config (symlink):  $SCALA_DEST"
echo
echo "  To run the test:   bash $TEST_DIR/run.sh"
echo "════════════════════════════════════════════════════════════════"
