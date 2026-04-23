typedef struct __attribute__((packed)) {
    uint32_t magic;              // 'SBOT' = 0x54424F53
    uint16_t header_version;     // currently 1
    uint16_t flags;
    uint32_t version;            // monotonically increasing per release
    uint32_t payload_size;       // size of kernel in bytes
    uint32_t load_address;       // where to load kernel (e.g. 0x80000000)
    uint32_t entry_point;        // where to jump after verify
    uint32_t reserved;
    uint32_t pad;
    uint8_t  payload_hash[32];   // SHA-256 of kernel binary
    uint8_t  next_pubkey_hash[32]; // For Stage B; zero in baseline
} manifest_t;