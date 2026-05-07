#ifndef ED25519_H
#define ED25519_H

#include <stdint.h>
#include <stddef.h>

#define ED25519_SIGNATURE_SIZE 64
#define ED25519_PUBLIC_KEY_SIZE 32

int ed25519_check(const uint8_t signature[ED25519_SIGNATURE_SIZE],
                  const uint8_t public_key[ED25519_PUBLIC_KEY_SIZE],
                  const uint8_t *message,
                  size_t message_size);

#endif