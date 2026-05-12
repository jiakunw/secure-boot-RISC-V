#include <stdint.h>
#include <unistd.h>
#include <string.h>

/* Must match bootrom.c. */
#define BOOT_STATUS_REG       0xF0003000UL
#define SR_MANIFEST_HEADER    (1u << 0)
#define SR_PUBLIC_KEY         (1u << 1)
#define SR_MANIFEST_SIGNATURE (1u << 2)
#define SR_LOAD_KERNEL        (1u << 3)
#define SR_ROLLBACK_COUNTER   (1u << 4)
#define SR_LOCK_PMP           (1u << 5)

/* Direct write() instead of printf to bypass newlib's stdio lazy init,
 * which traps in our sim configuration (see PROGRESS.md). write() goes
 * straight through htif_syscall to FESVR's SYS_write handler. */

static void say(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    write(1, s, n);
}

static void say_hex32(uint32_t v) {
    char buf[11] = "0x00000000";
    for (int i = 0; i < 8; i++) {
        unsigned nib = (v >> ((7 - i) * 4)) & 0xf;
        buf[2 + i] = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
    }
    write(1, buf, 10);
}

int main(void) {
    uint32_t status = *(volatile uint32_t *)BOOT_STATUS_REG;

    say("something went wrong, in recovery mode\n");
    say("boot status register = ");
    say_hex32(status);
    say("\n");

    if (status & SR_MANIFEST_HEADER)
        say("  - check_manifest_header failed (bit 0)\n");
    if (status & SR_PUBLIC_KEY)
        say("  - check_public_key failed (bit 1) -- OTP root-of-trust mismatch\n");
    if (status & SR_MANIFEST_SIGNATURE)
        say("  - check_manifest_signature failed (bit 2) -- Ed25519 invalid\n");
    if (status & SR_LOAD_KERNEL)
        say("  - check_and_load_kernel failed (bit 3) -- kernel hash mismatch / bad params\n");
    if (status & SR_ROLLBACK_COUNTER)
        say("  - check_rollback_counter failed (bit 4) -- version too old\n");
    if (status & SR_LOCK_PMP)
        say("  - lock_pmp failed (bit 5)\n");
    if (status == 0)
        say("  - (no bits set; BootROM jumped here without writing SR)\n");

    return 0;
}
