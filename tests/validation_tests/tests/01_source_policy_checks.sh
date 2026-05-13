#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../../.." && pwd)
LOG_DIR="$REPO/tests/validation_tests/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/01_source_policy_checks.log"

check_grep() {
    local pattern="$1"
    local file="$2"
    local label="$3"
    if grep -Eq "$pattern" "$REPO/$file"; then
        echo "PASS: $label"
    else
        echo "FAIL: $label"
        return 1
    fi
}

{
    echo "== BootROM source policy checks =="
    check_grep "check_manifest_header\(manifest\);" "software/bootrom/bootrom.c" "BootROM calls manifest header check"
    check_grep "check_public_key\(\);" "software/bootrom/bootrom.c" "BootROM calls OTP public-key hash check"
    check_grep "check_manifest_signature\(\);" "software/bootrom/bootrom.c" "BootROM calls Ed25519 signature check"
    check_grep "check_and_load_kernel\(manifest\);" "software/bootrom/bootrom.c" "BootROM calls kernel load/hash check"
    check_grep "check_rollback_counter\(manifest\)" "software/bootrom/bootrom.c" "BootROM calls rollback counter check"
    check_grep "lock_pmp\(\)" "software/bootrom/bootrom.c" "BootROM calls PMP lock path"
    check_grep "clear_scratch\(\);" "software/bootrom/bootrom.c" "BootROM clears scratch before handoff"
    check_grep "fence\.i" "software/bootrom/bootrom.c" "BootROM issues fence.i"
    check_grep "ED25519_VERIFY_BASE 0xF0004000" "software/bootrom/bootrom.c" "BootROM uses Ed25519 MMIO verifier at 0xF0004000"
    check_grep "BOOT_STATUS_REG[[:space:]]+0xF0003000" "software/bootrom/bootrom.c" "BootROM writes status register at 0xF0003000"

    echo
    echo "== Chisel config checks =="
    check_grep "WithSecureBootSPI" "hardware/secureboot/SecureBootConfig.scala" "SecureBootConfig includes SPI flash"
    check_grep "WithSecureBootOTP" "hardware/secureboot/SecureBootConfig.scala" "SecureBootConfig includes OTP"
    check_grep "WithSecureBootRollback" "hardware/secureboot/SecureBootConfig.scala" "SecureBootConfig includes rollback counter"
    check_grep "WithSecureBootEd25519" "hardware/secureboot/SecureBootConfig.scala" "SecureBootConfig includes Ed25519 verifier"
    check_grep "WithSecureBootSR" "hardware/secureboot/SecureBootConfig.scala" "SecureBootConfig includes status register"

    echo
    echo "== hardware behavior checks =="
    check_grep "data > version" "hardware/rollback_counter/rtl/rollback_counter.scala" "rollback counter only advances upward"
    check_grep "Files\.readAllBytes" "hardware/otp/rtl/otp.scala" "OTP loads public-key hash from metadata/pubkey_hash.bin"
    check_grep "idx != 192" "hardware/ed25519/vsrc/Ed25519VerifierSim.sv" "Ed verifier expects exactly 192 bytes"
    check_grep "verify_ed25519_from_files.py" "hardware/ed25519/vsrc/Ed25519VerifierSim.sv" "Ed verifier calls host-side verifier script"
} 2>&1 | tee "$LOG"
