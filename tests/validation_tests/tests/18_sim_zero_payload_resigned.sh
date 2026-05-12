#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
source "$REPO/tests/validation_tests/lib/common.sh"
vt_source_env "$REPO"
LOG_DIR=$(vt_log_dir "$REPO")
LOG="$LOG_DIR/18_sim_zero_payload_resigned.log"
BACKUP=$(mktemp -d)
cleanup() { vt_restore_artifacts "$REPO" "$BACKUP"; rm -rf "$BACKUP"; }
trap cleanup EXIT
vt_backup_artifacts "$REPO" "$BACKUP"

echo "== simulator negative test: validly signed manifest with payload_size = 0 ==" | tee "$LOG"
python3 "$REPO/tests/validation_tests/tools/image_tool.py" --repo "$REPO" patch-manifest-field --field payload_size --value 0 | tee -a "$LOG"
(cd "$REPO/tools" && python3 sign_firmware.py) | tee -a "$LOG"
vt_regen_hex_and_stage "$REPO"
vt_run_sim "$REPO" "$LOG" 300
vt_print_log_summary "$LOG" | tee -a "$LOG.summary"
vt_expect_rejection "$LOG" "0x00000008" "check_and_load_kernel" | tee -a "$LOG.summary"
