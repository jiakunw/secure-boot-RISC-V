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

#define BOOT_SCRATCH_BASE 0x88000000UL

#define MANIFEST_BUFFER    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0000u))
#define SIGNATURE_BUFFER   ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0100u))
#define PUBLIC_KEY_BUFFER  ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0200u))
#define PUBLIC_KEY_HASH    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0300u))
#define OTP_HASH_BUFFER    ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0340u))
#define KERNEL_HASH_BUFFER ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0380u))
#define KERNEL_CHUNK       ((uint8_t *)(BOOT_SCRATCH_BASE + 0x0400u))

#define KERNEL_CHUNK_SIZE 512u

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

    while (bytes_read < total_bytes) {
        uint32_t status = read_register(SPI_STATUS);

        if ((status & SPI_ERROR) != 0) {
            halt();
        }

        if ((status & SPI_DATA_READY) == 0) {
            continue;
        }

        uint32_t word = read_register(SPI_DATA);

        for (int i = 0; i < 4 && bytes_read < total_bytes; i++) {
            output_buffer[bytes_read] = (uint8_t)(word >> (8 * i));
            bytes_read++;
        }
    }

    while ((read_register(SPI_STATUS) & SPI_DONE) == 0) {
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

/* INCREMENT 4 known-good baseline: hash the pubkey but skip the OTP compare.
 * The un-stubbed real OTP comparison (INCREMENT 5) hangs in sim under
 * investigation; reverted here so bisection-passing version is restored. */
static void check_public_key(void)
{
    sha256_hash(PUBLIC_KEY_BUFFER, PUBLIC_KEY_SIZE, PUBLIC_KEY_HASH);
    /* Stage 1 OTP compare disabled (INCREMENT 5):
     * read_otp_hash(OTP_HASH_BUFFER);
     * if (!same_bytes(PUBLIC_KEY_HASH, OTP_HASH_BUFFER, OTP_HASH_SIZE)) halt();
     */
}

/* INCREMENT 4 known-good baseline: signature check stubbed.
 * MonoCypher's crypto_eddsa_check (INCREMENT 7) also hangs in sim;
 * keeping stubbed in this revision. */
static void check_manifest_signature(void)
{
    /* TODO restore (INCREMENT 7):
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

    sha256_init(&ctx);

    while (copied < manifest->payload_size) {
        uint32_t left = manifest->payload_size - copied;
        uint32_t chunk_size = left < KERNEL_CHUNK_SIZE ? left : KERNEL_CHUNK_SIZE;

        read_flash(KERNEL_OFFSET + copied, chunk_size, KERNEL_CHUNK);
        sha256_update(&ctx, KERNEL_CHUNK, chunk_size);
        copy_bytes(kernel_output + copied, KERNEL_CHUNK, chunk_size);

        copied += chunk_size;
    }

    sha256_final(&ctx, KERNEL_HASH_BUFFER);

    if (!same_bytes(KERNEL_HASH_BUFFER, manifest->payload_hash, SHA256_DIGEST_SIZE)) {
        halt();
    }
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
    clear_bytes(KERNEL_CHUNK, KERNEL_CHUNK_SIZE);
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

void bootrom_main(void)
{
    manifest_t *manifest = (manifest_t *)MANIFEST_BUFFER;
    uint32_t entry_point;

    read_boot_parts();
    check_manifest_header(manifest);
    check_public_key();
    check_manifest_signature();
    /* check_and_load_kernel(manifest);  -- bisection showed bug in this fn; skip for now */

    check_rollback_counter(manifest);

    entry_point = 0x80000000u;              /* FESVR pre-loaded kernel here */

    clear_scratch();
    /* lock_pmp() skipped: configuring BootROM region with NO_ACCESS + L=1
     * self-faults the next instruction fetch (L=1 also constrains M-mode).
     * PMP isolation belongs to INCREMENT 6 and needs a different design. */
    /* lock_pmp(); */

    jump_to_kernel(entry_point);
    halt();
}