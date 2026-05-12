#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
source "$REPO/tests/validation_tests/lib/common.sh"
vt_source_env "$REPO"
LOG_DIR=$(vt_log_dir "$REPO")
LOG="$LOG_DIR/14_sim_public_key_zero.log"
BACKUP=$(mktemp -d)
cleanup() { vt_restore_artifacts "$REPO" "$BACKUP"; rm -rf "$BACKUP"; }
trap cleanup EXIT
vt_backup_artifacts "$REPO" "$BACKUP"

echo "== simulator negative test: all-zero public key in flash ==" | tee "$LOG"
python3 "$REPO/tests/validation_tests/tools/image_tool.py" --repo "$REPO" zero-flash-region --offset 0xa0 --length 32 | tee -a "$LOG"
vt_regen_hex_and_stage "$REPO"
vt_run_sim "$REPO" "$LOG" 300
vt_print_log_summary "$LOG" | tee -a "$LOG.summary"
vt_expect_rejection "$LOG" "0x00000002" "check_public_key" | tee -a "$LOG.summary"
