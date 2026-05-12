#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
from pathlib import Path

MANIFEST_OFFSET = 0x0000
SIGNATURE_OFFSET = 0x0060
PUBLIC_KEY_OFFSET = 0x00A0
KERNEL_OFFSET = 0x00C0
MANIFEST_SIZE = 96
SIGNATURE_SIZE = 64
PUBLIC_KEY_SIZE = 32
MANIFEST_STRUCT = "<IHHIIIIII32s32s"
MANIFEST_FIELDS = [
    "magic",
    "header_version",
    "flags",
    "version",
    "payload_size",
    "load_address",
    "entry_point",
    "reserved",
    "pad",
    "payload_hash",
    "next_pubkey_hash",
]


def p(repo: Path, rel: str) -> Path:
    return repo / rel


def read(path: Path) -> bytes:
    if not path.exists():
        raise SystemExit(f"missing file: {path}")
    return path.read_bytes()


def parse_manifest(data: bytes) -> dict:
    if len(data) != MANIFEST_SIZE:
        raise SystemExit(f"manifest must be {MANIFEST_SIZE} bytes, got {len(data)}")
    values = struct.unpack(MANIFEST_STRUCT, data)
    return dict(zip(MANIFEST_FIELDS, values))


def pack_manifest(m: dict) -> bytes:
    return struct.pack(MANIFEST_STRUCT, *(m[name] for name in MANIFEST_FIELDS))


def load_manifest(repo: Path) -> tuple[dict, bytes]:
    data = read(p(repo, "metadata/manifest.bin"))
    return parse_manifest(data), data


def check_artifacts(repo: Path, verbose: bool = True) -> int:
    errors: list[str] = []

    manifest_path = p(repo, "metadata/manifest.bin")
    signature_path = p(repo, "metadata/signature.bin")
    public_key_path = p(repo, "metadata/public_key.bin")
    pubkey_hash_path = p(repo, "metadata/pubkey_hash.bin")
    kernel_path = p(repo, "software/kernel/kernel.bin")
    flash_path = p(repo, "flash_image/flash_image.bin")

    manifest = read(manifest_path)
    signature = read(signature_path)
    public_key = read(public_key_path)
    pubkey_hash = read(pubkey_hash_path)
    kernel = read(kernel_path)
    flash = read(flash_path)

    def expect(cond: bool, msg: str) -> None:
        if cond:
            if verbose:
                print(f"PASS: {msg}")
        else:
            print(f"FAIL: {msg}")
            errors.append(msg)

    expect(len(manifest) == MANIFEST_SIZE, f"manifest size is {MANIFEST_SIZE} bytes")
    expect(len(signature) == SIGNATURE_SIZE, f"signature size is {SIGNATURE_SIZE} bytes")
    expect(len(public_key) == PUBLIC_KEY_SIZE, f"public key size is {PUBLIC_KEY_SIZE} bytes")
    expect(len(pubkey_hash) == 32, "pubkey hash size is 32 bytes")

    if len(manifest) == MANIFEST_SIZE:
        m = parse_manifest(manifest)
        expect(m["magic"] == 0x54424F53, "manifest magic is SBOT / 0x54424F53")
        expect(m["header_version"] == 1, "manifest header_version is 1")
        expect(m["version"] >= 1, "manifest image version is at least 1")
        expect(m["payload_size"] == len(kernel), "manifest payload_size matches kernel.bin size")
        expect(m["load_address"] >= 0x80000000, "manifest load_address is in DRAM")
        expect(m["entry_point"] >= 0x80000000, "manifest entry_point is in DRAM")
        expect(m["payload_hash"] == hashlib.sha256(kernel).digest(), "manifest payload_hash matches kernel.bin")

    expect(hashlib.sha256(public_key).digest() == pubkey_hash, "pubkey_hash.bin matches SHA-256(public_key.bin)")

    expect(len(flash) >= KERNEL_OFFSET + len(kernel), "flash image is large enough to contain kernel")
    expect(flash[MANIFEST_OFFSET:MANIFEST_OFFSET + MANIFEST_SIZE] == manifest, "flash manifest region matches metadata/manifest.bin")
    expect(flash[SIGNATURE_OFFSET:SIGNATURE_OFFSET + SIGNATURE_SIZE] == signature, "flash signature region matches metadata/signature.bin")
    expect(flash[PUBLIC_KEY_OFFSET:PUBLIC_KEY_OFFSET + PUBLIC_KEY_SIZE] == public_key, "flash public key region matches metadata/public_key.bin")
    expect(flash[KERNEL_OFFSET:KERNEL_OFFSET + len(kernel)] == kernel, "flash kernel region matches software/kernel/kernel.bin")

    if errors:
        print(f"\nSUMMARY: {len(errors)} artifact check(s) failed")
        return 1
    print("\nSUMMARY: all artifact checks passed")
    return 0


def inspect(repo: Path) -> int:
    m, data = load_manifest(repo)
    print("Secure boot image summary")
    print(f"  manifest:       {p(repo, 'metadata/manifest.bin')} ({len(data)} bytes)")
    print(f"  signature:      {p(repo, 'metadata/signature.bin')} ({p(repo, 'metadata/signature.bin').stat().st_size} bytes)")
    print(f"  public key:     {p(repo, 'metadata/public_key.bin')} ({p(repo, 'metadata/public_key.bin').stat().st_size} bytes)")
    print(f"  pubkey hash:    {p(repo, 'metadata/pubkey_hash.bin')} ({p(repo, 'metadata/pubkey_hash.bin').stat().st_size} bytes)")
    print(f"  flash image:    {p(repo, 'flash_image/flash_image.bin')} ({p(repo, 'flash_image/flash_image.bin').stat().st_size} bytes)")
    print("")
    for name in ["magic", "header_version", "flags", "version", "payload_size", "load_address", "entry_point", "reserved", "pad"]:
        v = m[name]
        if name in {"magic", "load_address", "entry_point"}:
            print(f"  {name:15s}: 0x{v:08x}")
        else:
            print(f"  {name:15s}: {v}")
    print(f"  payload_hash   : {m['payload_hash'].hex()}")
    print(f"  next_pubkey_hash: {m['next_pubkey_hash'].hex()}")
    return 0


def patch_flash_byte(repo: Path, offset: int, xor_value: int | None, value: int | None) -> int:
    flash_path = p(repo, "flash_image/flash_image.bin")
    data = bytearray(read(flash_path))
    if offset < 0 or offset >= len(data):
        raise SystemExit(f"offset 0x{offset:x} out of flash image range 0..0x{len(data)-1:x}")
    old = data[offset]
    if value is not None:
        data[offset] = value & 0xff
    else:
        data[offset] ^= (xor_value if xor_value is not None else 0xff) & 0xff
    flash_path.write_bytes(data)
    print(f"patched flash_image.bin at 0x{offset:08x}: 0x{old:02x} -> 0x{data[offset]:02x}")
    return 0


def zero_flash_region(repo: Path, offset: int, length: int) -> int:
    flash_path = p(repo, "flash_image/flash_image.bin")
    data = bytearray(read(flash_path))
    if offset < 0 or offset + length > len(data):
        raise SystemExit(f"region 0x{offset:x}..0x{offset+length-1:x} out of flash image range")
    data[offset:offset + length] = b"\x00" * length
    flash_path.write_bytes(data)
    print(f"zeroed flash_image.bin region 0x{offset:08x}..0x{offset+length-1:08x}")
    return 0


def patch_manifest_field(repo: Path, field: str, value: int) -> int:
    if field not in MANIFEST_FIELDS:
        raise SystemExit(f"unknown manifest field: {field}")
    if field in {"payload_hash", "next_pubkey_hash"}:
        raise SystemExit(f"field {field} is bytes; this tool only patches integer fields")
    manifest_path = p(repo, "metadata/manifest.bin")
    m, old_data = load_manifest(repo)
    old = m[field]
    m[field] = value
    manifest_path.write_bytes(pack_manifest(m))
    print(f"patched manifest.{field}: {old} / 0x{old:x} -> {value} / 0x{value:x}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("inspect")
    sub.add_parser("check-artifacts")

    pfb = sub.add_parser("patch-flash-byte")
    pfb.add_argument("--offset", required=True, type=lambda s: int(s, 0))
    pfb.add_argument("--xor", dest="xor_value", type=lambda s: int(s, 0))
    pfb.add_argument("--value", type=lambda s: int(s, 0))

    zfr = sub.add_parser("zero-flash-region")
    zfr.add_argument("--offset", required=True, type=lambda s: int(s, 0))
    zfr.add_argument("--length", required=True, type=lambda s: int(s, 0))

    pmf = sub.add_parser("patch-manifest-field")
    pmf.add_argument("--field", required=True)
    pmf.add_argument("--value", required=True, type=lambda s: int(s, 0))

    args = ap.parse_args()
    repo = Path(args.repo).resolve()

    if args.cmd == "inspect":
        return inspect(repo)
    if args.cmd == "check-artifacts":
        return check_artifacts(repo)
    if args.cmd == "patch-flash-byte":
        return patch_flash_byte(repo, args.offset, args.xor_value, args.value)
    if args.cmd == "zero-flash-region":
        return zero_flash_region(repo, args.offset, args.length)
    if args.cmd == "patch-manifest-field":
        return patch_manifest_field(repo, args.field, args.value)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
