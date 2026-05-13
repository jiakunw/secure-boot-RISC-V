"""Host-side Ed25519 signature verifier called by the Ed25519VerifierSim
SystemVerilog BlackBox (hardware/ed25519/vsrc/Ed25519VerifierSim.sv).

The BlackBox writes three files containing the manifest, signature, and
public key, then calls this script via $system. Exit code 0 = signature
valid, non-zero = invalid.

Implementation: PyNaCl (libsodium), which uses RFC8032 standard Ed25519
with SHA-512. This MUST match the signing tool: tools/sign_firmware.py
also uses PyNaCl. MonoCypher's `crypto_eddsa_check` is NOT used here
because MonoCypher 4.x's EdDSA uses BLAKE2b instead of SHA-512 — the
two implementations are incompatible: a PyNaCl-signed message cannot be
verified by MonoCypher and vice versa.
"""
from pathlib import Path
import sys

try:
    from nacl.signing import VerifyKey
    from nacl.exceptions import BadSignatureError
except ImportError:
    print("error: PyNaCl not installed. `pip install pynacl`.", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: verify_ed25519_from_files.py manifest.bin signature.bin public_key.bin",
              file=sys.stderr)
        return 10

    manifest_path   = Path(sys.argv[1])
    signature_path  = Path(sys.argv[2])
    public_key_path = Path(sys.argv[3])

    for p in (manifest_path, signature_path, public_key_path):
        if not p.exists():
            print(f"error: missing file {p}", file=sys.stderr)
            return 11

    manifest   = manifest_path.read_bytes()
    signature  = signature_path.read_bytes()
    public_key = public_key_path.read_bytes()

    if len(manifest) != 96:
        print(f"error: manifest must be 96 bytes (got {len(manifest)})", file=sys.stderr)
        return 20
    if len(signature) != 64:
        print(f"error: signature must be 64 bytes (got {len(signature)})", file=sys.stderr)
        return 21
    if len(public_key) != 32:
        print(f"error: public_key must be 32 bytes (got {len(public_key)})", file=sys.stderr)
        return 22

    try:
        VerifyKey(public_key).verify(manifest, signature)
        return 0  # signature valid
    except BadSignatureError:
        return 30  # signature invalid


if __name__ == "__main__":
    raise SystemExit(main())
