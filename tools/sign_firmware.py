from pathlib import Path
import subprocess
import tempfile

TOOL_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOL_DIR.parent

MONOCYPHER_C = REPO_ROOT / "software" / "crypto" / "src" / "monocypher.c"
MONOCYPHER_H_DIR = REPO_ROOT / "software" / "crypto" / "include"

PRIVATE_KEY_PATH = REPO_ROOT / "metadata" / "private_key.bin"
PUBLIC_KEY_PATH  = REPO_ROOT / "metadata" / "public_key.bin"
MANIFEST_PATH    = REPO_ROOT / "metadata" / "manifest.bin"
KERNEL_PATH      = REPO_ROOT / "software" / "kernel" / "kernel.bin"
SIGNATURE_PATH   = REPO_ROOT / "metadata" / "signature.bin"
FLASH_IMG_PATH   = REPO_ROOT / "flash_image" / "flash_image.bin"

HELPER_C = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    if (argc != 5) {
        return 10;
    }

    const char *private_key_path = argv[1];
    const char *public_key_path = argv[2];
    const char *manifest_path = argv[3];
    const char *signature_path = argv[4];

    uint8_t *secret_key = 0;
    uint8_t *public_key = 0;
    uint8_t *manifest = 0;

    size_t secret_key_len = 0;
    size_t public_key_len = 0;
    size_t manifest_len = 0;

    if (read_file(private_key_path, &secret_key, &secret_key_len) != 0) return 11;
    if (read_file(public_key_path, &public_key, &public_key_len) != 0) return 12;
    if (read_file(manifest_path, &manifest, &manifest_len) != 0) return 13;

    if (secret_key_len != 64) return 14;
    if (public_key_len != 32) return 15;
    if (manifest_len != 96) return 16;

    uint8_t signature[64];

    crypto_eddsa_sign(signature, secret_key, manifest, manifest_len);

    if (crypto_eddsa_check(signature, public_key, manifest, manifest_len) != 0) {
        return 17;
    }

    if (write_file(signature_path, signature, sizeof(signature)) != 0) {
        return 18;
    }

    free(secret_key);
    free(public_key);
    free(manifest);

    return 0;
}
'''

def build_helper(tmp: Path) -> Path:
    helper_c = tmp / "monocypher_sign.c"
    helper_bin = tmp / "monocypher_sign"
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

def read_exact(path: Path, n: int) -> bytes:
    if not path.exists():
        raise SystemExit(f"missing file: {path}")

    data = path.read_bytes()

    if len(data) != n:
        raise SystemExit(f"{path} must be {n} bytes, got {len(data)}")

    return data

def main():
    manifest = read_exact(MANIFEST_PATH, 96)
    public_key = read_exact(PUBLIC_KEY_PATH, 32)
    private_key = read_exact(PRIVATE_KEY_PATH, 64)

    if not KERNEL_PATH.exists():
        raise SystemExit(f"missing file: {KERNEL_PATH}")

    kernel = KERNEL_PATH.read_bytes()

    with tempfile.TemporaryDirectory() as td:
        helper = build_helper(Path(td))
        subprocess.check_call([
            str(helper),
            str(PRIVATE_KEY_PATH),
            str(PUBLIC_KEY_PATH),
            str(MANIFEST_PATH),
            str(SIGNATURE_PATH),
        ])

    signature = read_exact(SIGNATURE_PATH, 64)

    FLASH_IMG_PATH.parent.mkdir(parents=True, exist_ok=True)

    with FLASH_IMG_PATH.open("wb") as f:
        f.write(manifest)      # 0x0000 - 0x005f
        f.write(signature)     # 0x0060 - 0x009f
        f.write(public_key)    # 0x00a0 - 0x00bf
        f.write(kernel)        # 0x00c0 onward

    print(f"Signed manifest with MonoCypher-compatible EdDSA")
    print(f"Manifest:  {MANIFEST_PATH} ({len(manifest)} bytes)")
    print(f"Signature: {SIGNATURE_PATH} ({len(signature)} bytes)")
    print(f"PublicKey: {PUBLIC_KEY_PATH} ({len(public_key)} bytes)")
    print(f"Kernel:    {KERNEL_PATH} ({len(kernel)} bytes)")
    print(f"Flash:     {FLASH_IMG_PATH} ({FLASH_IMG_PATH.stat().st_size} bytes)")

if __name__ == "__main__":
    main()
