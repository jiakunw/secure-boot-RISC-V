"""TAMPERED manifest generator — writes a manifest with WRONG magic.

Diff from main `tools/manifest_generators.py`:
  - MAGIC_NUMBER changed from 0x54424F53 ('SOBT') to 0x44414544 ('DEAD')
  - Output path points to the test's tempered_flash_image/ directory
    instead of the main metadata/ directory

The signature in the resulting flash image will be valid against THIS
tampered manifest (sign_firmware.py signs whatever manifest it finds),
but the BootROM rejects the boot at Stage 0 (check_manifest_header)
before it ever reaches the signature check.
"""
import struct
import hashlib
import os

# Paths relative to this file (tests/test_tempering_manifest_header/tools/)
HERE        = os.path.dirname(os.path.abspath(__file__))
KERNEL_PATH = os.path.normpath(os.path.join(HERE, "../../../software/kernel/kernel.bin"))
OUTPUT_PATH = os.path.normpath(os.path.join(HERE, "../tempered_flash_image/manifest.bin"))

# === TAMPER: magic is wrong ===
MAGIC_NUMBER   = 0x44414544   # 'DEAD' (instead of 'SOBT' = 0x54424F53)
HEADER_VERSION = 1
FLAGS          = 0
VERSION        = 1
LOAD_ADDR      = 0x80000000
ENTRY_POINT    = 0x80000000

with open(KERNEL_PATH, "rb") as f:
    kernel_data = f.read()
kernel_hash  = hashlib.sha256(kernel_data).digest()
payload_size = len(kernel_data)

print(f"Tempered manifest_generators.py:")
print(f"  Kernel:        {KERNEL_PATH}")
print(f"  Size:          {payload_size} bytes")
print(f"  SHA256:        {kernel_hash.hex()}")
print(f"  Magic:         0x{MAGIC_NUMBER:08X}  (TAMPERED — should be 0x54424F53 'SOBT')")
print(f"  Output:        {OUTPUT_PATH}")

struct_format = "<IHHIIIIII32s32s"
next_pubkey_hash = b'\x00' * 32

manifest_bytes = struct.pack(
    struct_format,
    MAGIC_NUMBER,
    HEADER_VERSION,
    FLAGS,
    VERSION,
    payload_size,
    LOAD_ADDR,
    ENTRY_POINT,
    0,
    0,
    kernel_hash,
    next_pubkey_hash,
)

os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
with open(OUTPUT_PATH, "wb") as f:
    f.write(manifest_bytes)

print(f"  Wrote tampered manifest: {len(manifest_bytes)} bytes")
