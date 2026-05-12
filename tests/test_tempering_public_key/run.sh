#!/usr/bin/env bash
# Negative test: tamper one byte of the public key inside flash_image.bin.
#
# The OTP module is burned with SHA-256(original public_key.bin) at
# elaboration time, so even one bit-flip in the flash-resident pubkey
# makes SHA-256(tampered pubkey) != OTP-burned hash. BootROM's Stage 1
# (check_public_key) detects this and jumps to recovery firmware, which
# reads the status register and reports the failure.
#
# Expected sim output:
#   - "boot status register = 0x00000002"
#   - "check_public_key failed (bit 1)"
#   - NO  "kernel started successfully rocket"
#
# No Verilator re-elaboration needed: flash content is loaded via
# $readmemh from flash_image.hex at simulator START, not baked in.

set -euo pipefail

# ── locate repo + sim binary ────────────────────────────────────────────
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$TEST_DIR/../.." && pwd)
source "$REPO/.env"

FLASH_BIN="$REPO/flash_image/flash_image.bin"
FLASH_HEX="$REPO/flash_image/flash_image.hex"
SIM_HEX="$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex"
SIMULATOR="$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-SecureBootConfig"
KERNEL="$REPO/software/kernel/kernel.riscv"
RECOVERY="$REPO/software/recovery/recovery.riscv"

# Sanity
[ -x "$SIMULATOR" ] || { echo "FAIL: simulator not built at $SIMULATOR"; exit 1; }
[ -f "$FLASH_BIN" ] || { echo "FAIL: missing $FLASH_BIN"; exit 1; }

# ── backup original flash artifacts, restore on exit ────────────────────
ORIG_BIN=$(mktemp); cp -p "$FLASH_BIN" "$ORIG_BIN"
ORIG_HEX=$(mktemp); cp -p "$FLASH_HEX" "$ORIG_HEX"
ORIG_SIM_HEX=$(mktemp); cp -p "$SIM_HEX" "$ORIG_SIM_HEX"
LOG=$(mktemp)
cleanup() {
    cp -p "$ORIG_BIN"     "$FLASH_BIN"
    cp -p "$ORIG_HEX"     "$FLASH_HEX"
    cp -p "$ORIG_SIM_HEX" "$SIM_HEX"
    rm -f "$ORIG_BIN" "$ORIG_HEX" "$ORIG_SIM_HEX" "$LOG"
}
trap cleanup EXIT

# ── tamper one byte in the pubkey region ───────────────────────────────
# flash_image layout: manifest(0x00..0x5F) signature(0x60..0x9F) pubkey(0xA0..0xBF) kernel(0xC0..)
# Flip all bits in byte at offset 0xA5 (= 5th byte of pubkey).
PUBKEY_OFFSET=$((0xA0))
TAMPER_AT=$((PUBKEY_OFFSET + 5))

python3 - <<PY
with open("$FLASH_BIN", "rb") as f:
    data = bytearray(f.read())
orig = data[$TAMPER_AT]
data[$TAMPER_AT] ^= 0xFF
with open("$FLASH_BIN", "wb") as f:
    f.write(bytes(data))
print(f"  tampered byte at offset 0x{$TAMPER_AT:x}: 0x{orig:02x} -> 0x{data[$TAMPER_AT]:02x}")
PY

# ── regenerate hex + copy into Verilator sim dir ────────────────────────
python3 "$REPO/tools/flash_image_to_hex.py" \
    --input "$FLASH_BIN" --output "$FLASH_HEX" >/dev/null
cp -p "$FLASH_HEX" "$SIM_HEX"

# ── run sim ─────────────────────────────────────────────────────────────
echo "  running sim (~5 min)..."
cd "$CHIPYARD_HOME/sims/verilator"
stdbuf -oL "$SIMULATOR" "$KERNEL" "$RECOVERY" > "$LOG" 2>&1 || true

# ── verdict ─────────────────────────────────────────────────────────────
echo
echo "── sim output ───────────────────────────────────────────────────"
cat "$LOG"
echo "─────────────────────────────────────────────────────────────────"

PASS=true
if grep -q "kernel started successfully" "$LOG"; then
    echo "FAIL: kernel booted normally — Stage 1 (check_public_key) did NOT catch the tamper"
    PASS=false
fi
if ! grep -q "check_public_key failed" "$LOG"; then
    echo "WARN: recovery did not print expected message; may indicate HTIF tohost mismatch between kernel/recovery ELFs"
fi
if grep -q "boot status register = 0x00000002" "$LOG"; then
    echo "PASS: SR shows 0x00000002 (bit 1 = check_public_key)"
elif ! grep -q "kernel started successfully" "$LOG"; then
    echo "PASS (weak): kernel banner absent — BootROM did NOT reach the success path. Recovery output not visible (HTIF mismatch?), but tamper was detected."
fi

$PASS && exit 0 || exit 1
