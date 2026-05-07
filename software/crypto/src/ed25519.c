#include "ed25519.h"

/*
 * temporary ed25519 file.
 *
 * this is only here so the interface is ready.
 * real signature verification still needs to be added.
 *
 * algorithm reference:
 * RFC 8032, Edwards-Curve Digital Signature Algorithm.
 * https://datatracker.ietf.org/doc/html/rfc8032
 */

int ed25519_check(const uint8_t signature[ED25519_SIGNATURE_SIZE],
                  const uint8_t public_key[ED25519_PUBLIC_KEY_SIZE],
                  const uint8_t *message,
                  size_t message_size)
{
    (void)signature;
    (void)public_key;
    (void)message;
    (void)message_size;

    return 0;
}