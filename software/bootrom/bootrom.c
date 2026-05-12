#include <stdint.h>
#include <stddef.h>

#include "sha256.h"
#include "monocypher.h"

#define ED25519_VERIFY_BASE 0xF0004000UL
#define ED25519_CMD        (ED25519_VERIFY_BASE + 0x00)
#define ED25519_STATUS     (ED25519_VERIFY_BASE + 0x04)
#define ED25519_COUNT      (ED25519_VERIFY_BASE + 0x08)
#define ED25519_DATA       (ED25519_VERIFY_BASE + 0x0c)

#define ED25519_CMD_CLEAR  0x1u
#define ED25519_CMD_START  0x2u

#define ED25519_BUSY       (1u << 0)
#define ED25519_DONE       (1u << 1)
#define ED25519_PASS       (1u << 2)
#define ED25519_ERROR      (1u << 3)


#define SPI_BASE      0xF0002000UL
#define SPI_ADDR      (SPI_BASE + 0x00)
#define SPI_LEN       (SPI_BASE + 0x04)
#define SPI_COMMAND   (SPI_BASE + 0x08)
#define SPI_STATUS    (SPI_BASE + 0x0C)
#define SPI_DATA      (SPI_BASE + 0x10)
#define SPI_REMAINING (SPI_BASE + 0x14)

#define SPI_START_READ 0x1
#define SPI_CLEAR_DONE 0x2

#define SPI_BUSY       (1u << 0)
#define SPI_DONE       (1u << 1)
#define SPI_ERROR      (1u << 2)
#define SPI_DATA_READY (1u << 3)

#define OTP_BASE      0xF0000000UL
#define OTP_HASH_SIZE 32u

#define ROLLBACK_COUNTER_BASE 0xF0001000UL




/* Boot status register: BootROM writes which stage failed (one bit per
 * stage); recovery firmware reads to report root cause. */
#define BOOT_STATUS_REG       0xF0003000UL
#define SR_MANIFEST_HEADER    (1u << 0)
#define SR_PUBLIC_KEY         (1u << 1)
#define SR_MANIFEST_SIGNATURE (1u << 2)
#define SR_LOAD_KERNEL        (1u << 3)
#define SR_ROLLBACK_COUNTER   (1u << 4)
#define SR_LOCK_PMP           (1u << 5)

#define MANIFEST_OFFSET   0x00000u
#define SIGNATURE_OFFSET  0x00060u
#define PUBLIC_KEY_OFFSET 0x000A0u
#define KERNEL_OFFSET     0x000C0u

#define MANIFEST_SIZE   96u
#define SIGNATURE_SIZE  64u
#define PUBLIC_KEY_SIZE 32u

#define MANIFEST_MAGIC          0x54424F53u
#define MANIFEST_HEADER_VERSION 1u

#define BOOTROM_BASE 0x10000UL
#define BOOTROM_SIZE 0x10000UL

#define OTP_SIZE              0x20UL
#define ROLLBACK_COUNTER_SIZE 0x8UL

#define DRAM_BASE 0x80000000UL

#define BOOT_SCRATCH_BASE 0x81000000UL

#define MANIFEST_BUFFER    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0000u))
#define SIGNATURE_BUFFER   ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0100u))
#define PUBLIC_KEY_BUFFER  ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0200u))
#define PUBLIC_KEY_HASH    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0300u))
#define OTP_HASH_BUFFER    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0340u))
#define KERNEL_HASH_BUFFER ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0380u))
#define KERNEL_CHUNK       ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0400u))

#define KERNEL_CHUNK_SIZE 512u
#define MAX_SPIN 10000000u

#define PMP_LOCK_NAPOT_NO_ACCESS 0x98u   /* L=1, NAPOT, ---  */
#define PMP_LOCK_NAPOT_RX        0x9Du   /* L=1, NAPOT, R-X  (M-mode can execute) */
#define PMP_LOCK_NAPOT_RWX       0x9Fu   /* L=1, NAPOT, RWX  */
#define PMP_LOCK_OFF             0x80u

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t header_version;
    uint16_t flags;
    uint32_t version;
    uint32_t payload_size;
    uint32_t load_address;
    uint32_t entry_point;
    uint32_t reserved;
    uint32_t pad;
    uint8_t payload_hash[32];
    uint8_t next_pubkey_hash[32];
} manifest_t;


/* rollback + PMP implementation constants */

#ifndef ROLLBACK_COUNTER_BASE
#define ROLLBACK_COUNTER_BASE 0xF0001000UL
#endif

#ifndef SR_ROLLBACK_COUNTER
#ifdef SR_ROLLBACK
#define SR_ROLLBACK_COUNTER SR_ROLLBACK
#else
#define SR_ROLLBACK_COUNTER (1u << 4)
#endif
#endif

#ifndef SR_PMP_LOCK
#ifdef SR_PMP
#define SR_PMP_LOCK SR_PMP
#else
#define SR_PMP_LOCK (1u << 5)
#endif
#endif

/*
 * PMP regions used at handoff.
 *
 * BootROM is locked X-only, not no-access, because the CPU is still fetching
 * from BootROM while these CSRs are programmed. OTP/rollback/SPI/status/Ed
 * verifier are locked no-access as one secure MMIO window. DRAM is locked RWX
 * so the verified kernel can run normally.
 */
#define BOOTROM_PROTECT_BASE       0x00010000UL
#define BOOTROM_PROTECT_SIZE       0x00010000UL

#define SECURE_MMIO_PROTECT_BASE   0xF0000000UL
#define SECURE_MMIO_PROTECT_SIZE   0x00010000UL

#define DRAM_PROTECT_BASE          0x80000000UL
#define DRAM_PROTECT_SIZE          0x10000000UL

#define PMP_R                      0x01UL
#define PMP_W                      0x02UL
#define PMP_X                      0x04UL
#define PMP_A_NAPOT                0x18UL
#define PMP_L                      0x80UL

#define PMP_CFG_LOCKED_X_ONLY      (PMP_L | PMP_A_NAPOT | PMP_X)
#define PMP_CFG_LOCKED_NO_ACCESS   (PMP_L | PMP_A_NAPOT)
#define PMP_CFG_LOCKED_RWX         (PMP_L | PMP_A_NAPOT | PMP_R | PMP_W | PMP_X)


static void halt(void)
{
    while (1) {
        __asm__ volatile ("wfi");
    }
}

/* Recovery firmware entry point. Lives at 0x80100000 in DRAM and is loaded
 * by FESVR from a separately-built ELF (software/recovery/recovery.riscv).
 * This emulates the production secure-boot pattern where verification
 * failure hands control to a signed recovery image that lives in its own
 * flash partition. */
#define RECOVERY_ENTRY 0x80100000UL

/* Read-modify-write the status register so successive failures accumulate
 * (we set 1 bit per stage; recovery firmware can inspect all of them). */
static void set_status(uint32_t bit)
{
    uint32_t cur = *(volatile uint32_t *)BOOT_STATUS_REG;
    *(volatile uint32_t *)BOOT_STATUS_REG = cur | bit;
    __asm__ volatile ("fence rw, rw" ::: "memory");
}

/* Kernel's HTIF `tohost` symbol address (from
 *   `riscv64-unknown-elf-nm software/kernel/kernel.riscv | grep tohost`).
 * FESVR polls this address; writing `(code << 1) | 1` here tells FESVR
 * to call $finish with exit code `code`. We use this as a fail-safe so
 * the sim ALWAYS exits cleanly on verification failure — even if the
 * recovery image isn't reachable (e.g., FESVR didn't load it via
 * `+payload=`, or recovery's own console is unreachable). */

/* Trap-exit safety stub. If mret-to-recovery in enter_recovery() traps
 * (illegal instr at 0x80100000 because recovery isn't loaded, PMP fault,
 * ...), CPU lands here via mtvec. Writes tohost with marker = 0x80 so
 * the test runner can distinguish "mret trapped" from "recovery main
 * reached" (0x40) and "BootROM-only exit" (0x00). */
extern void mret_trap_exit(void) __attribute__((aligned(4), naked));
__attribute__((naked, aligned(4)))
void mret_trap_exit(void)
{
    __asm__ volatile (
        "li   t0, 0x80001e08\n"
        "li   t1, 0x80001e00\n"
        "li   t2, 0x101\n"          /* (0x80 << 1) | 1 */
        "1:\n"
        "  sd t2, 0(t1)\n"
        "  sd zero, 0(t0)\n"
        "  j 1b\n"
        ::: "t0", "t1", "t2", "memory"
    );
}

/* On verification failure: record which stage failed in the SR, then
 * `mret` to the recovery firmware at 0x80100000. Safety net: mtvec
 * pre-armed to mret_trap_exit so a faulting mret exits sim cleanly with
 * a distinguishable code (0x80) instead of trapping back into _start
 * and looping. */
static __attribute__((noreturn)) void enter_recovery(uint32_t reason_bit)
{
    set_status(reason_bit);

    __asm__ volatile (
        "la   t0, mret_trap_exit\n"
        "csrw mtvec, t0\n"
        "fence\n"
        "fence.i\n"
        "csrw mepc, %0\n"
        "csrr a0, mhartid\n"
        "li   a1, 0\n"
        "mret\n"
        :
        : "r"((uintptr_t)RECOVERY_ENTRY)
        : "t0", "a0", "a1", "memory"
    );

    __builtin_unreachable();
}

/* freestanding memset / memcpy for MonoCypher under -nostdlib; volatile pointers
 * prevent GCC from replacing the loop with a self-recursive call to memset */
void *memset(void *dst, int value, size_t total_bytes)
{
    volatile uint8_t *output = (volatile uint8_t *)dst;
    for (size_t i = 0; i < total_bytes; i++) {
        output[i] = (uint8_t)value;
    }
    return dst;
}

void *memcpy(void *dst, const void *src, size_t total_bytes)
{
    volatile uint8_t *output = (volatile uint8_t *)dst;
    const volatile uint8_t *input = (const volatile uint8_t *)src;
    for (size_t i = 0; i < total_bytes; i++) {
        output[i] = input[i];
    }
    return dst;
}

/* writes one word to a hardware register */
static void write_register(uintptr_t address, uint32_t value)
{
    *(volatile uint32_t *)address = value;
}

/* reads one word from a hardware register */
static uint32_t read_register(uintptr_t address)
{
    return *(volatile uint32_t *)address;
}

/* writes one double word to a hardware register */
static void write_register64(uintptr_t address, uint64_t value)
{
    *(volatile uint64_t *)address = value;
}

/* reads one double word from a hardware register */
static uint64_t read_register64(uintptr_t address)
{
    return *(volatile uint64_t *)address;
}
/* compares all bytes before deciding */
static int same_bytes(const uint8_t *left, const uint8_t *right, uint32_t total_bytes)
{
    uint8_t diff = 0;

    for (uint32_t i = 0; i < total_bytes; i++) {
        diff |= left[i] ^ right[i];
    }

    return diff == 0;
}

/* clears one memory range before leaving bootrom */
static void clear_bytes(uint8_t *buffer, uint32_t total_bytes)
{
    volatile uint8_t *clean_buffer = (volatile uint8_t *)buffer;

    for (uint32_t i = 0; i < total_bytes; i++) {
        clean_buffer[i] = 0;
    }
}

/* copies bytes without libc */
static void copy_bytes(uint8_t *output_buffer, const uint8_t *input_buffer, uint32_t total_bytes)
{
    for (uint32_t i = 0; i < total_bytes; i++) {
        output_buffer[i] = input_buffer[i];
    }
}

/* starts one flash read through the spi controller */
static void start_flash_read(uint32_t flash_offset, uint32_t total_bytes)
{
    write_register(SPI_ADDR, flash_offset);
    write_register(SPI_LEN, total_bytes);
    write_register(SPI_COMMAND, SPI_CLEAR_DONE);
    write_register(SPI_COMMAND, SPI_START_READ);
}

/* copies returned spi words into the buffer */
static void read_flash_words(uint8_t *output_buffer, uint32_t total_bytes)
{
    uint32_t bytes_read = 0;

    uint32_t spin = 0;

    while (bytes_read < total_bytes) {
        uint32_t status = read_register(SPI_STATUS);

        if ((status & SPI_ERROR) != 0) {
            enter_recovery(SR_LOAD_KERNEL);
        }

        if ((status & SPI_DATA_READY) == 0) {
            spin++;
            if (spin > MAX_SPIN) {
                enter_recovery(SR_LOAD_KERNEL);
            }
            continue;
        }

        spin = 0;

        uint32_t word = read_register(SPI_DATA);

        for (int i = 0; i < 4 && bytes_read < total_bytes; i++) {
            output_buffer[bytes_read] = (uint8_t)(word >> (8 * i));
            bytes_read++;
        }
    }

    spin = 0;
    while ((read_register(SPI_STATUS) & SPI_DONE) == 0) {
        spin++;
        if (spin > MAX_SPIN) {
            enter_recovery(SR_LOAD_KERNEL);
        }
    }
}

/* reads bytes from flash into one buffer */
static void read_flash(uint32_t flash_offset, uint32_t total_bytes, uint8_t *output_buffer)
{
    start_flash_read(flash_offset, total_bytes);
    read_flash_words(output_buffer, total_bytes);
}

/* pulls the fixed boot image pieces from flash */
static void read_boot_parts(void)
{
    read_flash(MANIFEST_OFFSET, MANIFEST_SIZE, MANIFEST_BUFFER);
    read_flash(SIGNATURE_OFFSET, SIGNATURE_SIZE, SIGNATURE_BUFFER);
    read_flash(PUBLIC_KEY_OFFSET, PUBLIC_KEY_SIZE, PUBLIC_KEY_BUFFER);
}

/* reads the trusted public key hash from otp */
static void read_otp_hash(uint8_t *output_buffer)
{
    for (uint32_t i = 0; i < OTP_HASH_SIZE; i += 4) {
        uint32_t word = read_register(OTP_BASE + i);

        output_buffer[i + 0] = (uint8_t)(word >> 0);
        output_buffer[i + 1] = (uint8_t)(word >> 8);
        output_buffer[i + 2] = (uint8_t)(word >> 16);
        output_buffer[i + 3] = (uint8_t)(word >> 24);
    }
}

/* Stage 0: manifest magic + header version. Mismatch = boot image not for
 * us or actively replaced -> hand off to recovery firmware. */
static void check_manifest_header(const manifest_t *manifest)
{
    if (manifest->magic != MANIFEST_MAGIC) {
        enter_recovery(SR_MANIFEST_HEADER);
    }

    if (manifest->header_version != MANIFEST_HEADER_VERSION) {
        enter_recovery(SR_MANIFEST_HEADER);
    }
}

/* Stage 1: hash the flash-resident public key with SHA-256 and compare
 * against the hash burned into OTP at manufacturing. OTP is the hardware
 * root of trust — a mismatch is a strong tampering signal. On mismatch
 * we hand off to the recovery firmware (loaded at 0x80100000). */
static void check_public_key(void)
{
    sha256_hash(PUBLIC_KEY_BUFFER, PUBLIC_KEY_SIZE, PUBLIC_KEY_HASH);
    read_otp_hash(OTP_HASH_BUFFER);
    if (!same_bytes(PUBLIC_KEY_HASH, OTP_HASH_BUFFER, OTP_HASH_SIZE)) {
        enter_recovery(SR_PUBLIC_KEY);
    }
}

/* Stage 2: verify that the manifest was signed by the trusted key.
 * The public key itself was already checked against OTP in Stage 1.
 *
 * The Ed25519/EdDSA curve operation is exposed as an MMIO verifier so the
 * secure-boot stage remains real but does not stall the Rocket core under
 * Verilator for minutes. The verifier checks signature/public key/message
 * and returns pass/fail.
 */
static void ed25519_write_bytes(const uint8_t *data, uint32_t n)
{
    for (uint32_t i = 0; i < n; i += 4) {
        uint32_t word = 0;

        word |= ((uint32_t)data[i + 0]) << 0;
        word |= ((uint32_t)data[i + 1]) << 8;
        word |= ((uint32_t)data[i + 2]) << 16;
        word |= ((uint32_t)data[i + 3]) << 24;

        write_register(ED25519_DATA, word);
    }
}

static void check_manifest_signature(void)
{
    uint32_t spin = 0;

    write_register(ED25519_CMD, ED25519_CMD_CLEAR);

    ed25519_write_bytes(MANIFEST_BUFFER, MANIFEST_SIZE);
    ed25519_write_bytes(SIGNATURE_BUFFER, SIGNATURE_SIZE);
    ed25519_write_bytes(PUBLIC_KEY_BUFFER, PUBLIC_KEY_SIZE);

    write_register(ED25519_CMD, ED25519_CMD_START);

    while (1) {
        uint32_t status = read_register(ED25519_STATUS);

        if ((status & ED25519_ERROR) != 0) {
            enter_recovery(SR_MANIFEST_SIGNATURE);
        }

        if ((status & ED25519_DONE) != 0) {
            if ((status & ED25519_PASS) != 0) {
                return;
            }

            enter_recovery(SR_MANIFEST_SIGNATURE);
        }

        spin++;
        if (spin > MAX_SPIN) {
            enter_recovery(SR_MANIFEST_SIGNATURE);
        }
    }
}





/* Stage 3: read the whole kernel from flash into DRAM.
 * One SPI transaction avoids the old repeated-read hang.
 * Hash the DRAM copy because those are the bytes we jump into. */
static void check_and_load_kernel(const manifest_t *manifest)
{
    uint8_t *kernel_output = (uint8_t *)(uintptr_t)manifest->load_address;

    if (manifest->payload_size == 0) {
        enter_recovery(SR_LOAD_KERNEL);
    }

    if ((uintptr_t)kernel_output < DRAM_BASE) {
        enter_recovery(SR_LOAD_KERNEL);
    }

    /*
     * Read the whole kernel in one SPI transaction.
     *
     * The old version did many 512-byte SPI transactions. That keeps the
     * secure-boot behavior correct in theory, but it stresses the SPI
     * start/done handshake and can hang before the kernel handoff.
     *
     * This still follows the README flow:
     *   flash kernel -> DRAM load_address
     *   hash loaded kernel
     *   compare hash to manifest
     *   only then jump
     */
    read_flash(KERNEL_OFFSET, manifest->payload_size, kernel_output);

    sha256_hash(kernel_output, manifest->payload_size, KERNEL_HASH_BUFFER);

    if (!same_bytes(KERNEL_HASH_BUFFER, manifest->payload_hash, SHA256_DIGEST_SIZE)) {
        enter_recovery(SR_LOAD_KERNEL);
    }
}


/* INCREMENT 4: Stage 4 stubbed (will re-enable in INCREMENT 6). */

static uintptr_t pmp_napot_addr(uintptr_t base, uintptr_t size)
{
    return (base >> 2) | ((size >> 3) - 1);
}

static void csr_write_pmpaddr0(uintptr_t value)
{
    asm volatile ("csrw pmpaddr0, %0" :: "r"(value) : "memory");
}

static void csr_write_pmpaddr1(uintptr_t value)
{
    asm volatile ("csrw pmpaddr1, %0" :: "r"(value) : "memory");
}

static void csr_write_pmpaddr2(uintptr_t value)
{
    asm volatile ("csrw pmpaddr2, %0" :: "r"(value) : "memory");
}

static uintptr_t csr_read_pmpaddr0(void)
{
    uintptr_t value;
    asm volatile ("csrr %0, pmpaddr0" : "=r"(value));
    return value;
}

static uintptr_t csr_read_pmpaddr1(void)
{
    uintptr_t value;
    asm volatile ("csrr %0, pmpaddr1" : "=r"(value));
    return value;
}

static uintptr_t csr_read_pmpaddr2(void)
{
    uintptr_t value;
    asm volatile ("csrr %0, pmpaddr2" : "=r"(value));
    return value;
}

static void csr_write_pmpcfg0(uintptr_t value)
{
    asm volatile ("csrw pmpcfg0, %0" :: "r"(value) : "memory");
}

static uintptr_t csr_read_pmpcfg0(void)
{
    uintptr_t value;
    asm volatile ("csrr %0, pmpcfg0" : "=r"(value));
    return value;
}

static void boot_fence_all(void)
{
    asm volatile ("fence" ::: "memory");
    asm volatile ("fence.i" ::: "memory");
}



static void secure_memzero(void *ptr, uint32_t n)
{
    volatile uint8_t *p = (volatile uint8_t *)ptr;

    for (uint32_t i = 0; i < n; i++) {
        p[i] = 0;
    }
}

static void clear_boot_scratch(void)
{
    secure_memzero(MANIFEST_BUFFER, MANIFEST_SIZE);
    secure_memzero(SIGNATURE_BUFFER, SIGNATURE_SIZE);
    secure_memzero(PUBLIC_KEY_BUFFER, PUBLIC_KEY_SIZE);
    secure_memzero(PUBLIC_KEY_HASH, SHA256_DIGEST_SIZE);
    secure_memzero(OTP_HASH_BUFFER, SHA256_DIGEST_SIZE);
    secure_memzero(KERNEL_HASH_BUFFER, SHA256_DIGEST_SIZE);
    secure_memzero(KERNEL_CHUNK, KERNEL_CHUNK_SIZE);
}


static int check_rollback_counter(const manifest_t *manifest)
{
    uint64_t stored_version = read_register64(ROLLBACK_COUNTER_BASE);
    uint64_t image_version = (uint64_t)manifest->version;

    if (image_version < stored_version) {
        enter_recovery(SR_ROLLBACK_COUNTER);
        return -1;
    }

    if (image_version > stored_version) {
        write_register64(ROLLBACK_COUNTER_BASE, image_version);

        /*
         * The hardware counter is monotonic: it should either advance to the
         * requested version or already contain a newer value. Anything below
         * image_version means rollback protection did not latch correctly.
         */
        uint64_t updated_version = read_register64(ROLLBACK_COUNTER_BASE);

        if (updated_version < image_version) {
            enter_recovery(SR_ROLLBACK_COUNTER);
            return -1;
        }
    }

    return 0;
}


/* pmp uses napot encoding for locked regions */
static uint64_t make_napot(uint64_t base, uint64_t size)
{
    return (base >> 2) | ((size - 1) >> 3);
}

/* Stage 5: lock OTP / counter / BootROM with PMP.
 * BootROM stays RX so the handoff code can still run after the lock. */
static int lock_pmp(void)
{
    uintptr_t bootrom_addr = pmp_napot_addr(BOOTROM_PROTECT_BASE, BOOTROM_PROTECT_SIZE);
    uintptr_t secure_mmio_addr = pmp_napot_addr(SECURE_MMIO_PROTECT_BASE, SECURE_MMIO_PROTECT_SIZE);
    uintptr_t dram_addr = pmp_napot_addr(DRAM_PROTECT_BASE, DRAM_PROTECT_SIZE);

    uintptr_t cfg =
        ((uintptr_t)PMP_CFG_LOCKED_X_ONLY    << 0)  |
        ((uintptr_t)PMP_CFG_LOCKED_NO_ACCESS << 8)  |
        ((uintptr_t)PMP_CFG_LOCKED_RWX       << 16);

    /*
     * Program addresses first, then lock the config.
     * Once L is set in pmpcfg0, these entries cannot be changed until reset.
     */
    csr_write_pmpaddr0(bootrom_addr);
    csr_write_pmpaddr1(secure_mmio_addr);
    csr_write_pmpaddr2(dram_addr);

    boot_fence_all();

    csr_write_pmpcfg0(cfg);

    boot_fence_all();

    if (csr_read_pmpaddr0() != bootrom_addr ||
        csr_read_pmpaddr1() != secure_mmio_addr ||
        csr_read_pmpaddr2() != dram_addr) {
        enter_recovery(SR_PMP_LOCK);
        return -1;
    }

    if ((csr_read_pmpcfg0() & 0x00ffffffUL) != (cfg & 0x00ffffffUL)) {
        enter_recovery(SR_PMP_LOCK);
        return -1;
    }

    return 0;
}


/* clears scratch data before leaving bootrom */
static void clear_scratch(void)
{
    clear_bytes(MANIFEST_BUFFER, MANIFEST_SIZE);
    clear_bytes(SIGNATURE_BUFFER, SIGNATURE_SIZE);
    clear_bytes(PUBLIC_KEY_BUFFER, PUBLIC_KEY_SIZE);
    clear_bytes(PUBLIC_KEY_HASH, SHA256_DIGEST_SIZE);
    clear_bytes(OTP_HASH_BUFFER, OTP_HASH_SIZE);
    clear_bytes(KERNEL_HASH_BUFFER, SHA256_DIGEST_SIZE);
    clear_bytes(KERNEL_CHUNK, KERNEL_CHUNK_SIZE);
}

/* jumps into the verified kernel */
static void jump_to_kernel(uintptr_t entry_point)
{
    __asm__ volatile (
        "fence\n"
        "fence.i\n"
        "csrw mepc, %0\n"
        "li t0, 0x1800\n"
        "csrs mstatus, t0\n"
        "csrr a0, mhartid\n"
        "li a1, 0\n"
        "mret\n"
        :
        : "r"(entry_point)
        : "a0", "a1", "memory"
    );

    halt();
}

void bootrom_main(void)
{
    manifest_t *manifest = (manifest_t *)MANIFEST_BUFFER;
    uintptr_t entry_point;

    read_boot_parts();
    check_manifest_header(manifest);
    check_public_key();
    check_manifest_signature();
    check_and_load_kernel(manifest);

    if (check_rollback_counter(manifest) != 0) {
        enter_recovery(SR_ROLLBACK_COUNTER);
    }

    entry_point = manifest->entry_point;

    clear_scratch();
    if (lock_pmp() != 0) {
        enter_recovery(SR_PMP_LOCK);
    }

    clear_boot_scratch();
    boot_fence_all();
    jump_to_kernel(entry_point);
    halt();
}
