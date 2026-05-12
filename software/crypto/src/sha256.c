#include "sha256.h"

/*
 * SHA-256 implementation for BootROM.
 *
 * Algorithm source:
 * NIST FIPS 180-4, Secure Hash Standard.
 * https://csrc.nist.gov/pubs/fips/180-4/upd1/final
 *
 * Interface/source reference:
 * RFC 6234, US Secure Hash Algorithms.
 * https://datatracker.ietf.org/doc/html/rfc6234
 */

#define ROTR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))

#define BIG0(x) (ROTR32((x), 2) ^ ROTR32((x), 13) ^ ROTR32((x), 22))
#define BIG1(x) (ROTR32((x), 6) ^ ROTR32((x), 11) ^ ROTR32((x), 25))
#define SMALL0(x) (ROTR32((x), 7) ^ ROTR32((x), 18) ^ ((x) >> 3))
#define SMALL1(x) (ROTR32((x), 17) ^ ROTR32((x), 19) ^ ((x) >> 10))

/* round constants from the SHA-256 standard */
static const uint32_t sha256_k[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

/* SHA-256 reads each 32-bit word in big-endian order */
static uint32_t load_be32(const uint8_t *data)
{
    return ((uint32_t)data[0] << 24) |
           ((uint32_t)data[1] << 16) |
           ((uint32_t)data[2] << 8) |
           ((uint32_t)data[3]);
}

/* final digest is written out in big-endian order */
static void store_be32(uint8_t *data, uint32_t value)
{
    data[0] = (uint8_t)(value >> 24);
    data[1] = (uint8_t)(value >> 16);
    data[2] = (uint8_t)(value >> 8);
    data[3] = (uint8_t)value;
}

/* processes one 64-byte SHA-256 block */
static void sha256_block(sha256_ctx *ctx, const uint8_t block[64])
{
    uint32_t w[64];
    uint32_t a;
    uint32_t b;
    uint32_t c;
    uint32_t d;
    uint32_t e;
    uint32_t f;
    uint32_t g;
    uint32_t h;

    /* first 16 words come straight from the input block */
    for (int i = 0; i < 16; i++) {
        w[i] = load_be32(block + (i * 4));
    }

    /* the rest of the schedule is expanded from earlier words */
    for (int i = 16; i < 64; i++) {
        w[i] = SMALL1(w[i - 2]) + w[i - 7] + SMALL0(w[i - 15]) + w[i - 16];
    }

    /* start this block from the current hash state */
    a = ctx->state[0];
    b = ctx->state[1];
    c = ctx->state[2];
    d = ctx->state[3];
    e = ctx->state[4];
    f = ctx->state[5];
    g = ctx->state[6];
    h = ctx->state[7];

    /* mix the block into the working state */
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + BIG1(e) + CH(e, f, g) + sha256_k[i] + w[i];
        uint32_t t2 = BIG0(a) + MAJ(a, b, c);

        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    /* add this block result back into the hash state */
    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
    ctx->state[5] += f;
    ctx->state[6] += g;
    ctx->state[7] += h;
}

/* resets the hash state before hashing a new message */
void sha256_init(sha256_ctx *ctx)
{
    ctx->state[0] = 0x6a09e667u;
    ctx->state[1] = 0xbb67ae85u;
    ctx->state[2] = 0x3c6ef372u;
    ctx->state[3] = 0xa54ff53au;
    ctx->state[4] = 0x510e527fu;
    ctx->state[5] = 0x9b05688cu;
    ctx->state[6] = 0x1f83d9abu;
    ctx->state[7] = 0x5be0cd19u;
    ctx->bit_len = 0;
    ctx->buffer_len = 0;
}

/* adds bytes to the current hash */
void sha256_update(sha256_ctx *ctx, const uint8_t *data, size_t len)
{
    while (len > 0) {
        size_t space = 64 - ctx->buffer_len;
        size_t take = len < space ? len : space;

        /* fill the current 64-byte block buffer */
        for (size_t i = 0; i < take; i++) {
            ctx->buffer[ctx->buffer_len + i] = data[i];
        }

        ctx->buffer_len += take;
        data += take;
        len -= take;

        /* once the buffer is full, process it */
        if (ctx->buffer_len == 64) {
            sha256_block(ctx, ctx->buffer);
            ctx->bit_len += 512;
            ctx->buffer_len = 0;
        }
    }
}

/* pads the last block and writes the final digest */
void sha256_final(sha256_ctx *ctx, uint8_t out[SHA256_DIGEST_SIZE])
{
    uint64_t total_bits = ctx->bit_len + ((uint64_t)ctx->buffer_len * 8);
    size_t i = ctx->buffer_len;

    /* SHA padding starts with one 1 bit */
    ctx->buffer[i++] = 0x80;

    /* if length will not fit, finish this block and start one more */
    if (i > 56) {
        while (i < 64) {
            ctx->buffer[i++] = 0;
        }

        sha256_block(ctx, ctx->buffer);
        i = 0;
    }

    /* pad with zeros until the length field */
    while (i < 56) {
        ctx->buffer[i++] = 0;
    }

    /* last 8 bytes store the total message length in bits */
    ctx->buffer[56] = (uint8_t)(total_bits >> 56);
    ctx->buffer[57] = (uint8_t)(total_bits >> 48);
    ctx->buffer[58] = (uint8_t)(total_bits >> 40);
    ctx->buffer[59] = (uint8_t)(total_bits >> 32);
    ctx->buffer[60] = (uint8_t)(total_bits >> 24);
    ctx->buffer[61] = (uint8_t)(total_bits >> 16);
    ctx->buffer[62] = (uint8_t)(total_bits >> 8);
    ctx->buffer[63] = (uint8_t)total_bits;

    sha256_block(ctx, ctx->buffer);

    /* copy the final 8 state words into the 32-byte digest */
    for (int i = 0; i < 8; i++) {
        store_be32(out + (i * 4), ctx->state[i]);
    }
}

/* one-shot helper for hashing one complete buffer */
void sha256_hash(const uint8_t *data, size_t len, uint8_t out[SHA256_DIGEST_SIZE])
{
    sha256_ctx ctx;

    sha256_init(&ctx);
    sha256_update(&ctx, data, len);
    sha256_final(&ctx, out);
}