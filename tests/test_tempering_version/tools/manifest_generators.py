"""Manifest generator for the test_tempering_version negative test.

Writes a manifest with VERSION=1 (older than the rollback counter's
elaborated resetValue of 5 in TamperedRollbackSecureBootConfig.scala).
The signature in the resulting flash image will be cryptographically
valid against this manifest (sign_firmware.py signs whatever manifest
it finds), but BootROM Stage 4 (check_rollback_counter) rejects the
boot: manifest.version=1 < counter=5 → enter_recovery(SR_ROLLBACK_COUNTER).

Diff from main `tools/manifest_generators.py`:
  - VERSION lowered to 1 (the "old firmware" downgrade-attack scenario)
  - Paths are absolute (via HERE / REPO) so this script can be run from
    anywhere without modifying the main repo's metadata/.

Inputs (read-only, from main repo):
  - software/kernel/kernel.bin    (hashed for payload_hash)

Output (written into THIS test's dir, NOT main repo):
  - tempered_flash_image/manifest.bin
"""
import struct
import hashlib
import os

HERE        = os.path.dirname(os.path.abspath(__file__))
REPO        = os.path.normpath(os.path.join(HERE, "../../.."))
KERNEL_PATH = os.path.join(REPO, "software", "kernel", "kernel.bin")
OUTPUT_PATH = os.path.normpath(os.path.join(HERE, "../tempered_flash_image/manifest.bin"))

# === Genuine cryptographic params, only `VERSION` is "old" ===
MAGIC_NUMBER   = 0x54424F53   # 'SOBT' (genuine — Stage 0 passes)
HEADER_VERSION = 1
FLAGS          = 0
VERSION        = 1            # OLD: counter resetValue=5 → 1 < 5 → Stage 4 rejects
LOAD_ADDR      = 0x80000000
ENTRY_POINT    = 0x80000000

with open(KERNEL_PATH, "rb") as f:
    kernel_data = f.read()
kernel_hash  = hashlib.sha256(kernel_data).digest()
payload_size = len(kernel_data)

print(f"Tampered-version manifest_generators.py:")
print(f"  Kernel:        {KERNEL_PATH}")
print(f"  Size:          {payload_size} bytes")
print(f"  SHA256:        {kernel_hash.hex()}")
print(f"  Magic:         0x{MAGIC_NUMBER:08X}  (genuine — Stage 0 passes)")
print(f"  Version:       {VERSION}  (OLD — counter resetValue=5, so Stage 4 rejects)")
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

print(f"  Wrote rollback-tampered manifest: {len(manifest_bytes)} bytes")
