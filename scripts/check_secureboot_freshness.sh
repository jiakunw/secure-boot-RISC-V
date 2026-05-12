#!/usr/bin/env bash
set -euo pipefail

: "${CHIPYARD_HOME:=/root/chipyard}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1] required generated files"
for f in \
  "$REPO/software/kernel/kernel.riscv" \
  "$REPO/software/kernel/kernel.bin" \
  "$REPO/metadata/public_key.bin" \
  "$REPO/metadata/private_key.bin" \
  "$REPO/metadata/pubkey_hash.bin" \
  "$REPO/metadata/manifest.bin" \
  "$REPO/metadata/signature.bin" \
  "$REPO/flash_image/flash_image.bin" \
  "$REPO/flash_image/flash_image.hex" \
  "$REPO/software/bootrom/bootrom.img"
do
  if [ ! -f "$f" ]; then
    echo "missing: $f"
    exit 1
  fi
  ls -l "$f"
done

echo ""
echo "[2] public key hash matches OTP hash file"
python3 - <<PY
from pathlib import Path
import hashlib

repo = Path("$REPO")
pub = (repo / "metadata/public_key.bin").read_bytes()
otp = (repo / "metadata/pubkey_hash.bin").read_bytes()
calc = hashlib.sha256(pub).digest()

print("sha256(public_key.bin):", calc.hex())
print("pubkey_hash.bin:       ", otp.hex())

if calc != otp:
    raise SystemExit("ERROR: public key hash does not match pubkey_hash.bin")
PY

echo ""
echo "[3] flash image contains current public key"
python3 - <<PY
from pathlib import Path

repo = Path("$REPO")
pub = (repo / "metadata/public_key.bin").read_bytes()
flash = (repo / "flash_image/flash_image.bin").read_bytes()
flash_pub = flash[0xA0:0xA0 + 32]

print("metadata public_key:", pub.hex())
print("flash public_key:   ", flash_pub.hex())

if pub != flash_pub:
    raise SystemExit("ERROR: flash public key does not match metadata/public_key.bin")
PY

echo ""
echo "[4] flash hex staged into Verilator"
STAGED_FLASH="$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex"

if [ ! -f "$STAGED_FLASH" ]; then
  echo "missing staged flash: $STAGED_FLASH"
  exit 1
fi

cmp -s "$REPO/flash_image/flash_image.hex" "$STAGED_FLASH" \
  && echo "staged flash matches repo flash" \
  || { echo "ERROR: staged flash is stale"; exit 1; }

echo ""
echo "[5] BootROM image staged into Chipyard resources"
STAGED_BOOTROM="$CHIPYARD_HOME/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img"

if [ ! -f "$STAGED_BOOTROM" ]; then
  echo "missing staged BootROM: $STAGED_BOOTROM"
  exit 1
fi

cmp -s "$REPO/software/bootrom/bootrom.img" "$STAGED_BOOTROM" \
  && echo "staged BootROM matches repo BootROM" \
  || { echo "ERROR: staged BootROM is stale"; exit 1; }

echo ""
echo "freshness check passed"
