#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERROR: do not source this script."
  echo "Run it with:"
  echo "  bash scripts/run_validation_essential.sh"
  return 1
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHIPYARD_HOME="${CHIPYARD_HOME:-/root/chipyard}"
SIM_DIR="$CHIPYARD_HOME/sims/verilator"
SIM="$SIM_DIR/simulator-chipyard.harness-SecureBootConfig"
OUT="$REPO/validation_results"

mkdir -p "$OUT"

export CHIPYARD_HOME
export SECURE_BOOT_REPO="$REPO"

GOOD_BIN="$OUT/flash_good.bin"
GOOD_HEX="$OUT/flash_good.hex"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

run_sim() {
  local name="$1"
  local expect="$2"
  local log="$OUT/${name}.log"

  echo ""
  echo "============================================================"
  echo "RUNNING: $name"
  echo "EXPECT:  $expect"
  echo "============================================================"

  cd "$SIM_DIR"

  set +e
  /usr/bin/time -f "elapsed_seconds=%e" \
    timeout 300 stdbuf -oL "$SIM" \
      +payload="$REPO/software/recovery/recovery.riscv" \
      "$REPO/software/kernel/kernel.riscv" \
      > "$log" 2>&1

  local rc=$?
  set -e

  echo "sim exit code: $rc" | tee -a "$log"

  grep -nE "kernel started|recovery|boot status|signature|public_key|kernel|hash|rollback|PMP|FAILED|tohost|Verilog|finish|trap|fault|UART|Terminated|elapsed_seconds" \
    "$log" || true

  if grep -q "$expect" "$log"; then
    echo "RESULT: PASS" | tee -a "$log"
    return 0
  else
    echo "RESULT: FAIL" | tee -a "$log"
    return 1
  fi
}

stage_flash() {
  cp "$REPO/flash_image/flash_image.hex" "$SIM_DIR/flash_image/flash_image.hex"
}

restore_good_flash() {
  cp "$GOOD_BIN" "$REPO/flash_image/flash_image.bin"
  cp "$GOOD_HEX" "$REPO/flash_image/flash_image.hex"
  stage_flash
}

bin_to_hex() {
  python3 "$REPO/tools/flash_image_to_hex.py" \
    --input "$REPO/flash_image/flash_image.bin" \
    --output "$REPO/flash_image/flash_image.hex"
}

record_md_header() {
  cat > "$OUT/validation_summary.md" <<'MD'
# Essential Secure Boot Validation Results

This is the reduced validation set used for the report. It covers one clean positive whole-system boot and the three most important negative security failures: signed manifest tamper, public-key/OTP mismatch, and kernel byte tamper.

| Test | What was changed | Expected result | Log file |
|---|---|---|---|
MD
}

record_md_row() {
  local test="$1"
  local changed="$2"
  local expected="$3"
  local log="$4"

  echo "| $test | $changed | $expected | \`validation_results/$log\` |" >> "$OUT/validation_summary.md"
}

main() {
  cd "$REPO"

  [ -x "$SIM" ] || die "missing simulator: $SIM"
  [ -f "$REPO/flash_image/flash_image.bin" ] || die "missing flash_image.bin"
  [ -f "$REPO/flash_image/flash_image.hex" ] || die "missing flash_image.hex"
  [ -f "$REPO/software/kernel/kernel.riscv" ] || die "missing kernel.riscv"
  [ -f "$REPO/software/recovery/recovery.riscv" ] || die "missing recovery.riscv"

  echo ""
  echo "============================================================"
  echo "1. Freshness check"
  echo "============================================================"
  CHIPYARD_HOME="$CHIPYARD_HOME" "$REPO/scripts/check_secureboot_freshness.sh" \
    | tee "$OUT/00_freshness.log"

  cp "$REPO/flash_image/flash_image.bin" "$GOOD_BIN"
  cp "$REPO/flash_image/flash_image.hex" "$GOOD_HEX"

  record_md_header
  record_md_row "Freshness check" "No tamper; checks staged BootROM and flash" "freshness check passed" "00_freshness.log"

  # 1. valid boot
  restore_good_flash
  run_sim "01_valid_boot" "kernel started successfully rocket"
  record_md_row "Valid boot" "No tamper" "kernel started successfully rocket" "01_valid_boot.log"

  # 2. tampered manifest / Ed25519
  restore_good_flash
  python3 "$REPO/tools/validation_flash_tamper.py" manifest
  bin_to_hex
  stage_flash
  run_sim "02_tampered_manifest" "boot status register = 0x00000004"
  record_md_row "Tampered manifest" "Flip one signed manifest byte after signing" "boot status register = 0x00000004" "02_tampered_manifest.log"

  # 3. wrong public key / OTP
  restore_good_flash
  python3 "$REPO/tools/validation_flash_tamper.py" public_key
  bin_to_hex
  stage_flash
  run_sim "03_wrong_public_key" "boot status register = 0x00000002"
  record_md_row "Wrong public key" "Flip one public-key byte in flash" "boot status register = 0x00000002" "03_wrong_public_key.log"

  # 4. tampered kernel / SHA-256
  restore_good_flash
  python3 "$REPO/tools/validation_flash_tamper.py" kernel
  bin_to_hex
  stage_flash
  run_sim "04_tampered_kernel" "boot status register = 0x00000008"
  record_md_row "Tampered kernel" "Flip one kernel byte after manifest/signature generation" "boot status register = 0x00000008" "04_tampered_kernel.log"

  restore_good_flash

  echo ""
  echo "============================================================"
  echo "DONE"
  echo "Results folder: $OUT"
  echo "Summary file:   $OUT/validation_summary.md"
  echo "============================================================"

  cat "$OUT/validation_summary.md"
}

main "$@"
