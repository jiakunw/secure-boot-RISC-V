"""Sign the test_tempering_version manifest + assemble tampered flash image.

Reads:
  - main repo: metadata/private_key.bin, public_key.bin
  - main repo: software/kernel/kernel.bin
  - this test:  tempered_flash_image/manifest.bin (written by manifest_generators.py
                with VERSION=1)

Writes (into THIS test's dir):
  - tempered_flash_image/signature.bin
  - tempered_flash_image/flash_image.bin

The signature will be cryptographically valid against the VERSION=1
manifest — Ed25519 doesn't know or care that VERSION=1 is "old". BootROM's
Stage 2 (signature check) is stubbed in the current build, and would pass
anyway because the signature matches the manifest. The downgrade attack
is caught at Stage 4 by the rollback counter compare.
"""
import os
from nacl.signing import SigningKey

HERE             = os.path.dirname(os.path.abspath(__file__))
REPO             = os.path.normpath(os.path.join(HERE, "../../.."))
TEMPERED_DIR     = os.path.normpath(os.path.join(HERE, "../tempered_flash_image"))

# Read-only from main repo
PRIVATE_KEY_PATH = os.path.join(REPO, "metadata", "private_key.bin")
PUBLIC_KEY_PATH  = os.path.join(REPO, "metadata", "public_key.bin")
KERNEL_PATH      = os.path.join(REPO, "software", "kernel", "kernel.bin")

# Read tampered manifest from this test dir; write tampered flash here too
MANIFEST_PATH    = os.path.join(TEMPERED_DIR, "manifest.bin")
SIGNATURE_PATH   = os.path.join(TEMPERED_DIR, "signature.bin")
FLASH_IMG_PATH   = os.path.join(TEMPERED_DIR, "flash_image.bin")

with open(PRIVATE_KEY_PATH, "rb") as f:
    signing_key = SigningKey(f.read())
with open(PUBLIC_KEY_PATH, "rb") as f:
    public_key_bytes = f.read()
with open(MANIFEST_PATH, "rb") as f:
    manifest_bytes = f.read()
assert len(manifest_bytes) == 96, f"manifest must be 96 bytes (got {len(manifest_bytes)}); re-run manifest_generators.py"
with open(KERNEL_PATH, "rb") as f:
    kernel_bytes = f.read()

print(f"Signing tampered-version manifest ({len(manifest_bytes)} bytes) with real private key...")
signature = signing_key.sign(manifest_bytes).signature
print(f"  (Signature is cryptographically valid against the VERSION=1 manifest;")
print(f"   BootROM rejects the boot at Stage 4 — rollback counter compare.)")

os.makedirs(TEMPERED_DIR, exist_ok=True)
with open(SIGNATURE_PATH, "wb") as f:
    f.write(signature)

# Layout: [Manifest(96)] [Signature(64)] [PubKey(32)] [Kernel(...)]
with open(FLASH_IMG_PATH, "wb") as f:
    f.write(manifest_bytes)   # 0x00
    f.write(signature)        # 0x60
    f.write(public_key_bytes) # 0xA0
    f.write(kernel_bytes)     # 0xC0

print(f"Wrote tempered {FLASH_IMG_PATH} ({os.path.getsize(FLASH_IMG_PATH)} bytes)")
