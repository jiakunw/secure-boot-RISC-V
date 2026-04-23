import struct
import hashlib
import os

# Configuration
KERNEL_PATH    = '../software/kernel/kernel.bin' 
OUTPUT_PATH    = '../metadata/manifest.bin'
MAGIC_NUMBER   = 0x54424F53   # 'SBOT'
HEADER_VERSION = 1
FLAGS          = 0
VERSION        = 1            
LOAD_ADDR      = 0x80000000   
ENTRY_POINT    = 0x80000000   

# 1. Read the kernel binary and hash it
with open(KERNEL_PATH, "rb") as f:
    kernel_data = f.read()

kernel_hash = hashlib.sha256(kernel_data).digest()
payload_size = len(kernel_data)

print(f"Kernel: {KERNEL_PATH}")
print(f"  Size:  {payload_size} bytes")
print(f"  SHA256: {kernel_hash.hex()}")

# 2. Pack the manifest
struct_format = "<IHHIIIIII32s32s"
next_pubkey_hash = b'\x00' * 32   # Placeholder for Stage B

manifest_bytes = struct.pack(
    struct_format,
    MAGIC_NUMBER,      #  uint32_t magic;
    HEADER_VERSION,    #  uint16_t header_version;
    FLAGS,             #  uint16_t flags;
    VERSION,           #  uint32_t version;
    payload_size,      #  uint32_t payload_size;
    LOAD_ADDR,         #  uint32_t load_address;
    ENTRY_POINT,       #  uint32_t entry_point;
    0,                 #  uint32_t reserved;
    0,                 #  uint32_t pad;
    kernel_hash,       #  uint8_t  payload_hash[32];
    next_pubkey_hash,  #  uint8_t  next_pubkey_hash[32];
)

# 3. Write back
os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
with open(OUTPUT_PATH, "wb") as f:
    f.write(manifest_bytes)

print(f"Manifest written: {OUTPUT_PATH} ({len(manifest_bytes)} bytes)")