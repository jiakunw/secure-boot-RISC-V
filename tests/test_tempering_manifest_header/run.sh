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

# Decode FESVR exit code. With current BootROM (mret-to-recovery + diagnostic
# recovery), three outcomes are interesting:
#
#   exit code 0x41 (65)  = recovery main() reached, SR contains bit 0 (manifest)
#                          → BootROM detected tampering AND mret'd to recovery
#                            AND recovery's crt0+main ran end-to-end. Strongest PASS.
#   exit code 0x80 (128) = BootROM's mret_trap_exit safety net fired
#                          → mret traps (recovery .text not at 0x80100000 or
#                            illegal instruction)
#   exit code 0x01 (1)   = older tohost-exit-from-BootROM path (no mret was taken)
#
# Verilator's $stop returns host shell exit 255; the SoC-level exit code is in
# the SimTSI assertion line: "Assertion failed: *** FAILED *** (exit code = N)".
if grep -qE "exit code =[[:space:]]+65\b" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ FESVR exit code = 0x41 — BootROM mret succeeded, recovery main() reached, SR_MANIFEST_HEADER captured"
elif grep -qE "exit code =[[:space:]]+128\b" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ⚠ FESVR exit code = 0x80 — BootROM mret TRAPPED (recovery firmware not at 0x80100000 or unreachable)"
elif grep -qE "exit code =[[:space:]]+1\b" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ FESVR exit code = 1 — BootROM tohost-exit path (no recovery mret)"
else
    EVIDENCE="$EVIDENCE\n  ⚠ no FESVR exit code line found (sim hung)"
    PASS=false
fi

if $PASS; then
    echo -e "PASS:$EVIDENCE"
    exit 0
else
    exit 1
fi
