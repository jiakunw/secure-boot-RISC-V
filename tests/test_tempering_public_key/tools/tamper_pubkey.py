"""Build-time tamper of the public key for the test_tempering_public_key
negative test.

Reads the genuine artifacts from the main repo:
  - metadata/manifest.bin       (96 bytes, unchanged)
  - metadata/signature.bin      (64 bytes, unchanged — signature is over the
                                  manifest, not the pubkey, so tampering the
                                  pubkey doesn't invalidate the signature
                                  per se; the failure happens at Stage 1)
  - metadata/public_key.bin     (32 bytes — we XOR byte 5 here)
  - software/kernel/kernel.bin  (kernel image, unchanged)

Writes the tampered artifacts to this test's tempered_flash_image/:
  - public_key.bin              (tampered)
  - flash_image.bin             (manifest + sig + tampered_pubkey + kernel)
  - flash_image.hex             (Verilator $readmemh format)

Run once via build.sh; output is checked into the repo so the test is
deterministic and the test directory is self-contained.

Expected BootROM behavior at run time:
  - Stage 0 (check_manifest_header) passes (manifest is unchanged)
  - Stage 1 (check_public_key) FAILS:
      SHA-256(tampered_pubkey) != OTP-burned SHA-256(original_pubkey)
  - enter_recovery(SR_PUBLIC_KEY) → SR bit 1 set → mret to recovery
  - Recovery prints "check_public_key failed (bit 1)" and exits cleanly
"""
import os

HERE         = os.path.dirname(os.path.abspath(__file__))
REPO         = os.path.normpath(os.path.join(HERE, "../../.."))
TEMPERED_DIR = os.path.normpath(os.path.join(HERE, "../tempered_flash_image"))

MANIFEST_PATH      = os.path.join(REPO, "metadata", "manifest.bin")
SIGNATURE_PATH     = os.path.join(REPO, "metadata", "signature.bin")
PUBLIC_KEY_PATH    = os.path.join(REPO, "metadata", "public_key.bin")
KERNEL_PATH        = os.path.join(REPO, "software", "kernel", "kernel.bin")

OUT_PUBKEY_PATH    = os.path.join(TEMPERED_DIR, "public_key.bin")
OUT_FLASH_BIN_PATH = os.path.join(TEMPERED_DIR, "flash_image.bin")

# XOR-flip byte 5 (= pubkey byte 5 = flash offset 0xA5). Any other byte
# works equivalently — SHA-256's avalanche means any single-bit change in
# the pubkey produces a totally different hash.
TAMPER_OFFSET = 5

os.makedirs(TEMPERED_DIR, exist_ok=True)

with open(MANIFEST_PATH,   "rb") as f: manifest_bytes  = f.read()
with open(SIGNATURE_PATH,  "rb") as f: signature_bytes = f.read()
with open(PUBLIC_KEY_PATH, "rb") as f: pubkey_bytes    = bytearray(f.read())
with open(KERNEL_PATH,     "rb") as f: kernel_bytes    = f.read()

assert len(manifest_bytes)  == 96, f"manifest must be 96 bytes (got {len(manifest_bytes)})"
assert len(signature_bytes) == 64, f"signature must be 64 bytes (got {len(signature_bytes)})"
assert len(pubkey_bytes)    == 32, f"pubkey must be 32 bytes (got {len(pubkey_bytes)})"

orig_byte = pubkey_bytes[TAMPER_OFFSET]
pubkey_bytes[TAMPER_OFFSET] ^= 0xFF
tampered_byte = pubkey_bytes[TAMPER_OFFSET]

print(f"Tamper public key:")
print(f"  byte 0x{TAMPER_OFFSET:02x}: 0x{orig_byte:02x} -> 0x{tampered_byte:02x}")
print(f"  Output pubkey: {OUT_PUBKEY_PATH}")

with open(OUT_PUBKEY_PATH, "wb") as f:
    f.write(bytes(pubkey_bytes))

# Layout: [Manifest(96)] [Signature(64)] [TamperedPubKey(32)] [Kernel(...)]
with open(OUT_FLASH_BIN_PATH, "wb") as f:
    f.write(manifest_bytes)        # 0x00
    f.write(signature_bytes)       # 0x60
    f.write(bytes(pubkey_bytes))   # 0xA0  (tampered)
    f.write(kernel_bytes)          # 0xC0

print(f"  Output flash_image.bin: {OUT_FLASH_BIN_PATH}")
print(f"  Total size: {os.path.getsize(OUT_FLASH_BIN_PATH)} bytes")
