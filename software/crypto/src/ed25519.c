#include "ed25519.h"
#include "monocypher.h"

int ed25519_check(const uint8_t signature[ED25519_SIGNATURE_SIZE],
                  const uint8_t public_key[ED25519_PUBLIC_KEY_SIZE],
                  const uint8_t *message,
                  size_t message_size)
{
    return crypto_eddsa_check(signature, public_key, message, message_size);
}
