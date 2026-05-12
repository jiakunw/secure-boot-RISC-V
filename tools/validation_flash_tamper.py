from pathlib import Path
import argparse
import sys

REPO = Path(__file__).resolve().parent.parent
FLASH = REPO / "flash_image" / "flash_image.bin"
KERNEL = REPO / "software" / "kernel" / "kernel.bin"
PUBKEY = REPO / "metadata" / "public_key.bin"

MANIFEST_SIZE = 96

def flip(data: bytearray, offset: int, label: str):
    if offset < 0 or offset >= len(data):
        raise SystemExit(f"{label}: offset 0x{offset:x} outside flash size {len(data)}")

    old = data[offset]
    data[offset] ^= 0x01
    new = data[offset]

    print(f"{label}: flipped flash offset 0x{offset:x}: 0x{old:02x} -> 0x{new:02x}")

def find_blob(data: bytes, blob: bytes, label: str) -> int:
    off = data.find(blob)
    if off < 0:
        raise SystemExit(f"could not find {label} bytes inside flash_image.bin")
    return off

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=["manifest", "public_key", "kernel"])
    args = parser.parse_args()

    if not FLASH.exists():
        raise SystemExit(f"missing {FLASH}")

    data = bytearray(FLASH.read_bytes())

    if args.case == "manifest":
        # avoid magic at byte 0; change signed metadata after signing
        flip(data, 0x10, "tampered manifest")

    elif args.case == "public_key":
        if not PUBKEY.exists():
            raise SystemExit(f"missing {PUBKEY}")

        pub = PUBKEY.read_bytes()
        off = find_blob(bytes(data), pub, "public key")
        flip(data, off + 4, "tampered public key")

    elif args.case == "kernel":
        if not KERNEL.exists():
            raise SystemExit(f"missing {KERNEL}")

        kernel = KERNEL.read_bytes()
        off = find_blob(bytes(data), kernel, "kernel")
        flip(data, off + 16, "tampered kernel")

    FLASH.write_bytes(data)
    print(f"wrote tampered flash: {FLASH}")

if __name__ == "__main__":
    main()
