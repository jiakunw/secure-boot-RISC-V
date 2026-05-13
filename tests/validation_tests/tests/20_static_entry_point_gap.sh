#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
LOG_DIR="$REPO/tests/validation_tests/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/20_static_entry_point_gap.log"
{
    echo "== static design-gap check: entry point range =="
    echo "BootROM checks load_address >= DRAM_BASE before loading kernel."
    echo "This test checks whether bootrom.c also validates manifest->entry_point before mret."
    if grep -Eq "entry_point.*DRAM_BASE|DRAM_BASE.*entry_point" "$REPO/software/bootrom/bootrom.c"; then
        echo "PASS: BootROM source appears to check entry_point against DRAM_BASE"
    else
        echo "WARN: no explicit entry_point range check found in bootrom.c"
        echo "      This is a reportable limitation unless you add the check."
        echo "      The code currently stores entry_point = manifest->entry_point and later mret's to it."
    fi
} 2>&1 | tee "$LOG"
