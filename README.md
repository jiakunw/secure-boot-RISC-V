# Secure Boot on RV64 Microcontroller — Single-Stage Baseline

**Course:** COMS 6424 Hardware Security  
**Project Option:** 1 (Secure Boot on RISC-V)  
**Platform:** Chipyard 1.13.0 + Rocket Chip + Verilator

---

## 1. Overview

This document describes the **single-stage baseline** of our secure boot
implementation. In this configuration, an immutable on-chip BootROM
directly verifies and launches a single signed kernel image. The
two-stage chain-of-trust extension (Stage B) and Linux boot (Stage C)
build on this baseline without modifying its core mechanisms.

The baseline implements all five core security mechanisms required by
the project:

1. **Hardware-anchored public key** (OTP-stored hash)
2. **Cryptographic image authentication** (Ed25519 signature)
3. **Cryptographic image integrity** (SHA-256 payload hash)
4. **Anti-rollback protection** (monotonic counter)
5. **Post-boot isolation** (PMP with Lock)

---

## 2. Threat Model

### 2.1 Assets We Protect

- **A1. Boot image integrity:** the code that runs after BootROM must
  not have been modified from what the developer signed.
- **A2. Boot image authenticity:** only images signed by the authorized
  developer key shall execute.
- **A3. BootROM integrity at runtime:** later-stage software must not
  be able to overwrite or bypass the BootROM.
- **A4. Rollback resistance:** an attacker cannot force the system to
  execute an older, signed-but-vulnerable image.
- **A5. Boot-time microarchitectural hygiene:** intermediate
  verification state (hashes, buffers, predictor state) must not be
  leveraged by later-stage untrusted software.

### 2.2 Attacker Capabilities (In Scope)

- **C1. Malicious flash contents:** the attacker can arbitrarily modify
  any data in off-chip flash, including boot images, manifests, and
  signatures.
- **C2. Malicious post-boot software:** after boot completes, untrusted
  user-mode or supervisor-mode code may inject malicious code/data and
  attempt to read or modify protected regions.
- **C3. Software-initiated microarchitectural attacks:** the attacker
  can mount Spectre-class, cache, TLB, or branch-predictor
  side-channel attacks from post-boot software.
- **C4. Replay of old signed images:** the attacker may attempt to
  load legitimately signed but outdated (vulnerable) firmware.

### 2.3 Trust Assumptions

- **T1.** The BootROM content and the public-key hash burned into the
  OTP peripheral are correct at manufacture and immutable thereafter.
- **T2.** The hardware RTL is correctly synthesized and not tampered
  with physically.
- **T3.** The developer's signing private key is stored offline (e.g.,
  on an air-gapped workstation or HSM) and is not compromised.
- **T4.** Cryptographic primitives (SHA-256, Ed25519) are
  computationally secure against realistic adversaries.

### 2.4 Out of Scope

- **O1.** Physical attacks: fault injection, EM analysis, decapping,
  probing, power analysis.
- **O2.** Supply-chain attacks on the RTL or toolchain.
- **O3.** DRAM-level attacks (e.g., Rowhammer) — our simulation
  environment does not model DRAM.
- **O4.** Denial of service: an attacker controlling flash can always
  produce an image that fails verification and bricks the device. Our
  design detects this and halts (fail-closed) but does not guarantee
  availability.
- **O5.** Covert channels exploiting shared off-chip resources.
- **O6.** Post-boot kernel security: protecting kernel-internal
  secrets against runtime attacks (e.g., user-process Spectre attacks
  on a kernel) is the responsibility of the kernel itself, not of
  secure boot.

### 2.5 Mapping Attacks to Defenses

| # | Threat (Capability) | Asset Targeted | Defense Mechanism |
|---|---------------------|----------------|-------------------|
| 1 | C1: tamper kernel binary in flash | A1 | SHA-256(kernel) compared against `manifest.payload_hash` (Stage 3 of boot flow) |
| 2 | C1: tamper manifest in flash | A1, A2 | Ed25519 signature over manifest verified with OTP-anchored public key (Stage 2) |
| 3 | C1: substitute attacker's public key in flash | A2 | SHA-256(public_key) compared against immutable OTP value (Stage 1) |
| 4 | C4: replay older signed image (downgrade attack) | A4 | Monotonic rollback counter compared against `manifest.version` (Stage 4); counter is hardware-monotonic |
| 5 | C2: post-boot code reads OTP / BootROM contents | A3, A5 | PMP entries lock OTP, BootROM, and counter regions; Lock bit (`L=1`) makes them inaccessible to all modes including M-mode (Stage 5) |
| 6 | C2: post-boot code modifies counter to allow downgrade | A4 | PMP locks counter MMIO; only BootROM (before lock) can write |
| 7 | C2: post-boot code modifies PMP to bypass restrictions | A3, A4 | PMP `L=1` makes the entry itself immutable until next reset; no software can clear lock |
| 8 | C3: cache side channel on BootROM execution | A5 | Constant-time crypto (MonoCypher Ed25519); BootROM contains no secret-dependent memory accesses; scratch buffers cleared before boot exit |
| 9 | C3: BTB poisoning (Spectre-v2) targeting BootROM | A5 | (i) Hardware reset clears Rocket's BTB via `RegInit`; (ii) BootROM has no secret-dependent indirect branches; (iii) BootROM executes in temporal isolation (no concurrent attacker code); (iv) `fence.i` before kernel jump serializes pipeline |
| 10 | C3: BHT side channel (BranchScope) on verification logic | A5 | Constant-time `memcmp`; constant-time crypto; no secret-dependent conditional branches in verification path |
| 11 | C3: TLB side channel during BootROM | A5 | Not applicable: BootROM runs in M-mode without paging; TLB is unused during boot |
| 12 | C3: Spectre-v1 (bounds check bypass) targeting BootROM | A5 | BootROM has no user-input-driven bounds checks; in-order scalar pipeline limits speculation window to ~5 cycles |
| 13 | Inherent: Meltdown / Spectre-v4 / MDS / LVI | (n/a) | Architecturally impossible: in-order scalar Rocket lacks out-of-order execution, memory disambiguation speculation, and fill buffers |

---

## 3. Architecture

### 3.1 Core Pipeline

- 64-bit **RV64GC** in-order scalar pipeline (Rocket Chip)
- Branch predictor: BHT + BTB + Return Address Stack
- **Sv39** virtual memory with TLB (available but **not used by BootROM**)
- M / S / U privilege modes
- **16-entry Physical Memory Protection (PMP)** unit with Lock bit

### 3.2 Memory Map

| Region            | Address Range            | Size   | Notes |
|-------------------|--------------------------|--------|-------|
| BootROM           | `0x10000` – `0x1FFFF`    | 64 KB  | On-chip ROM, contains verification code |
| OTP               | `0xF0000000` – `0xF000001F` | 32 B  | MMIO peripheral, holds SHA-256(pubkey) |
| Rollback Counter  | `0xF0001000` – `0xF0001007` | 8 B   | MMIO peripheral, hardware-monotonic |
| DRAM (kernel)     | `0x80000000` – ...       | (configurable) | Verified kernel runs here |
| Image staging     | `0x88000000` – ...       | (configurable) | FESVR loads signed image here in simulation |

### 3.3 New Hardware Components

We add two MMIO peripherals to the default Rocket SoC:

- **OTP Peripheral.** A read-only memory containing the SHA-256 hash
  of the developer's public key. Modeled in Chisel based on Chipyard's
  `GCD.scala` template. In simulation, the contents are hard-coded at
  generation time; in a real silicon flow this would be one-time
  programmable fuses.

- **Rollback Counter Peripheral.** A monotonically increasing 64-bit
  counter accessible via MMIO. Reads return the current value; writes
  with a value greater than the current value advance the counter;
  writes with a value less than or equal are ignored. The counter
  cannot be decreased, even by M-mode software.

### 3.4 Software Components

- **BootROM** (`software/bootrom/`): contains startup assembly and C
  verification logic. Compiled to `bootrom.img` and embedded into the
  Rocket SoC at elaboration time.
- **Kernel** (`software/kernel/`): a minimal baremetal demonstration
  program executed after successful verification.
- **Crypto** (`software/crypto/`): SHA-256 (RFC 6234 reference) and
  Ed25519 (MonoCypher subset).
- **Signing tool** (`software/signing_tool/`): Python utility that
  generates Ed25519 keypairs, computes SHA-256 hashes, builds signed
  manifests, and assembles the final flash image.

---

## 4. Manifest Format

The manifest is a 96-byte fixed-size structure signed by the developer:

```c
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
```

The **next_pubkey_hash** field is reserved and zeroed in the
single-stage baseline. It enables forward extension to a two-stage
chain (Stage B) without changing the manifest layout.

---

## 5. Flash Layout

The signed image written to flash (or loaded by FESVR in simulation)
has the following layout:

Offset      Content                Size
─────────────────────────────────────────
0x00000     manifest               96 B
0x00060     signature (Ed25519)    64 B
0x000A0     public key             32 B
0x000C0     kernel binary          variable

The signature is computed over the manifest only. The kernel is
protected indirectly via the `payload_hash` field inside the signed
manifest.

---

## 6. Boot Flow (Six Stages)

### Stage 0 — BootROM Initialization

- Hardware reset places the hart in M-mode with interrupts disabled.
- PC is set to the reset vector (`0x10000`, the BootROM entry).
- Startup assembly sets the stack pointer, clears BSS, and calls
  `bootrom_main()`.
- `bootrom_main()` validates the magic field of the manifest and
  halts if the field is unexpected.

### Stage 1 — Public Key Authentication

- BootROM reads the 32-byte public key from the flash image.
- Computes SHA-256 of the public key.
- Compares the result against the OTP-stored hash using
  constant-time comparison.
- On mismatch: **halt** (fail-closed).

### Stage 2 — Manifest Signature Verification

- BootROM reads the 96-byte manifest and 64-byte signature.
- Calls `crypto_eddsa_check(signature, pubkey, manifest, 96)` from
  MonoCypher.
- On verification failure: **halt**.
- On success: the manifest contents are now trusted.

### Stage 3 — Payload Hash Verification

- BootROM streams the kernel binary in fixed-size chunks (e.g., 512 B)
  and incrementally updates a SHA-256 context.
- After all bytes are processed, the resulting digest is compared
  against `manifest.payload_hash` using constant-time comparison.
- On mismatch: **halt**.
- This step protects against in-flight modifications to the kernel
  bytes that would not affect the (separately signed) manifest.

### Stage 4 — Anti-Rollback Check and Counter Update

- BootROM reads the current value of the rollback counter via MMIO.
- Compares with `manifest.version`:
  - `version < counter` → **halt** (downgrade attack).
  - `version == counter` → continue.
  - `version > counter` → write `version` to counter (advancing it).
- The counter update happens **only after all prior verifications
  pass**, preventing a malicious manifest from advancing the counter
  to lock out future legitimate updates.

### Stage 5 — Boot-Exit Hardening and Jump

- Clear scratch buffers used during verification (SHA-256 state,
  Ed25519 working set) using `memset`.
- Configure PMP entries with Lock bit:
  - Entry 0: BootROM region — no R/W/X, locked.
  - Entry 1: OTP region — no R/W/X, locked.
  - Entry 2: Rollback counter region — no R/W/X, locked.
  - Entry 3: Catch-all — R/W/X, locked (allows kernel access to DRAM
    and other peripherals).
- Issue `fence` to drain pending stores (PMP configuration committed,
  scratch zeros visible).
- Issue `fence.i` to serialize the pipeline and synchronize the
  instruction cache.
- Set `mepc` to `manifest.entry_point` and execute `mret` to jump
  into the verified kernel.

### Failure Mode

All verification failures result in an unconditional halt loop
(`wfi; j .`). No recovery, no retry, no partial boot. This
**fail-closed** posture is consistent with industrial secure boot
practice (ARM TBB, OpenTitan).

---

## 7. PMP Configuration

We use four PMP entries plus locked-OFF placeholders to maximize
defensive coverage. Encoding uses NAPOT mode for all entries:

```c
// pmpcfg byte format: [L | 00 | A | X | W | R]
//   L=1 (locked), A=11 (NAPOT)

// Entry 0: BootROM    [0x10000, 0x20000)   — no R/W/X, L=1   → 0x98
// Entry 1: OTP        [0xF0000000, 0xF0000020) — no R/W/X, L=1 → 0x98
// Entry 2: Counter    [0xF0001000, 0xF0001008) — no R/W/X, L=1 → 0x98
// Entry 3: Catch-all  full address space  — R/W/X, L=1       → 0x9F

uint64_t pmpaddr0 = NAPOT(0x10000,    0x10000);
uint64_t pmpaddr1 = NAPOT(0xF0000000, 0x20);
uint64_t pmpaddr2 = NAPOT(0xF0001000, 0x8);
uint64_t pmpaddr3 = NAPOT(0x0, 1ULL << 54);  // catch-all

#define NAPOT(base, size) (((base) >> 2) | (((size) - 1) >> 3))
```

All unused entries (4–15) are set to `L=1, A=OFF` (`0x80`) so that
post-boot software cannot enable them with attacker-chosen
configurations.

---

## 8. Microarchitectural Security Discussion

### 8.1 Inherent Robustness

Our in-order scalar pipeline is **structurally immune** to several
families of transient execution attacks:

- **Meltdown** requires speculative forwarding of values past
  permission checks; the in-order pipeline completes permission checks
  before any forwarding.
- **Spectre-v4 (Store-to-Load Bypass)** requires speculative memory
  disambiguation, which is absent in-order.
- **MDS-class attacks** (ZombieLoad, RIDL, Fallout) require
  fill buffers and line-fill buffers, neither of which exist in
  Rocket's cache hierarchy.
- **LVI** requires speculative forwarding of injected values, not
  possible in-order.

### 8.2 Residual Risks and Mitigations

The presence of branch prediction (BHT/BTB/RAS) and caches creates
some theoretical attack surface:

| Attack | Status | Mitigation |
|--------|--------|------------|
| Spectre-v1 (BCB) | Possible | No secret-dependent bounds checks in BootROM |
| BTB poisoning (Spectre-v2) | Possible across reboots | Hardware reset clears BTB; no secret-dependent indirect branches; `fence.i` before kernel jump |
| BHT side channel | Possible | Constant-time crypto and `memcmp` |
| Cache side channel | Possible | Constant-time algorithms; scratch buffers cleared |
| TLB side channel | Not applicable | BootROM does not enable paging |

### 8.3 BootROM Trust-Root Property

The BootROM execution environment provides **temporal isolation**
from any adversary:

1. BootROM code is immutable (silicon ROM).
2. BootROM executes immediately after reset, with predictor state
   cleared by hardware reset.
3. BootROM runs single-threaded on a single hart with interrupts
   disabled — no attacker code runs concurrently.
4. There are no context switches during BootROM execution.

These properties eliminate the practical preconditions for
microarchitectural attacks during BootROM itself. Mitigations like
`fence.i` and scratch clearing primarily ensure that **residual
state from BootROM does not become a tool for attacking the
post-boot kernel**.

### 8.4 Information Leakage Scope

Crucially, the BootROM holds **no cryptographic secrets**. All data
it processes (public key, hash in OTP, manifest, signature, kernel
image) is public by design. The signing private key never enters
the chip. Therefore, side-channel leakage of *any* BootROM-resident
data has no direct cryptographic consequence. Our defense-in-depth
measures address residual microarchitectural state, not secret
recovery.

### 8.5 Known Limitations

- **No BTB-flush primitive.** RISC-V provides no equivalent of
  Intel's IBPB; Rocket's internal BTB-flush signal is not exposed
  to software. We rely on hardware-reset clearing and the absence
  of BootROM secret-dependent gadgets.
- **No cache flush primitive.** The base Rocket configuration lacks
  the Zicbom extension. Constant-time algorithms ensure cache
  behavior is independent of secrets.

---

## 9. Build and Run

### 9.1 Prerequisites

- Linux (Ubuntu 20.04+ recommended)
- Chipyard 1.13.0 installed
- Conda environment activated

### 9.2 First-Time Setup

```bash
git clone <this-repo>
cd secure-boot-RISC-V
cp .env.example .env
# Edit .env to set CHIPYARD_HOME=/path/to/chipyard
```

### 9.3 Build and Run a Verified Kernel

```bash
# 1. Generate a signed image
cd software/signing_tool
python sign_firmware.py --kernel ../kernel/kernel.bin \
                        --output flash_image.bin

# 2. Integrate into Chipyard and build
cd ../..
./scripts/integrate_to_chipyard.sh

cd $CHIPYARD_HOME/sims/verilator
make CONFIG=SecureBootConfig

# 3. Run simulation
./simulator-chipyard.harness-SecureBootConfig \
    ~/secure-boot-RISC-V/software/signing_tool/flash_image.bin
```

### 9.4 Negative Tests

```bash
cd tests
./test_tampered_kernel.sh    # expect: BootROM halts at Stage 3
./test_wrong_pubkey.sh       # expect: BootROM halts at Stage 1
./test_bad_signature.sh      # expect: BootROM halts at Stage 2
./test_rollback_attempt.sh   # expect: BootROM halts at Stage 4
./test_pmp_enforcement.sh    # expect: kernel fault on OTP access
```

---

## 10. Files

secure-boot-RISC-V/
├── README.md                         (this file)
├── .env.example
├── hardware/secureboot/
│   ├── OTP.scala                     (OTP MMIO peripheral)
│   ├── RollbackCounter.scala         (counter MMIO peripheral)
│   └── SecureBootConfig.scala        (Chipyard config)
├── software/
│   ├── bootrom/
│   │   ├── bootrom.S                 (startup assembly)
│   │   ├── bootrom.c                 (verification logic)
│   │   ├── linker.ld                 (BootROM linker script)
│   │   └── Makefile
│   ├── crypto/
│   │   ├── sha256.c, sha256.h        (RFC 6234 reference)
│   │   └── monocypher.c, monocypher.h
│   ├── kernel/
│   │   ├── kernel.c                  (demo kernel)
│   │   ├── kernel.ld
│   │   └── Makefile
│   └── signing_tool/
│       ├── sign_firmware.py
│       └── requirements.txt
├── tests/
│   ├── test_tampered_kernel.sh
│   ├── test_wrong_pubkey.sh
│   ├── test_bad_signature.sh
│   ├── test_rollback_attempt.sh
│   └── test_pmp_enforcement.sh
└── scripts/
├── integrate_to_chipyard.sh
└── build_and_run.sh