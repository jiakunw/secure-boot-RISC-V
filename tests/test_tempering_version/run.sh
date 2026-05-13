#!/usr/bin/env bash
# Run the version-tampered (rollback) negative test against the pre-built
# TamperedRollbackSecureBootConfig sim.
#
# This sim's rollback counter peripheral is elaborated with resetValue=5
# (simulating "an earlier newer firmware bumped the counter"), and the
# tempered flash_image.hex contains a manifest with VERSION=1. BootROM
# Stage 4 (check_rollback_counter) reads counter=5, sees version=1,
# 1 < 5 → enter_recovery(SR_ROLLBACK_COUNTER).
#
# Expected outcome:
#   - kernel banner ABSENT (BootROM rejected boot at Stage 4)
#   - "boot status register = 0x00000010"  (= SR_ROLLBACK_COUNTER bit 4)
#   - "check_rollback_counter failed (bit 4)"
#   - Verilog $finish, sim_exit=0
#
# This script does NOT build anything — run build.sh first.

set -o pipefail
# Not using `set -u`: Chipyard's conda activate scripts reference some
# BACKUP_* variables that may be unset on first activation.

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../.." && pwd)
export CONDA_BACKUP_RISCV=${CONDA_BACKUP_RISCV:-}
source "$REPO/.env"

SIM="$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-TamperedRollbackSecureBootConfig"
KERNEL="$REPO/software/kernel/kernel.riscv"
RECOVERY="$REPO/software/recovery/recovery.riscv"

if [ ! -x "$SIM" ]; then
    echo "FAIL: simulator not built. Run:  bash $TEST_DIR/build.sh"
    exit 1
fi

LOG=$(mktemp)
trap "rm -f $LOG" EXIT

echo "Running version-tampered (rollback) sim..."
cd "$CHIPYARD_HOME/sims/verilator"
# FESVR loads ONLY the first positional ELF (targs[0]). Extra ELFs must
# be passed via the `+payload=<path>` plusarg, which goes through FESVR's
# `payloads` list and gets loaded in addition to the primary kernel.
# Do NOT use `stdbuf -oL` or wrap with `timeout`: both interact badly with
# the Verilator sim's stdio when output is redirected to a file.
"$SIM" "+payload=$RECOVERY" "$KERNEL" > "$LOG" 2>&1
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
    echo "FAIL: kernel banner present — Stage 4 (check_rollback_counter) did NOT catch the downgrade"
    PASS=false
else
    EVIDENCE="$EVIDENCE\n  ✓ kernel banner absent"
fi

# Signal 2: recovery banner reached
if grep -q "in recovery mode" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ recovery firmware reached (printed 'something went wrong, in recovery mode')"
fi

# Signal 3: SR readout = 0x00000010 (SR_ROLLBACK_COUNTER bit 4)
if grep -q "boot status register = 0x00000010" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ recovery confirmed SR = 0x00000010 (SR_ROLLBACK_COUNTER bit set)"
fi

# Signal 4: per-stage diagnostic
if grep -q "check_rollback_counter failed" "$LOG"; then
    EVIDENCE="$EVIDENCE\n  ✓ recovery decoded failure as Stage 4 (check_rollback_counter)"
fi

# Signal 5: clean Verilog $finish (sim_exit=0)
if grep -q "Verilog \$finish" "$LOG" && [ "$SIM_EXIT" -eq 0 ]; then
    EVIDENCE="$EVIDENCE\n  ✓ sim exited cleanly via \$finish (sim_exit=0)"
fi

# Fallback diagnostic for known failure modes
if grep -qE "exit code =[[:space:]]+128\b" "$LOG"; then
    echo "FAIL: BootROM mret_trap_exit fired (exit code 0x80) — recovery.riscv not loaded at 0x80100000."
    echo "      Check that recovery is passed via +payload=, not as positional arg."
    PASS=false
fi

if $PASS; then
    echo -e "PASS:$EVIDENCE"
    exit 0
else
    exit 1
fi
