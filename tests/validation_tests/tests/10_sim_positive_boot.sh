#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
source "$REPO/tests/validation_tests/lib/common.sh"
LOG_DIR=$(vt_log_dir "$REPO")
LOG="$LOG_DIR/10_sim_positive_boot.log"

echo "== simulator positive boot test ==" | tee "$LOG"
vt_regen_hex_and_stage "$REPO"
vt_run_sim "$REPO" "$LOG" 300
vt_print_log_summary "$LOG" | tee -a "$LOG.summary"
vt_expect_positive_boot "$LOG" | tee -a "$LOG.summary"
