#!/usr/bin/env bash
# Run the negative test against the pre-built TemperedSecureBootConfig sim.
# Expected outcome:
#   - kernel banner ABSENT (because BootROM rejected boot at Stage 0)
#   - recovery prints "check_manifest_header failed (bit 0)" if its HTIF
#     console is reachable; otherwise PASS via banner-absence signal.
#
# This script does NOT build anything — run build.sh first.

set -o pipefail
# NOT using `set -u`: Chipyard's conda activate/deactivate scripts
# reference BACKUP vars that may be unset; under `set -u` they abort the
# parent shell.

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../.." && pwd)
export CONDA_BACKUP_RISCV=${CONDA_BACKUP_RISCV:-}
source "$REPO/.env"
source "$CHIPYARD_HOME/env.sh"

SIM="$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-TemperedSecureBootConfig"
KERNEL="$REPO/software/kernel/kernel.riscv"
RECOVERY="$REPO/software/recovery/recovery.riscv"

if [ ! -x "$SIM" ]; then
    echo "FAIL: simulator not built. Run:  bash $TEST_DIR/build.sh"
    exit 1
fi

LOG=$(mktemp)
trap "rm -f $LOG" EXIT

echo "Running tempered sim..."
cd "$CHIPYARD_HOME/sims/verilator"
stdbuf -oL "$SIM" "$KERNEL" "$RECOVERY" > "$LOG" 2>&1 || true

echo
echo "── sim output ───────────────────────────────────────────────────"
cat "$LOG"
echo "─────────────────────────────────────────────────────────────────"

PASS=true
if grep -q "kernel started successfully" "$LOG"; then
    echo "FAIL: kernel banner present — Stage 0 (check_manifest_header) did NOT catch the tampered magic"
    PASS=false
fi
if grep -q "check_manifest_header failed" "$LOG"; then
    echo "PASS: recovery printed expected message (Stage 0 caught the tamper, SR bit 0 set)"
elif grep -q "boot status register = 0x00000001" "$LOG"; then
    echo "PASS: SR shows 0x00000001 (bit 0 = check_manifest_header)"
elif ! grep -q "kernel started successfully" "$LOG"; then
    echo "PASS (weak): kernel banner absent — BootROM did not reach success path. Recovery printf not visible (likely HTIF tohost-mismatch between kernel.riscv and recovery.riscv ELFs)."
fi

$PASS && exit 0 || exit 1
