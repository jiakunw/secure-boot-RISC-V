#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERROR: do not source this script."
  echo "Run it with:"
  echo "  bash scripts/hard_rebuild_secureboot.sh"
  return 1
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHIPYARD_HOME="${CHIPYARD_HOME:-/root/chipyard}"
CONFIG="${CONFIG:-SecureBootConfig}"

echo "============================================================"
echo "Hard secure-boot rebuild"
echo "repo:     $REPO"
echo "chipyard: $CHIPYARD_HOME"
echo "config:   $CONFIG"
echo "============================================================"

if [ ! -f "$CHIPYARD_HOME/env.sh" ]; then
  echo "ERROR: missing Chipyard env.sh at $CHIPYARD_HOME/env.sh"
  exit 1
fi

set +u
source "$CHIPYARD_HOME/env.sh"
set -u

export CHIPYARD_HOME
export SECURE_BOOT_REPO="$REPO"

cd "$REPO"

echo ""
echo "[1] delete repo-generated artifacts"

rm -f software/bootrom/*.o
rm -f software/bootrom/bootrom.elf
rm -f software/bootrom/bootrom.img
rm -f software/bootrom/bootrom.dump

rm -f software/kernel/*.o
rm -f software/kernel/*.elf
rm -f software/kernel/*.dump
rm -f software/kernel/kernel.riscv
rm -f software/kernel/kernel.bin

rm -f software/recovery/*.o
rm -f software/recovery/*.elf
rm -f software/recovery/*.dump
rm -f software/recovery/recovery.riscv

rm -f metadata/manifest.bin
rm -f metadata/signature.bin

rm -f flash_image/flash_image.bin
rm -f flash_image/flash_image.hex

rm -rf validation_results

echo ""
echo "[2] delete staged Chipyard artifacts"

rm -rf "$CHIPYARD_HOME/sims/verilator/flash_image"
rm -rf "$CHIPYARD_HOME/sims/verilator/generated-src/chipyard.harness.TestHarness.$CONFIG"
rm -f "$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-$CONFIG"
rm -f "$CHIPYARD_HOME/.classpath_cache/chipyard.jar"

rm -f "$CHIPYARD_HOME/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img"

echo ""
echo "[3] rebuild and stage secure-boot artifacts"

bash "$REPO/scripts/integrate_to_chipyard.sh"

echo ""
echo "[4] freshness check"

CHIPYARD_HOME="$CHIPYARD_HOME" "$REPO/scripts/check_secureboot_freshness.sh"

echo ""
echo "[5] build simulator"

cd "$CHIPYARD_HOME/sims/verilator"
make CONFIG="$CONFIG" -j"$(nproc)"

echo ""
echo "============================================================"
echo "Hard rebuild finished."
echo "Now run:"
echo "  cd $CHIPYARD_HOME/sims/verilator"
echo "  timeout 300 stdbuf -oL ./simulator-chipyard.harness-$CONFIG \\"
echo "    +payload=\"$REPO/software/recovery/recovery.riscv\" \\"
echo "    \"$REPO/software/kernel/kernel.riscv\""
echo "============================================================"
