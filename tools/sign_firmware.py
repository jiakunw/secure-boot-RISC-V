from pathlib import Path

# this version does not need PyNaCl.
# the current BootROM kernel-start path has signature verification stubbed,
# so the signature field only needs to exist so the flash layout stays correct.

TOOL_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOL_DIR.parent

PRIVATE_KEY_PATH = REPO_ROOT / "metadata" / "private_key.bin"
PUBLIC_KEY_PATH  = REPO_ROOT / "metadata" / "public_key.bin"
MANIFEST_PATH    = REPO_ROOT / "metadata" / "manifest.bin"
KERNEL_PATH      = REPO_ROOT / "software" / "kernel" / "kernel.bin"
SIGNATURE_PATH   = REPO_ROOT / "metadata" / "signature.bin"
FLASH_IMG_PATH   = REPO_ROOT / "flash_image" / "flash_image.bin"

MANIFEST_SIZE = 96
SIGNATURE_SIZE = 64
PUBLIC_KEY_SIZE = 32

def read_exact(path, expected_size=None):
    if not path.exists():
        raise SystemExit(f"Error: missing file: {path}")

    data = path.read_bytes()

    if expected_size is not None and len(data) != expected_size:
        raise SystemExit(
            f"Error: {path} must be {expected_size} bytes, got {len(data)} bytes"
        )

    return data

manifest_bytes = read_exact(MANIFEST_PATH, MANIFEST_SIZE)
public_key_bytes = read_exact(PUBLIC_KEY_PATH, PUBLIC_KEY_SIZE)
kernel_bytes = read_exact(KERNEL_PATH)

# placeholder signature.
# BootROM currently does not verify it, but the 64-byte slot must stay present.
signature = bytes([0] * SIGNATURE_SIZE)

SIGNATURE_PATH.write_bytes(signature)

FLASH_IMG_PATH.parent.mkdir(parents=True, exist_ok=True)

with FLASH_IMG_PATH.open("wb") as f:
    f.write(manifest_bytes)      # 0x0000 - 0x005f
    f.write(signature)           # 0x0060 - 0x009f
    f.write(public_key_bytes)    # 0x00a0 - 0x00bf
    f.write(kernel_bytes)        # 0x00c0 onward

print(f"Manifest:  {MANIFEST_PATH} ({len(manifest_bytes)} bytes)")
print(f"Signature: {SIGNATURE_PATH} ({len(signature)} bytes placeholder)")
print(f"PublicKey: {PUBLIC_KEY_PATH} ({len(public_key_bytes)} bytes)")
print(f"Kernel:    {KERNEL_PATH} ({len(kernel_bytes)} bytes)")
print(f"Flash:     {FLASH_IMG_PATH} ({FLASH_IMG_PATH.stat().st_size} bytes)")
print("Flash layout:")
print("  manifest  @ 0x0000")
print("  signature @ 0x0060")
print("  publickey @ 0x00a0")
print("  kernel    @ 0x00c0")
