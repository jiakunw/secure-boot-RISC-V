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

# Run secure-boot sim
./simulator-chipyard.harness-SecureBootConfig $SECURE_BOOT_REPO/software/kernel/kernel.riscv
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
| **4** | **Full 6-stage BootROM runs end-to-end, stages 1/2/4 stubbed** | **🚧 5/6 stages** | Bisection-confirmed: `check_and_load_kernel` (Stage 3) hangs |
| 5 | Real OTP compare in Stage 1 | 🔧 attempted, hangs | Un-stubbed code hangs in sim, root cause TBD |
| 6 | Real rollback counter check + PMP lock | ⏳ pending | `lock_pmp` design needs rework (see below) |
| 7 | Real Ed25519 verify (MonoCypher) in Stage 2 | 🔧 attempted, hangs | Un-stubbed code hangs in sim, root cause TBD |

**Currently shipped (this commit):**
- Stages 0, 1 (partial — SHA-256 only, no OTP compare), 2 (stub), 4 (stub), 5 (clear_scratch only, no PMP lock) all run.
- Stage 3 (`check_and_load_kernel`) is commented out — BootROM mret's to FESVR-pre-loaded kernel at 0x80000000.
- Kernel boots successfully and prints `kernel started successfully rocket`.

---

## What Works ✅

1. **All 3 custom MMIO peripherals** integrate cleanly into Chipyard's PBUS and respond on the correct addresses.

2. **SPI flash returns correct bytes.** Verified via dropbox diagnostic: BootROM read `0x54424F53` (SOBT magic), `0xBA8E4211` (pubkey first word), and all 6 expected manifest fields. Required a non-trivial BlackBox fix (see "Key Technical Discoveries" below).

3. **5 of 6 BootROM stages run end-to-end.** Bisection (commenting out `check_and_load_kernel`) showed everything else completes:
   - read_boot_parts (3 SPI transactions)
   - magic check (real)
   - pubkey SHA-256 (real, OTP compare deferred)
   - signature stub
   - rollback stub
   - clear_scratch
   - mret to kernel

4. **Build pipeline.** Single `integrate_to_chipyard.sh` invocation rebuilds BootROM (with `-Os --gc-sections`), kernel via cmake, copies into Chipyard's resource tree, regenerates flash image hex.

5. **Standalone SystemVerilog BlackBox + auto-staging.** `hardware/spi_flash/vsrc/FlashStorage.sv` is the canonical SV source. `integrate_to_chipyard.sh` symlinks any `*.sv` under `hardware/` into `$CHIPYARD/generators/chipyard/src/main/resources/vsrc/` so `HasBlackBoxResource + addResource("/vsrc/FlashStorage.sv")` finds it.

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

### 2. INCREMENT 5 — real OTP compare hangs

Un-stubbing the OTP compare in `check_public_key()`:
```c
read_otp_hash(OTP_HASH_BUFFER);
if (!same_bytes(PUBLIC_KEY_HASH, OTP_HASH_BUFFER, OTP_HASH_SIZE)) halt();
```
causes the sim to hang at 99% CPU. **Prerequisite verified:** `pubkey_hash.bin` (the file burned into OTP at elaboration) contains exactly `SHA-256(public_key.bin)`, so if the OTP read succeeds and the SPI-loaded pubkey is correct, the compare should pass. The hang is therefore either in `read_otp_hash` (MMIO read of the OTP module hangs?) or somewhere in the new larger BootROM image — needs more bisection.

### 3. INCREMENT 7 — real Ed25519 verify hangs

Un-stubbing `crypto_eddsa_check()` (MonoCypher Ed25519). Symptom identical to #2: 99% CPU, no progress. Adds ~10-20 KB of crypto code into the BootROM (Curve25519 + SHA-512 + BigNum arithmetic). The TLROM resizes automatically (from 8 KB to 32 KB), so size isn't the blocker. Could be:
- MonoCypher stack overflow (Ed25519 verify needs ~1-2 KB stack; current stack at 0x88010000 should have room)
- An infinite loop in some MonoCypher inner routine
- Same underlying issue as #2 (whatever it is)

### 4. `lock_pmp()` — self-fault

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

**Current (shipped) state:**
```
kernel started successfully rocket
```

(Stage marker instrumentation removed from this commit; verification path is the BootROM completing all uncommented stages → mret to FESVR-loaded kernel → kernel printf via HTIF.)

---

## TODO (in priority order)

1. **Fix `check_and_load_kernel`** — likely rewrite as single-shot SPI read + one-shot SHA-256 hash. Critical for any real secure boot.
2. **Diagnose INCREMENT 5 hang** — try OTP compare in isolation with the stage_mark instrumentation restored, see where it actually halts.
3. **Diagnose INCREMENT 7 hang** — same approach. Suspect stack pressure from MonoCypher.
4. **Redesign `lock_pmp`** — `RX+L=1` for BootROM region (or trampoline through DRAM).
5. **Negative tests** — corrupt manifest, wrong pubkey, sig-mismatch, version rollback. Each should produce `halt()` (CPU goes to wfi, sim never prints kernel banner).
6. **Performance measurement** — boot time breakdown per stage, BootROM image size, gate count.
7. **Final report** — design rationale, threat model, measurements, lessons learned.

---

## Build Pipeline Quick Reference

| Change | Required step |
|---|---|
| `software/bootrom/*.c` | `bash scripts/integrate_to_chipyard.sh` + `touch hardware/secureboot/SecureBootConfig.scala` + `make` |
| `software/kernel/*.c` | `bash scripts/integrate_to_chipyard.sh` (no re-elaboration needed; FESVR loads at sim start) |
| `hardware/**/*.scala` | `bash scripts/integrate_to_chipyard.sh` + `make` (touch may not be needed if file mtime changed) |
| `hardware/**/*.sv` | `bash scripts/integrate_to_chipyard.sh` + `touch hardware/secureboot/SecureBootConfig.scala` + `make` |
| `metadata/*.bin` (re-sign) | Re-run signing script in `tools/`, then `bash scripts/integrate_to_chipyard.sh` + `touch + make` |
