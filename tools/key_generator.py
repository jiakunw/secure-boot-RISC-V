from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

TOOL_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOL_DIR.parent

MONOCYPHER_C = REPO_ROOT / "software" / "crypto" / "src" / "monocypher.c"
MONOCYPHER_H_DIR = REPO_ROOT / "software" / "crypto" / "include"

PRIVATE_KEY_PATH = REPO_ROOT / "metadata" / "private_key.bin"
PUBLIC_KEY_PATH = REPO_ROOT / "metadata" / "public_key.bin"
PUBKEY_HASH_PATH = REPO_ROOT / "metadata" / "pubkey_hash.bin"

HELPER_C = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "monocypher.h"

static int write_file(const char *path, const uint8_t *data, size_t n)
{
    FILE *f = fopen(path, "wb");
    if (!f) return 1;
    if (fwrite(data, 1, n, f) != n) {
        fclose(f);
        return 2;
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        return 10;
    }

    uint8_t seed[32];
    uint8_t secret_key[64];
    uint8_t public_key[32];

    FILE *random_file = fopen("/dev/urandom", "rb");
    if (!random_file) {
        return 11;
    }

    if (fread(seed, 1, sizeof(seed), random_file) != sizeof(seed)) {
        fclose(random_file);
        return 12;
    }

    fclose(random_file);

    crypto_eddsa_key_pair(secret_key, public_key, seed);

    if (write_file(argv[1], secret_key, sizeof(secret_key)) != 0) {
        return 13;
    }

    if (write_file(argv[2], public_key, sizeof(public_key)) != 0) {
        return 14;
    }

    return 0;
}
'''

def build_helper(tmp: Path) -> Path:
    helper_c = tmp / "monocypher_keygen.c"
    helper_bin = tmp / "monocypher_keygen"
    helper_c.write_text(HELPER_C)

    subprocess.check_call([
        "gcc",
        "-O2",
        "-I", str(MONOCYPHER_H_DIR),
        str(helper_c),
        str(MONOCYPHER_C),
        "-o", str(helper_bin),
    ])

    return helper_bin

def main():
    if not MONOCYPHER_C.exists():
        raise SystemExit(f"missing {MONOCYPHER_C}")

    PRIVATE_KEY_PATH.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        helper = build_helper(Path(td))
        subprocess.check_call([
            str(helper),
            str(PRIVATE_KEY_PATH),
            str(PUBLIC_KEY_PATH),
        ])

    public_key = PUBLIC_KEY_PATH.read_bytes()

    if len(PRIVATE_KEY_PATH.read_bytes()) != 64:
        raise SystemExit("private_key.bin must be 64 bytes for MonoCypher EdDSA")

    if len(public_key) != 32:
        raise SystemExit("public_key.bin must be 32 bytes")

    pubkey_hash = hashlib.sha256(public_key).digest()
    PUBKEY_HASH_PATH.write_bytes(pubkey_hash)

    print(f"private key saved: {PRIVATE_KEY_PATH} ({PRIVATE_KEY_PATH.stat().st_size} bytes)")
    print(f"public key saved:  {PUBLIC_KEY_PATH} ({PUBLIC_KEY_PATH.stat().st_size} bytes)")
    print(f"pubkey hash saved: {PUBKEY_HASH_PATH} ({PUBKEY_HASH_PATH.stat().st_size} bytes)")
    print(f"pubkey hash:       {pubkey_hash.hex()}")

if __name__ == "__main__":
    main()
