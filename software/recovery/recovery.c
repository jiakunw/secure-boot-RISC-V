#include <stdio.h>
#include <stdint.h>

/* Must match bootrom.c. */
#define BOOT_STATUS_REG       0xF0003000UL
#define SR_MANIFEST_HEADER    (1u << 0)
#define SR_PUBLIC_KEY         (1u << 1)
#define SR_MANIFEST_SIGNATURE (1u << 2)
#define SR_LOAD_KERNEL        (1u << 3)
#define SR_ROLLBACK_COUNTER   (1u << 4)
#define SR_LOCK_PMP           (1u << 5)

int main(void) {
  uint32_t status = *(volatile uint32_t *)BOOT_STATUS_REG;

  printf("something went wrong, in recovery mode\n");
  printf("boot status register = 0x%08x\n", status);

  if (status & SR_MANIFEST_HEADER)
    printf("  - check_manifest_header failed (bit 0)\n");
  if (status & SR_PUBLIC_KEY)
    printf("  - check_public_key failed (bit 1) -- OTP root-of-trust mismatch\n");
  if (status & SR_MANIFEST_SIGNATURE)
    printf("  - check_manifest_signature failed (bit 2) -- Ed25519 invalid\n");
  if (status & SR_LOAD_KERNEL)
    printf("  - check_and_load_kernel failed (bit 3) -- kernel hash mismatch / bad params\n");
  if (status & SR_ROLLBACK_COUNTER)
    printf("  - check_rollback_counter failed (bit 4) -- version too old\n");
  if (status & SR_LOCK_PMP)
    printf("  - lock_pmp failed (bit 5)\n");
  if (status == 0)
    printf("  - (no bits set; BootROM jumped here without writing SR)\n");

  return 0;
}
