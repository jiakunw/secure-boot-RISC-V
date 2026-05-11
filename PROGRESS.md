# Secure Boot on RISC-V — Project Progress

COMS 6424 Hardware Security, Spring 2026
Target: secure-boot SoC on Chipyard 1.13.0 + Rocket Chip + Verilator.

---

## Architecture Summary

```
┌────────────────────────────────────────────────────────────────┐
│ SecureBootConfig (Chipyard)                                    │
│                                                                │
│  ┌──────────┐    ┌─────────────────────────────────────────┐   │
│  │ Rocket   │◄──►│ TileLink interconnect (PBUS/SBUS/MBUS)  │   │
│  │ RV64GC   │    └──┬───────────┬──────────────┬───────────┘   │
│  │  +VM     │       │           │              │               │
│  │  +BP     │       ▼           ▼              ▼               │
│  └──────────┘    ┌──────┐  ┌──────────┐  ┌─────────────┐       │
│                  │ DRAM │  │  BootROM │  │ Peripherals │       │
│                  │256MB │  │   ~32KB  │  │             │       │
│                  └──────┘  └──────────┘  │ OTP   F0000 │       │
│                  @0x8000_  @0x10000      │ Cnt   F1000 │       │
│                   0000                   │ SPI   F2000 │       │
│                                          └─────────────┘       │
│                                                  │             │
│                                                  ▼             │
│                                          ┌─────────────┐       │
│                                          │ Sim Flash   │       │
│                                          │ 1MB         │       │
│                                          │ (BlackBox)  │       │
│                                          └─────────────┘       │
└────────────────────────────────────────────────────────────────┘
```

3 custom MMIO peripherals (Chisel/Scala), BootROM (C + MonoCypher), Python signing toolchain (PyNaCl Ed25519).

---

## Repo Layout

```
hardware/
  otp/rtl/                  OTP read-only peripheral (32-byte pubkey hash)
  rollback_counter/rtl/     Monotonic 64-bit counter peripheral
  spi_flash/
    rtl/spi_flash.scala     SPI master + simulated slave + TL adapter
    vsrc/FlashStorage.sv    Hand-written SV blackbox for flash storage
  secureboot/
    SecureBootConfig.scala  Top-level config (peripherals + BootROM override)
software/
  bootrom/                  C BootROM with 6-stage chain-of-trust
  kernel/                   Tiny test kernel (prints marchid)
  recovery/                 Standalone recovery firmware (recovery.c +
                            recovery.ld + Makefile). Linked at 0x80100000;
                            BootROM mret's here on verification failure.
  crypto/                   MonoCypher 4.0.2 + SHA-256
metadata/
  manifest.bin              Magic + payload size + SHA-256 of kernel
  signature.bin             Ed25519 sig over manifest (64 bytes)
  public_key.bin            Ed25519 pubkey (32 bytes)
  pubkey_hash.bin           SHA-256 of public_key.bin (32 bytes, burned into OTP at elaboration)
flash_image/
  flash_image.bin           Concatenated manifest+sig+pubkey+kernel for SPI flash slave
  flash_image.hex           Same, as $readmemh-compatible hex
tools/                      Python signing + image-assembly tools
scripts/
  integrate_to_chipyard.sh  Symlinks Scala + SV into Chipyard, builds artifacts
```

---

## Build & Run

```bash
# One-shot: regenerate everything and push into Chipyard's tree
bash scripts/integrate_to_chipyard.sh

# Re-elaborate so updated bootrom.img is baked into TLROM.sv
touch hardware/secureboot/SecureBootConfig.scala
cd $CHIPYARD_HOME/sims/verilator
make -j$(nproc) CONFIG=SecureBootConfig

# Run secure-boot sim — pass BOTH the kernel and the recovery image so
# FESVR loads kernel @ 0x80000000 and recovery @ 0x80100000.
./simulator-chipyard.harness-SecureBootConfig \
    $SECURE_BOOT_REPO/software/kernel/kernel.riscv \
    $SECURE_BOOT_REPO/software/recovery/recovery.riscv
```

**Critical:** BootROM contents are baked into `TLROM.sv` at *elaboration time* (via `ResourceFileName`), NOT loaded from disk at simulation start. After any change to `bootrom.c`, you MUST `touch` a Scala file in `hardware/secureboot/` to force re-elaboration. Otherwise `make` sees the Verilog as unchanged and reuses the old BootROM.

---

## BootROM Chain-of-Trust Design

```
                  ┌───────────────────────────────────────┐
                  │   bootrom_main()                      │
                  └───────────────────────────────────────┘
                              │
                              ▼
                  ┌───────────────────────┐
                  │ read_boot_parts()     │  SPI reads 192 B:
                  │                       │   manifest (96) @ 0x00
                  │                       │   signature (64) @ 0x60
                  │                       │   pubkey   (32) @ 0xA0
                  └───────────────────────┘
                              │
                              ▼
Stage 0: ┌───────────────────────────────────────┐
         │ check_manifest_header()               │  magic == 0x54424F53 ("SOBT")
         │                                       │  header_version == 1
         └───────────────────────────────────────┘
                              │
                              ▼
Stage 1: ┌───────────────────────────────────────┐
         │ check_public_key()                    │  SHA-256(pubkey) == OTP-burned hash
         │                                       │  (anchors trust in hardware)
         └───────────────────────────────────────┘
                              │
                              ▼
Stage 2: ┌───────────────────────────────────────┐
         │ check_manifest_signature()            │  Ed25519_verify(sig, pubkey, manifest)
         │                                       │  (only trust signed manifests)
         └───────────────────────────────────────┘
                              │
                              ▼
Stage 3: ┌───────────────────────────────────────┐
         │ check_and_load_kernel()               │  Stream kernel from SPI flash,
         │                                       │  SHA-256 it, compare to
         │                                       │  manifest->payload_hash,
         │                                       │  copy to DRAM @ load_address
         └───────────────────────────────────────┘
                              │
                              ▼
Stage 4: ┌───────────────────────────────────────┐
         │ check_rollback_counter()              │  manifest->version >= counter
         │                                       │  (anti-rollback)
         └───────────────────────────────────────┘
                              │
                              ▼
Stage 5: ┌───────────────────────────────────────┐
         │ clear_scratch + lock_pmp()            │  Wipe verification buffers,
         │                                       │  lock OTP / Counter / ROM
         │                                       │  from S/U-mode access
         └───────────────────────────────────────┘
                              │
                              ▼
                  ┌───────────────────────┐
                  │ jump_to_kernel()      │  fence + fence.i + mret to 0x80000000
                  └───────────────────────┘
```

---

## INCREMENT Status

| # | Description | Status | Notes |
|---|---|---|---|
| 0 | OTP peripheral integrated, reads pubkey hash at elaboration | ✅ done | `pubkey_hash.bin` → MMIO `0xF0000000` |
| 1 | Rollback counter peripheral (64-bit monotonic) | ✅ done | MMIO `0xF0001000` |
| 2 | SPI Flash master + simulated slave + TL adapter | ✅ done | MMIO `0xF0002000` |
| 3 | Baseline build pipeline (BootROM → integrate → Verilator → sim) | ✅ done | |
| **4** | **Full 6-stage BootROM runs end-to-end, stages 2/4 stubbed** | **🚧 5/6 stages** | Bisection-confirmed: `check_and_load_kernel` (Stage 3) hangs |
| **5** | **Real OTP compare in Stage 1 (`check_public_key`)** | **✅ done** | Debug dropbox confirmed `MATCH` between BootROM-computed SHA-256(pubkey) and OTP-burned hash; now wired so a mismatch jumps to recovery firmware |
| 6 | Real rollback counter check + PMP lock | ⏳ pending | `lock_pmp` design needs rework (see below) |
| 7 | Real Ed25519 verify (MonoCypher) in Stage 2 | 🔧 attempted, hangs | Un-stubbed code hangs in sim; previously suspected MonoCypher / OTP but earlier hangs may have been zombie-sim CPU starvation — needs re-test |
| **+** | **Recovery handler (industry-style failure handoff)** | **✅ done** | Separate `recovery.riscv` ELF at `0x80100000`; BootROM mret's to it on `check_manifest_header` / `check_public_key` failure instead of halting forever |

**Currently shipped (this commit):**
- Stages 0, 1 (full — SHA-256 + OTP compare), 2 (stub), 4 (stub), 5 (clear_scratch only, no PMP lock) all run.
- Stage 3 (`check_and_load_kernel`) is commented out — BootROM mret's to FESVR-pre-loaded kernel at 0x80000000.
- Verification failures in Stage 0 or Stage 1 trigger `enter_recovery()` instead of halting; CPU `mret`s to recovery firmware at 0x80100000.
- Kernel boots successfully and prints `kernel started successfully rocket` on the happy path.

---

## What Works ✅

1. **All 3 custom MMIO peripherals** integrate cleanly into Chipyard's PBUS and respond on the correct addresses.

2. **SPI flash returns correct bytes.** Verified via dropbox diagnostic: BootROM read `0x54424F53` (SOBT magic), `0xBA8E4211` (pubkey first word), and all 6 expected manifest fields. Required a non-trivial BlackBox fix (see "Key Technical Discoveries" below).

3. **OTP root-of-trust compare (INCREMENT 5) works end-to-end.** BootROM computes SHA-256 over the flash-resident public key, reads the 32-byte hash burned into the OTP MMIO at elaboration time, and the two match byte-for-byte. Verified via a debug dropbox run where the kernel printed both hashes side-by-side:
   ```
   flag = 0x0000abcd  (MATCH)
   pubkey SHA-256 (computed by BootROM):
     ead8da89 8d0cab34 cdfe5e0b 3fd50daf f68b3137 ecea9820 0bd66474 bb3b1102
   OTP-stored hash (read via MMIO):
     ead8da89 8d0cab34 cdfe5e0b 3fd50daf f68b3137 ecea9820 0bd66474 bb3b1102
   ```
   Both buffers identical and match `metadata/pubkey_hash.bin`. The compare is now wired with `enter_recovery()` on mismatch (tampering triggers recovery handoff rather than silent boot).

4. **5 of 6 BootROM stages run end-to-end.** Bisection (commenting out `check_and_load_kernel`) showed everything else completes:
   - read_boot_parts (3 SPI transactions)
   - magic check (real, recovery on mismatch)
   - pubkey SHA-256 + OTP compare (real, recovery on mismatch)
   - signature stub
   - rollback stub
   - clear_scratch
   - mret to kernel

5. **Recovery firmware — industry-style failure handoff.** Instead of `halt()` on verification failure, BootROM `mret`s to a separately-built `recovery.riscv` ELF linked at `0x80100000`. This emulates the production pattern used by Apple Recovery OS, Google Titan recovery mode, Android recovery partition, etc.: verification fails → hand off to a recovery image instead of bricking. The recovery image lives in `software/recovery/` with its own linker script (`recovery.ld`) and Makefile (built standalone, bypassing Chipyard's CMake which can't override the global `-T htif.ld`). FESVR loads BOTH `kernel.riscv` and `recovery.riscv` at simulator startup; the BootROM chooses which to `mret` to based on whether verification passes. See [Recovery Handler Design](#recovery-handler-design) below.

6. **Build pipeline.** Single `integrate_to_chipyard.sh` invocation rebuilds BootROM (with `-Os --gc-sections`), kernel via cmake, **recovery firmware via its own standalone Makefile**, copies into Chipyard's resource tree, regenerates flash image hex.

7. **Standalone SystemVerilog BlackBox + auto-staging.** `hardware/spi_flash/vsrc/FlashStorage.sv` is the canonical SV source. `integrate_to_chipyard.sh` symlinks any `*.sv` under `hardware/` into `$CHIPYARD/generators/chipyard/src/main/resources/vsrc/` so `HasBlackBoxResource + addResource("/vsrc/FlashStorage.sv")` finds it.

---

## Recovery Handler Design

Verification failures in `check_manifest_header` (Stage 0) and `check_public_key` (Stage 1) call `enter_recovery()` instead of `halt()`. This mirrors the industry "recovery firmware" pattern: production secure boot doesn't brick on first failure — it hands off to a smaller, independently-loaded image that can diagnose, report, and (in real systems) re-flash the device.

```
                    BootROM @ 0x10000
                          │
            ┌─────────────┼──────────────┐
            │             │              │
            ▼             ▼              ▼
   check_manifest    check_public    (other stages)
     _header()        _key()
            │             │
   fail ────┤    fail ────┤
            ▼             ▼
       ┌────────────────────────┐
       │  enter_recovery()      │
       │  fence + fence.i       │
       │  mepc ← 0x80100000     │
       │  mret                  │
       └──────────┬─────────────┘
                  │
                  ▼
       ┌────────────────────────┐         ┌────────────────────────┐
       │ recovery.riscv         │         │ kernel.riscv           │
       │ @ 0x80100000           │   vs    │ @ 0x80000000           │
       │ (FESVR-loaded)         │         │ (FESVR-loaded)         │
       │                        │         │                        │
       │ printf("something went │         │ printf("kernel started │
       │  wrong, in recovery    │         │  successfully rocket\n")│
       │  mode\n")              │         │                        │
       └────────────────────────┘         └────────────────────────┘
              Recovery path                       Happy path
        (verification failed)              (all stages passed)
```

**Build:** `software/recovery/` contains a standalone build:
- `recovery.c` — body (just `printf`, will exit via HTIF)
- `recovery.ld` — linker script identical to chipyard's `htif.ld` except base address is `0x80100000` instead of `0x80000000`
- `Makefile` — bypasses Chipyard's CMake (which has a global `-T htif.ld` that conflicts with our override); links recovery directly with `-T recovery.ld` and `-specs=htif_nano.specs` for riscv-pk printf support

**Runtime:** Pass both ELFs to the simulator:
```bash
./simulator-chipyard.harness-SecureBootConfig kernel.riscv recovery.riscv
```
FESVR's `htif_t::start()` accepts multiple positional ELF arguments and loads each at its LMA. Kernel ends up at `0x80000000`, recovery at `0x80100000`. BootROM `mret`s to whichever is appropriate.

**Where this lands on the production spectrum:**
| Aspect | Our prototype | Production typical |
|---|---|---|
| Recovery storage | DRAM @ 0x80100000 (loaded by FESVR at sim startup) | Signed flash partition (Apple Recovery OS), mask ROM (Apple T2), or scratchpad SRAM (Apple Secure Enclave, Google Titan) |
| Recovery loading | FESVR pre-loads, BootROM doesn't copy | BootROM reads from flash, verifies a signature, copies to DRAM/SRAM |
| Recovery signing | Not signed (prototype shortcut) | Independently signed (often with a different OTP-anchored key for revocability) |
| Recovery runtime | riscv-pk nano libc (so `printf` works) | Typically smaller bare-metal; sometimes a stripped-down OS |
| Recovery capability | Just prints a message | Can re-flash main firmware over USB/serial/network, run diagnostics |

A production-faithful upgrade path would: (1) store `recovery.bin` in SPI flash alongside the manifest, (2) have BootROM verify recovery's own signature using a recovery-specific OTP-burned key, (3) copy verified bytes into DRAM (or, ideally, a dedicated scratchpad SRAM region — our SoC has `memory@8000000` reserved but currently disabled) before `mret`-ing.

---

## What Doesn't Work Yet 🚧

### 1. `check_and_load_kernel` (Stage 3) — hangs

**Symptom:** Sim runs 99% CPU forever, kernel never prints.

**What it does:** 16 successive 512-byte SPI reads of the kernel from flash, with incremental SHA-256 along the way, copying chunks to DRAM at `manifest->load_address`. Compares final hash against `manifest->payload_hash`.

**Bisection result:** With this function commented out, the BootROM completes all other stages and the kernel boots. So the bug is contained inside this function.

**Suspected causes (not yet diagnosed):**
- SPI master state machine not resetting cleanly between back-to-back transactions (we only proved 3 small reads in `read_boot_parts`; 16 large reads stress the state machine more)
- Incremental `sha256_update` bug
- FIFO backpressure deadlock during long transactions

**Fix candidate (untested):** rewrite as a single SPI transaction (read all 7896 bytes into DRAM, then `sha256_hash` once). Removes both multi-transaction and incremental-hash from the suspect list at the same time.

### 2. INCREMENT 7 — real Ed25519 verify hangs

Un-stubbing `crypto_eddsa_check()` (MonoCypher Ed25519). Earlier attempts showed 99% CPU with no progress for 19+ minutes. Adds ~10-20 KB of crypto code into the BootROM (Curve25519 + SHA-512 + BigNum arithmetic). The TLROM resizes automatically (from 8 KB to 32 KB), so size isn't the blocker. Possible causes:
- MonoCypher stack overflow (Ed25519 verify needs ~1-2 KB stack; current stack at 0x88010000 should have room)
- An infinite loop in some MonoCypher inner routine
- **Previous hangs may have been zombie-sim CPU starvation** (we had 17 leaked sims fighting for CPU). After OTP turned out to work fine once zombies were cleaned, Ed25519 deserves a re-test under clean CPU conditions — could plausibly Just Work.

### 3. `lock_pmp()` — self-fault

Configuring PMP entry 0 to cover the BootROM region with `NO_ACCESS + L=1` makes the *next instruction fetch* (return from `lock_pmp` into the BootROM region we just locked) fault, because the RISC-V spec says `L=1` extends PMP enforcement to M-mode. Currently commented out. INCREMENT 6 needs a different design — either:
- Configure BootROM as `RX + L=1` instead of `NO_ACCESS + L=1` (keeps execute, locks writes)
- Copy a tiny trampoline to DRAM and jump there before lock_pmp, so the post-lock fetch is from an unlocked region
- Drop privilege to S/U mode via `mret` first, then PMP applies and BootROM is naturally unreachable from S/U

---

## Key Technical Discoveries

### A. Chipyard's `RANDOMIZE_MEM_INIT` clobbers `loadMemoryFromFileInline`

`Chisel.Mem` + `loadMemoryFromFileInline` looks like the right way to populate a flash model, but the FIRRTL/CIRCT backend emits something like:
```verilog
initial begin
  $readmemh("flash_image.hex", Memory);            // loads our data
  `ifdef RANDOMIZE_MEM_INIT
    for (i = 0; i < N; i++)
      Memory[i] = `RANDOM;                          // overwrites with random!
  `endif
end
```
Chipyard's default Verilator flags include `+define+RANDOMIZE_MEM_INIT`, so the `$readmemh` load gets *silently* overwritten with seeded-random bytes. Reads from the slave return deterministic-but-meaningless garbage — easy to mistake for an SPI bit-shift bug.

**Workaround:** swap the Chisel `Mem` for a hand-written SystemVerilog blackbox (`reg [7:0] mem[N]` array). FIRRTL never sees the storage, so it never emits the randomize template around it. See `hardware/spi_flash/rtl/spi_flash.scala::FlashStorage` and `hardware/spi_flash/vsrc/FlashStorage.sv`.

### B. BootROM content is baked at elaboration, not loaded at runtime

`ResourceFileName("/testchipip/bootrom/bootrom.secureboot.rv64.img")` in our `WithSecureBootROM` config tells Chisel/CIRCT to read the `.img` file *during elaboration* and emit the bytes as Verilog literals in the generated `TLROM.sv`. After elaboration the `.img` file on disk is irrelevant — the simulator uses the baked-in bytes.

**Consequence:** any BootROM source change requires a full re-elaboration (`touch SecureBootConfig.scala && make`), not just a rebuild of the `.img`. This took ~15-20 min per iteration and was a major time sink.

### C. CPU caches make external DRAM observation unreliable

We tried to monitor BootROM progress externally by writing stage markers to a fixed DRAM address and reading them via `sudo dd if=/proc/PID/mem ...`. This only works *after* the CPU's L1 D-cache has evicted the marker line back to DRAM. While the BootROM is hanging in a tight fault/poll loop, the marker writes sit in cache indefinitely and `/proc/PID/mem` reads return zeros from the underlying mmap.

We learned this the hard way after thinking "marker=0 means BootROM never ran." Reliable in-sim diagnostics need either:
- Output via a path the kernel later reads (then the kernel's read flushes through cache), or
- Output to uncached MMIO (e.g., the SPI peripheral itself, or a debug register), or
- Forced cache eviction (write to many distinct cache lines after the marker)

---

## Verification Evidence

**SPI correctness (bisection diagnostic, archived):**
```
=== SPI dump from BootROM ===
manifest[ 0..3]  = 0x54424f53  (expected 0x54424f53 SBOT)
manifest[ 4..7]  = 0x00000001  (expected 0x00000001)
manifest[ 8..11] = 0x00000001  (expected 0x00000001)
manifest[12..15] = 0x00001ed8  (expected 0x00001ed8)
signature[0..3]  = 0xab651510
pubkey[0..3]     = 0xba8e4211  (expected 0xba8e4211)
```

**End-to-end boot (bisection, stage_mark instrumentation, archived):**
```
BootROM final stage marker: 0xba07
kernel started successfully rocket
```

**INCREMENT 5 (OTP compare) verification (archived):**
```
=== OTP compare debug ===
flag = 0x0000abcd  (MATCH)
pubkey SHA-256 (computed by BootROM):
  ead8da89 8d0cab34 cdfe5e0b 3fd50daf f68b3137 ecea9820 0bd66474 bb3b1102
OTP-stored hash (read via MMIO):
  ead8da89 8d0cab34 cdfe5e0b 3fd50daf f68b3137 ecea9820 0bd66474 bb3b1102
kernel started successfully rocket
```
Both hash buffers identical and match `metadata/pubkey_hash.bin` byte-for-byte. OTP root-of-trust is anchored.

**Current (shipped) state — happy path with recovery handler wired:**
```
kernel started successfully rocket
```
The OTP compare in `check_public_key` is now real (not a stub) and feeds into `enter_recovery()` on mismatch. `recovery.riscv` is FESVR-loaded at 0x80100000 and will run on any failure of Stage 0 or Stage 1.

---

## TODO (in priority order)

1. **Negative test the recovery path** — corrupt one byte of `metadata/public_key.bin`, regenerate flash hex, re-run sim. Should see `"something went wrong, in recovery mode"` (from recovery.riscv) instead of the kernel banner. Proves the `enter_recovery()` handoff actually fires in the failure case.
2. **Re-test INCREMENT 7 (Ed25519)** — earlier hang may have been zombie-sim contention; clean sim re-test could surprise us by working.
3. **Fix `check_and_load_kernel`** — likely rewrite as single-shot SPI read + one-shot SHA-256 hash. Critical for any real secure boot.
4. **Redesign `lock_pmp`** — `RX+L=1` for BootROM region (or trampoline through DRAM).
5. **More negative tests** — corrupt manifest magic, wrong signature, version rollback. Each should drive a different recovery code path (once `enter_recovery()` takes a reason argument, currently it's a single entry).
6. **Performance measurement** — boot time breakdown per stage, BootROM image size, gate count.
7. **Final report** — design rationale, threat model, measurements, lessons learned.

---

## Build Pipeline Quick Reference

| Change | Required step |
|---|---|
| `software/bootrom/*.c` | `bash scripts/integrate_to_chipyard.sh` + `touch hardware/secureboot/SecureBootConfig.scala` + `make` |
| `software/kernel/*.c` | `bash scripts/integrate_to_chipyard.sh` (no re-elaboration needed; FESVR loads at sim start) |
| `software/recovery/*.c` or `recovery.ld` | `bash scripts/integrate_to_chipyard.sh` (no re-elaboration needed; FESVR loads at sim start) |
| `hardware/**/*.scala` | `bash scripts/integrate_to_chipyard.sh` + `make` (touch may not be needed if file mtime changed) |
| `hardware/**/*.sv` | `bash scripts/integrate_to_chipyard.sh` + `touch hardware/secureboot/SecureBootConfig.scala` + `make` |
| `metadata/*.bin` (re-sign) | Re-run signing script in `tools/`, then `bash scripts/integrate_to_chipyard.sh` + `touch + make` |
