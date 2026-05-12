#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
source "$REPO/tests/validation_tests/lib/common.sh"
vt_source_env "$REPO"
LOG_DIR=$(vt_log_dir "$REPO")
LOG="$LOG_DIR/12_sim_header_version_bad.log"
BACKUP=$(mktemp -d)
cleanup() { vt_restore_artifacts "$REPO" "$BACKUP"; rm -rf "$BACKUP"; }
trap cleanup EXIT
vt_backup_artifacts "$REPO" "$BACKUP"

echo "== simulator negative test: bad manifest header version ==" | tee "$LOG"
# header_version is little-endian uint16 at manifest offset 0x04. Set low byte from 1 to 2.
python3 "$REPO/tests/validation_tests/tools/image_tool.py" --repo "$REPO" patch-flash-byte --offset 0x4 --value 0x02 | tee -a "$LOG"
vt_regen_hex_and_stage "$REPO"
vt_run_sim "$REPO" "$LOG" 300
vt_print_log_summary "$LOG" | tee -a "$LOG.summary"
vt_expect_rejection "$LOG" "0x00000001" "check_manifest_header" | tee -a "$LOG.summary"
