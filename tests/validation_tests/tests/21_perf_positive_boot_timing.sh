#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
source "$REPO/tests/validation_tests/lib/common.sh"
vt_source_env "$REPO"
LOG_DIR=$(vt_log_dir "$REPO")
LOG="$LOG_DIR/21_perf_positive_boot_timing.log"
CSV="$LOG_DIR/performance_boot_timing.csv"

echo "== performance test: positive boot wall-clock time ==" | tee "$LOG"
vt_regen_hex_and_stage "$REPO"
start_ns=$(date +%s%N)
vt_run_sim "$REPO" "$LOG" 300
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
pass="no"
if grep -q "kernel started successfully" "$LOG"; then
    pass="yes"
fi
{
    if [ ! -f "$CSV" ]; then
        echo "test,passed,elapsed_ms,log"
    fi
    echo "positive_boot,$pass,$elapsed_ms,$LOG"
} >> "$CSV"
echo "elapsed_ms=$elapsed_ms" | tee -a "$LOG"
echo "saved CSV: $CSV" | tee -a "$LOG"
vt_expect_positive_boot "$LOG" | tee -a "$LOG.summary"
