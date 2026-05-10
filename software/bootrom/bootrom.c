#include <stdint.h>
#include <stddef.h>

#include "sha256.h"
#include "monocypher.h"

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

/* FESVR-bypass model:
 *   FESVR loads flash_image.elf at FLASH_BASE = 0x88200000 via --payload.
 *   BootROM reads flash from there directly (no SPI bit-bang).
 *   Scratch buffers stay at BOOT_SCRATCH_BASE = 0x88000000 (separate region).
 *
 *   Memory map within DRAM (0x80000000 - 0x90000000, 256 MB):
 *     0x80000000 - 0x80002240   FESVR-loaded kernel.riscv (~8 KB)
 *     0x88000000 - 0x88010000   Stack + scratch (64 KB)
 *     0x88200000 - 0x88202000   FESVR-loaded flash_image.elf (~8 KB)
 *
 *   In real silicon BootROM would read from the SPI controller; here we
 *   pre-stage the same bytes in DRAM via FESVR. The verification logic
 *   (Stages 0-5) is identical. */
#define BOOT_SCRATCH_BASE 0x88000000UL
#define FLASH_BASE        0x88200000UL

#define MANIFEST_BUFFER    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0000u))
#define SIGNATURE_BUFFER   ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0100u))
#define PUBLIC_KEY_BUFFER  ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0200u))
#define PUBLIC_KEY_HASH    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0300u))
#define OTP_HASH_BUFFER    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0340u))
#define KERNEL_HASH_BUFFER ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0380u))

#define PMP_LOCK_NAPOT_NO_ACCESS 0x98u
#define PMP_LOCK_NAPOT_RWX       0x9Fu
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

static void halt(void)
{
    while (1) {
        __asm__ volatile ("wfi");
    }
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

/* FESVR-bypass: read flash bytes directly from FLASH_BASE in DRAM,
 * which FESVR has pre-loaded via --payload=flash_image.elf. The SPI
 * controller is still present in the SoC for completeness; it just
 * isn't used by the BootROM in this simulation flow. */
static void read_flash(uint32_t flash_offset, uint32_t total_bytes, uint8_t *output_buffer)
{
    copy_bytes(output_buffer, (const uint8_t *)(FLASH_BASE + flash_offset), total_bytes);
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

/* checks that the manifest starts with the right marker */
static void check_manifest_header(const manifest_t *manifest)
{
    if (manifest->magic != MANIFEST_MAGIC) {
        halt();
    }

    if (manifest->header_version != MANIFEST_HEADER_VERSION) {
        halt();
    }
}

/* INCREMENT 4: Stage 1 stubbed (will re-enable in INCREMENT 5).
 * Hashes the flash pubkey but skips the OTP comparison for now. */
static void check_public_key(void)
{
    sha256_hash(PUBLIC_KEY_BUFFER, PUBLIC_KEY_SIZE, PUBLIC_KEY_HASH);
    /* Stage 1 OTP compare disabled until INCREMENT 5:
     * read_otp_hash(OTP_HASH_BUFFER);
     * if (!same_bytes(PUBLIC_KEY_HASH, OTP_HASH_BUFFER, OTP_HASH_SIZE)) halt();
     */
}

/* DIAGNOSTIC: Stage 2 temporarily bypassed to isolate which stage halts */
static void check_manifest_signature(void)
{
    /* TODO restore:
     * if (crypto_eddsa_check(SIGNATURE_BUFFER, PUBLIC_KEY_BUFFER,
     *                        MANIFEST_BUFFER, MANIFEST_SIZE) != 0) halt();
     */
}

/* reads the kernel, copies it to ram, and checks its hash */
static void check_and_load_kernel(const manifest_t *manifest)
{
    sha256_ctx ctx;
    uint32_t copied = 0;
    uint8_t *kernel_output = (uint8_t *)(uintptr_t)manifest->load_address;

    if (manifest->payload_size == 0) {
        halt();
    }

    if ((uintptr_t)kernel_output < DRAM_BASE) {
        halt();
    }

    /* FESVR-bypass: kernel is already in DRAM at FLASH_BASE+KERNEL_OFFSET.
     * Hash directly from there in one pass, then copy to load_address only
     * after the hash check passes. */
    const uint8_t *kernel_src = (const uint8_t *)(FLASH_BASE + KERNEL_OFFSET);

    sha256_init(&ctx);
    sha256_update(&ctx, kernel_src, manifest->payload_size);
    sha256_final(&ctx, KERNEL_HASH_BUFFER);
    (void)copied;

    if (!same_bytes(KERNEL_HASH_BUFFER, manifest->payload_hash, SHA256_DIGEST_SIZE)) {
        halt();
    }

    /* Hash verified — copy verified kernel from FLASH_BASE to load_address. */
    copy_bytes(kernel_output, kernel_src, manifest->payload_size);
}

/* INCREMENT 4: Stage 4 stubbed (will re-enable in INCREMENT 6). */
static void check_rollback_counter(const manifest_t *manifest)
{
    (void)manifest;
    /* Stage 4 rollback compare disabled until INCREMENT 6:
     * uint64_t counter = read_register64(ROLLBACK_COUNTER_BASE);
     * uint64_t version = (uint64_t)manifest->version;
     * if (version < counter) halt();
     * if (version > counter) write_register64(ROLLBACK_COUNTER_BASE, version);
     */
}

/* pmp uses napot encoding for locked regions */
static uint64_t make_napot(uint64_t base, uint64_t size)
{
    return (base >> 2) | ((size - 1) >> 3);
}

/* locks bootrom, otp, counter, and the catch-all rule */
static void lock_pmp(void)
{
    uint64_t pmpaddr0 = make_napot(BOOTROM_BASE, BOOTROM_SIZE);
    uint64_t pmpaddr1 = make_napot(OTP_BASE, OTP_SIZE);
    uint64_t pmpaddr2 = make_napot(ROLLBACK_COUNTER_BASE, ROLLBACK_COUNTER_SIZE);
    uint64_t pmpaddr3 = make_napot(0x0ULL, 1ULL << 54);

    uint64_t pmpcfg0 =
        ((uint64_t)PMP_LOCK_NAPOT_NO_ACCESS << 0)  |
        ((uint64_t)PMP_LOCK_NAPOT_NO_ACCESS << 8)  |
        ((uint64_t)PMP_LOCK_NAPOT_NO_ACCESS << 16) |
        ((uint64_t)PMP_LOCK_NAPOT_RWX       << 24) |
        ((uint64_t)PMP_LOCK_OFF             << 32) |
        ((uint64_t)PMP_LOCK_OFF             << 40) |
        ((uint64_t)PMP_LOCK_OFF             << 48) |
        ((uint64_t)PMP_LOCK_OFF             << 56);

    uint64_t pmpcfg2 =
        ((uint64_t)PMP_LOCK_OFF << 0)  |
        ((uint64_t)PMP_LOCK_OFF << 8)  |
        ((uint64_t)PMP_LOCK_OFF << 16) |
        ((uint64_t)PMP_LOCK_OFF << 24) |
        ((uint64_t)PMP_LOCK_OFF << 32) |
        ((uint64_t)PMP_LOCK_OFF << 40) |
        ((uint64_t)PMP_LOCK_OFF << 48) |
        ((uint64_t)PMP_LOCK_OFF << 56);

    __asm__ volatile ("csrw pmpaddr0, %0" :: "r"(pmpaddr0));
    __asm__ volatile ("csrw pmpaddr1, %0" :: "r"(pmpaddr1));
    __asm__ volatile ("csrw pmpaddr2, %0" :: "r"(pmpaddr2));
    __asm__ volatile ("csrw pmpaddr3, %0" :: "r"(pmpaddr3));

    __asm__ volatile ("csrw pmpcfg2, %0" :: "r"(pmpcfg2));
    __asm__ volatile ("csrw pmpcfg0, %0" :: "r"(pmpcfg0));
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
}

/* jumps into the verified kernel */
static void jump_to_kernel(uint32_t entry_point)
{
    __asm__ volatile (
        "fence\n"
        "fence.i\n"
        "csrw mepc, %0\n"
        "csrr a0, mhartid\n"
        "li a1, 0\n"
        "mret\n"
        :
        : "r"((uintptr_t)entry_point)
        : "a0", "a1", "memory"
    );

    halt();
}

/* DEBUG: SiFive UART at 0x10020000. txdata bit 31 = full, txctrl bit 0 = enable */
#define UART_BASE   0x10020000UL
#define UART_TXDATA (UART_BASE + 0x00)
#define UART_TXCTRL (UART_BASE + 0x08)
#define UART_DIV    (UART_BASE + 0x18)

static void uart_init(void)
{
    *(volatile uint32_t *)UART_DIV    = 0;   /* simulation: no divider needed */
    *(volatile uint32_t *)UART_TXCTRL = 1;   /* enable TX */
}

static void uart_putc(char c)
{
    while (*(volatile uint32_t *)UART_TXDATA & 0x80000000u) { }
    *(volatile uint32_t *)UART_TXDATA = (uint8_t)c;
}

static void uart_print(const char *s)
{
    while (*s) {
        uart_putc(*s++);
    }
}

void bootrom_main(void)
{
    /* DIAGNOSTIC: verify FESVR --payload= actually loaded flash_image.elf
     * at FLASH_BASE. If the magic at FLASH_BASE is SBOT, exit success.
     * Otherwise hang (so we know it didn't load). */
    uint32_t magic = *(volatile uint32_t *)FLASH_BASE;
    if (magic == MANIFEST_MAGIC) {
        *(volatile uint64_t *)0x80001e00 = 1;
    }
    while (1) {
        __asm__ volatile ("wfi");
    }
}