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
# FESVR loads ONLY the first positional ELF (targs[0]). Extra ELFs must
# be passed via the `+payload=<path>` plusarg, which goes through FESVR's
# `payloads` list and gets loaded in addition to the primary kernel.
stdbuf -oL "$SIM" "+payload=$RECOVERY" "$KERNEL" > "$LOG" 2>&1
SIM_EXIT=$?
echo "sim exit code: $SIM_EXIT  (kernel-success path → 0; BootROM-tohost-exit path → reason_bit)"

echo
echo "── sim output ───────────────────────────────────────────────────"
cat "$LOG"
echo "─────────────────────────────────────────────────────────────────"

PASS=true
EVIDENCE=""

# Signal 1: kernel banner — must be ABSENT (BootROM rejected the image)
if grep -q "kernel started successfully" "$LOG"; then
    echo "FAIL: kernel banner present — Stage 0 (check_manifest_header) did NOT catch the tampered magic"
    PASS=false
else
    EVIDENCE="$EVIDENCE\n  ✓ kernel banner absent"
fi

# Signal 2: FESVR-reported exit code = reason_bit (BootROM's tohost-exit signal).
# SR_MANIFEST_HEADER = 1, so "exit code = 1" means Stage 0 caught the tamper.
# Note: Verilator's $stop returns host exit 255; the SoC-level exit code is in
# the SimTSI assertion line: "Assertion failed: *** FAILED *** (exit code = 1)".
if grep -qE "exit code =[[:space:]]+1\b" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ FESVR-reported exit code = 1 (= SR_MANIFEST_HEADER bit)"
fi

# Signal 3: recovery's own printout (best evidence, may not be visible)
if grep -q "check_manifest_header failed" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ recovery printed expected diagnostic"
fi

# Signal 4: SR readout in log
if grep -q "boot status register = 0x00000001" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ recovery confirmed SR = 0x00000001"
fi

if $PASS; then
    echo -e "PASS:$EVIDENCE"
    exit 0
else
    exit 1
fi
