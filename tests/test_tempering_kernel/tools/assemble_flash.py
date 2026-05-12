"""Build-time assembler of the kernel-tampered flash image.

Reads from the main repo:
  - metadata/manifest.bin       (96 bytes, unchanged — signature still valid)
  - metadata/signature.bin      (64 bytes, unchanged)
  - metadata/public_key.bin     (32 bytes, unchanged — passes Stage 1)

Reads from this test's directory:
  - bad_kernel.bin              (compiled by ../Makefile, the malicious
                                  replacement payload)

Writes to this test's tempered_flash_image/:
  - flash_image.bin             (manifest + sig + pubkey + bad_kernel,
                                  padded/truncated to match the original
                                  payload_size declared in the manifest)

Why pad/truncate to manifest.payload_size:
  BootROM reads exactly `payload_size` bytes from flash offset 0xC0 (KERNEL_OFFSET).
  If bad_kernel is shorter, BootROM would read past it into flash junk; if
  longer, only the first payload_size bytes are read. Either way SHA-256
  differs from manifest->payload_hash, so Stage 3 catches the tamper. We
  normalize to payload_size for a clean, deterministic flash image.

Expected BootROM behavior at run time:
  - Stage 0: manifest magic OK (manifest unchanged)
  - Stage 1: SHA-256(pubkey) == OTP hash, OK (pubkey unchanged)
  - Stage 2: signature stub, OK (stub passes trivially)
  - Stage 3: SHA-256(bad_kernel padded) ≠ manifest->payload_hash → FAIL
  - enter_recovery(SR_LOAD_KERNEL) → SR bit 3 set → mret to recovery
  - Recovery prints "check_and_load_kernel failed (bit 3) -- kernel hash mismatch / bad params"
"""
import os
import struct

HERE         = os.path.dirname(os.path.abspath(__file__))
REPO         = os.path.normpath(os.path.join(HERE, "../../.."))
TEMPERED_DIR = os.path.normpath(os.path.join(HERE, "../tempered_flash_image"))

MANIFEST_PATH   = os.path.join(REPO, "metadata", "manifest.bin")
SIGNATURE_PATH  = os.path.join(REPO, "metadata", "signature.bin")
PUBLIC_KEY_PATH = os.path.join(REPO, "metadata", "public_key.bin")
BAD_KERNEL_PATH = os.path.normpath(os.path.join(HERE, "../bad_kernel.bin"))

OUT_FLASH_BIN_PATH = os.path.join(TEMPERED_DIR, "flash_image.bin")

os.makedirs(TEMPERED_DIR, exist_ok=True)

with open(MANIFEST_PATH,   "rb") as f: manifest_bytes  = f.read()
with open(SIGNATURE_PATH,  "rb") as f: signature_bytes = f.read()
with open(PUBLIC_KEY_PATH, "rb") as f: pubkey_bytes    = f.read()
with open(BAD_KERNEL_PATH, "rb") as f: bad_kernel      = f.read()

assert len(manifest_bytes)  == 96, f"manifest must be 96 bytes (got {len(manifest_bytes)})"
assert len(signature_bytes) == 64, f"signature must be 64 bytes (got {len(signature_bytes)})"
assert len(pubkey_bytes)    == 32, f"pubkey must be 32 bytes (got {len(pubkey_bytes)})"

# Manifest layout (little-endian): magic(I) header_version(H) flags(H)
#                                  version(I) payload_size(I) ...
payload_size = struct.unpack_from("<I", manifest_bytes, 8)[0]

print(f"Assemble tampered flash:")
print(f"  manifest.payload_size: {payload_size} bytes")
print(f"  bad_kernel.bin size:   {len(bad_kernel)} bytes")

if len(bad_kernel) > payload_size:
    bad_kernel_padded = bad_kernel[:payload_size]
    print(f"  bad_kernel TRUNCATED to {payload_size} bytes (was {len(bad_kernel)})")
elif len(bad_kernel) < payload_size:
    pad = payload_size - len(bad_kernel)
    bad_kernel_padded = bad_kernel + b'\x00' * pad
    print(f"  bad_kernel PADDED with {pad} zeros to {payload_size} bytes")
else:
    bad_kernel_padded = bad_kernel
    print(f"  bad_kernel size matches payload_size exactly")

# Layout: [Manifest(96)] [Signature(64)] [PubKey(32)] [BadKernel(payload_size)]
with open(OUT_FLASH_BIN_PATH, "wb") as f:
    f.write(manifest_bytes)
    f.write(signature_bytes)
    f.write(pubkey_bytes)
    f.write(bad_kernel_padded)

total = os.path.getsize(OUT_FLASH_BIN_PATH)
expected_total = 96 + 64 + 32 + payload_size
print(f"  Output: {OUT_FLASH_BIN_PATH}")
print(f"  Total size: {total} bytes (expected {expected_total})")
assert total == expected_total
