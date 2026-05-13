#!/usr/bin/env python3
"""Convert flash_image.bin into a one-byte-per-line Chisel memory hex file."""

from pathlib import Path
import argparse


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="flash_image/flash_image.bin")
    parser.add_argument("--output", default="flash_image/flash_image.hex")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)
    data = input_path.read_bytes()

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("".join(f"{byte:02x}\n" for byte in data), encoding="ascii")
    print(f"Wrote {len(data)} bytes to {output_path}")


if __name__ == "__main__":
    main()
