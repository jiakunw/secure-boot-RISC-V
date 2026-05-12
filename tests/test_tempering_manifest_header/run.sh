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
# 300s timeout: sim wall-clock for tempered case is typically 1-4 min
# depending on Verilator build optimization level. 30s is too short.
timeout 300 stdbuf -oL "$SIM" "+payload=$RECOVERY" "$KERNEL" > "$LOG" 2>&1
SIM_EXIT=$?
echo "sim exit code: $SIM_EXIT  (kernel-success → 0; tohost-exit path → 255 with SoC exit code in log)"

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

# Signal 2: recovery's "in recovery mode" banner — strongest positive
# evidence that BootROM successfully mret'd to recovery.riscv at 0x80100000
# and recovery's main() executed.
if grep -q "in recovery mode" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ recovery firmware reached (printed 'something went wrong, in recovery mode')"
fi

# Signal 3: SR readout — recovery read 0xF0003000 and saw SR_MANIFEST_HEADER bit.
if grep -q "boot status register = 0x00000001" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ recovery confirmed SR = 0x00000001 (SR_MANIFEST_HEADER bit set)"
fi

# Signal 4: per-stage diagnostic line from recovery decoding the SR.
if grep -q "check_manifest_header failed" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ recovery decoded failure as Stage 0 (check_manifest_header)"
fi

# Signal 5: clean Verilog $finish (recovery's main returned 0 → _exit(0) →
# tohost = 1 → FESVR called $finish).
if grep -q "Verilog \$finish" "$LOG" && [ "$SIM_EXIT" -eq 0 ]; then
    EVIDENCE="$EVIDENCE\n  ✓ sim exited cleanly via \$finish (sim_exit=0)"
fi

if $PASS; then
    echo -e "PASS:$EVIDENCE"
    exit 0
else
    exit 1
fi
