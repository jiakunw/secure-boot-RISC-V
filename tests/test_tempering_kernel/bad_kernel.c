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
    say("bad kernel!\n");

    return 0;
}
