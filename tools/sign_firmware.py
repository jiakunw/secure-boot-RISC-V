import os
from nacl.signing import SigningKey

# Paths - Adjust these to match your repo structure
PRIVATE_KEY_PATH = "../metadata/private_key.bin"
PUBLIC_KEY_PATH  = "../metadata/public_key.bin"
MANIFEST_PATH    = "../metadata/manifest.bin"
KERNEL_PATH      = "../software/kernel/kernel.bin"
SIGNATURE_PATH    = "../metadata/manifest.bin"
FLASH_IMG_PATH      = "../flash_image/flash_image.bin"

# 1. Load the Secret Private Key
if not os.path.exists(PRIVATE_KEY_PATH):
    print(f"Error: Private key not found at {PRIVATE_KEY_PATH}")
    exit(-1)

with open(PRIVATE_KEY_PATH, "rb") as f:
    signing_key = SigningKey(f.read())

# 2. Load the Public Key (to include in the final image)
with open(PUBLIC_KEY_PATH, "rb") as f:
    public_key_bytes = f.read()

# 3. Read the Manifest and the Kernel
with open(MANIFEST_PATH, "rb") as f:
    manifest_bytes = f.read()

with open(KERNEL_PATH, "rb") as f:
    kernel_bytes = f.read()

# 4. Generate the Signature
# We sign the 96-byte manifest. The signature will be 64 bytes.
print(f"Signing manifest ({len(manifest_bytes)} bytes)...")
signed_data = signing_key.sign(manifest_bytes)
signature = signed_data.signature

# 5. Save signature
with open(SIGNATURE_PATH, "wb") as f:
    f.write(signature)

# 6. Assemble the final flash_image.bin
# Layout: [Manifest(96)] [Signature(64)] [PubKey(32)] [Kernel(...)]
with open(FLASH_IMG_PATH, "wb") as f:
    f.write(manifest_bytes)   # Offset 0x00
    f.write(signature)        # Offset 0x60
    f.write(public_key_bytes) # Offset 0xA0
    f.write(kernel_bytes)     # Offset 0xC0

print(f"Successfully created {FLASH_IMG_PATH}")
print(f"Final Size: {os.path.getsize(FLASH_IMG_PATH)} bytes")
