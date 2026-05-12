from pathlib import Path
import subprocess
import tempfile
import sys

REPO = Path(__file__).resolve().parent.parent
MONO_C = REPO / "software" / "crypto" / "src" / "monocypher.c"
MONO_INCLUDE = REPO / "software" / "crypto" / "include"

HELPER_C = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "monocypher.h"

static int read_file(const char *path, uint8_t **out, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) return 1;

    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return 2;
    }

    long n = ftell(f);
    if (n < 0) {
        fclose(f);
        return 3;
    }

    rewind(f);

    uint8_t *buf = malloc((size_t)n ? (size_t)n : 1);
    if (!buf) {
        fclose(f);
        return 4;
    }

    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return 5;
    }

    fclose(f);

    *out = buf;
    *len = (size_t)n;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        return 10;
    }

    uint8_t *manifest = 0;
    uint8_t *signature = 0;
    uint8_t *public_key = 0;

    size_t manifest_len = 0;
    size_t signature_len = 0;
    size_t public_key_len = 0;

    if (read_file(argv[1], &manifest, &manifest_len) != 0) return 11;
    if (read_file(argv[2], &signature, &signature_len) != 0) return 12;
    if (read_file(argv[3], &public_key, &public_key_len) != 0) return 13;

    if (manifest_len != 96) return 20;
    if (signature_len != 64) return 21;
    if (public_key_len != 32) return 22;

    int rc = crypto_eddsa_check(signature, public_key, manifest, manifest_len);

    free(manifest);
    free(signature);
    free(public_key);

    return rc == 0 ? 0 : 30;
}
'''

def build_helper(tmp: Path) -> Path:
    helper_c = tmp / "secureboot_ed_verify.c"
    helper_bin = tmp / "secureboot_ed_verify"

    helper_c.write_text(HELPER_C)

    subprocess.check_call([
        "gcc",
        "-O2",
        "-I", str(MONO_INCLUDE),
        str(helper_c),
        str(MONO_C),
        "-o", str(helper_bin),
    ])

    return helper_bin

def main():
    if len(sys.argv) != 4:
        print("usage: verify_ed25519_from_files.py manifest.bin signature.bin public_key.bin", file=sys.stderr)
        return 10

    manifest = Path(sys.argv[1])
    signature = Path(sys.argv[2])
    public_key = Path(sys.argv[3])

    for p in [manifest, signature, public_key]:
        if not p.exists():
            print(f"missing file: {p}", file=sys.stderr)
            return 11

    with tempfile.TemporaryDirectory() as td:
        helper = build_helper(Path(td))
        rc = subprocess.call([str(helper), str(manifest), str(signature), str(public_key)])

    return rc

if __name__ == "__main__":
    raise SystemExit(main())
