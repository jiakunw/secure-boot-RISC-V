"""Same logic as main tools/sign_firmware.py, but paths point at the
test's tempered_flash_image/ directory. The PRIVATE key, PUBLIC key,
and kernel come from the main repo (we're reusing real keys + real
kernel; only the manifest is tampered)."""
import os
from nacl.signing import SigningKey

HERE             = os.path.dirname(os.path.abspath(__file__))
REPO             = os.path.normpath(os.path.join(HERE, "../../.."))
TEMPERED_DIR     = os.path.normpath(os.path.join(HERE, "../tempered_flash_image"))

# Reused from main repo (real signing key, real pubkey, real kernel)
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
assert len(manifest_bytes) == 96, f"manifest must be 96 bytes (got {len(manifest_bytes)})"
with open(KERNEL_PATH, "rb") as f:
    kernel_bytes = f.read()

print(f"Signing TAMPERED manifest ({len(manifest_bytes)} bytes) with real private key...")
signature = signing_key.sign(manifest_bytes).signature
print(f"  (The signature will be valid against the TAMPERED manifest, but")
print(f"   BootROM rejects boot at Stage 0 before signature check is reached.)")

os.makedirs(TEMPERED_DIR, exist_ok=True)
with open(SIGNATURE_PATH, "wb") as f:
    f.write(signature)

# Layout: [Manifest(96)] [Signature(64)] [PubKey(32)] [Kernel(...)]
with open(FLASH_IMG_PATH, "wb") as f:
    f.write(manifest_bytes)   # 0x00
    f.write(signature)        # 0x60
    f.write(public_key_bytes) # 0xA0
    f.write(kernel_bytes)     # 0xC0

print(f"Wrote tampered {FLASH_IMG_PATH} ({os.path.getsize(FLASH_IMG_PATH)} bytes)")
