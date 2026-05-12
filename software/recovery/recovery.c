#include <stdint.h>

/* DIAGNOSTIC RECOVERY — no printf, no htif_nano runtime activity.
 *
 * Purpose: BootROM mret's here on verification failure. We want to prove
 * recovery._start (the htif_nano crt0) completed and main() was reached,
 * by exiting the sim with an exit code that encodes:
 *   - 0x40 marker bit  ("recovery's main() was reached")
 *   - SR contents      (which BootROM stage failed)
 *
 * If we see exit code 0x41 in tempered-manifest-header test:
 *   recovery main() ran, crt0 was fine, the original printf-based
 *   recovery was hanging in htif_nano's putc protocol, not in startup.
 *
 * If sim hangs:
 *   recovery's crt0 hung somewhere before reaching main().
 *
 * If we see exit code 0x80:
 *   BootROM's mret_trap_exit safety net fired — mret itself trapped,
 *   recovery code never started.
 */

#define BOOT_STATUS_REG       0xF0003000UL

/* Match kernel.riscv's tohost address (forced via Makefile --defsym so the
 * linker resolves recovery's references to the same address FESVR's
 * htif_t watcher polls from kernel.riscv's symbol table). */
#define KERNEL_TOHOST_ADDR    0x80001e00UL

int main(void) {
    /* Read SR (MMIO — bypasses cache). */
    uint32_t status = *(volatile uint32_t *)BOOT_STATUS_REG;

    /* Encode: low 6 bits = SR contents, bit 6 = "recovery main reached". */
    uint64_t encoded = (uint64_t)(status | 0x40u);
    uint64_t exit_val = (encoded << 1) | 1ULL;

    volatile uint64_t *tohost   = (volatile uint64_t *)KERNEL_TOHOST_ADDR;
    volatile uint64_t *fromhost = (volatile uint64_t *)(KERNEL_TOHOST_ADDR + 8);

    /* Same loop pattern as BootROM's enter_recovery and riscv-pk's _exit. */
    for (;;) {
        *fromhost = 0;
        *tohost   = exit_val;
    }
}
