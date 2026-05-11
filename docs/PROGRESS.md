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
  status_register/rtl/      Boot-status register (32-bit) at 0xF0003000;
                            BootROM sets one bit per failed stage,
                            recovery reads to report root cause.
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
tests/
  test_tempering_manifest_header/   Self-contained "tempered SoC" negative test:
    TemperedSecureBootConfig.scala  alt config pointing SPI flash at tampered hex
    tools/                          tampered manifest_generators.py + sign_firmware.py
    tempered_flash_image/           generated tampered artifacts
    build.sh + run.sh               build alt sim binary + verify recovery handoff
  test_tempering_public_key/        (byte-tamper variant, simpler)
  run_all.sh                        master runner
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
| **5** | **Real OTP compare in Stage 1 (`check_public_key`)** | **✅ done** | Debug dropbox confirmed `MATCH` between BootROM-computed SHA-256(pubkey) and OTP-burned hash; mismatch triggers `enter_recovery(SR_PUBLIC_KEY)` (bit 1) |
| **6** | **PMP lock (Stage 5) — real lock active; rollback still stub** | **🚧 PMP only** | `lock_pmp` now writes BootROM=RX+L, OTP/Counter=NO_ACCESS+L, catch-all=RWX+L; BootROM successfully `mret`s to kernel post-lock. Rollback counter check is still stubbed |
| 7 | Real Ed25519 verify (MonoCypher) in Stage 2 | 🔧 attempted, hangs | Un-stubbed code hangs in sim; previously suspected MonoCypher / OTP but earlier hangs may have been zombie-sim CPU starvation — needs re-test |
| **+** | **Recovery handler (industry-style failure handoff)** | **✅ done (sim-exit variant)** | Separate `recovery.riscv` ELF at `0x80100000` is built and FESVR-loaded; `enter_recovery(reason_bit)` writes the failing-stage bit to the SR and then **directly drives the sim to exit via tohost** (writes `(reason_bit<<1)|1` in an infinite loop, mimicking riscv-pk's `_exit`). Sim exits with FESVR-reported exit code = reason_bit. On real silicon this same `enter_recovery` would instead `mret` to the recovery image — see "Sim exit vs production mret" note below |
| **+** | **Status Register (SR) peripheral — 32-bit boot-status MMIO** | **✅ done** | New peripheral at `0xF0003000` (`hardware/status_register/rtl/sr.scala`). BootROM sets one bit per failed stage (`SR_MANIFEST_HEADER`=0x01, `SR_PUBLIC_KEY`=0x02, …, `SR_LOCK_PMP`=0x20); recovery reads and reports which stage failed |
| **+** | **Tempered SoC test infrastructure (negative tests)** | **✅ done — PASS strong** | `tests/test_tempering_manifest_header/` builds an entire parallel SoC (`TemperedSecureBootConfig`) pointing the SPI flash at a tampered hex image. Strong PASS: kernel banner absent **AND** FESVR-reported exit code = 1 = `SR_MANIFEST_HEADER` bit. Sim runs ~10s wall-clock and exits cleanly via `$stop` |

**Currently shipped (this commit):**
- All BootROM stages 0, 1, 2, 4, 5 run end-to-end on the happy path (signature + rollback are stubs but the function bodies execute and return).
- Stage 3 (`check_and_load_kernel`) is still commented out — bisection confirmed the SPI multi-transaction hang.
- **PMP lock is now active**: BootROM region locked R+X (M-mode can still execute remaining instructions), OTP / Counter regions NO_ACCESS (kernel cannot read them post-lock), catch-all RWX. Kernel boots in M-mode but is isolated from the OTP root-of-trust and the rollback counter.
- Verification failures in Stages 0, 1, 3, 5 trigger `enter_recovery(reason_bit)`, which (a) writes the failing-stage bit into the SR and (b) drives the sim to exit with that bit as the exit code via tohost. (On real silicon the same `enter_recovery` would `mret` to the recovery image at `0x80100000`; for the sim we use the tohost-exit shortcut for a strong, machine-checkable verdict — see "Sim exit vs production mret" below.)
- **Happy path verified end-to-end**: with all integrated stages (real OTP compare + real PMP lock active), the kernel still boots and prints `kernel started successfully rocket` cleanly.
- **Negative test verified end-to-end (PASS strong)**: tampered manifest magic → BootROM Stage 0 catches it → sim exits with exit code = `SR_MANIFEST_HEADER` bit = 1, kernel banner absent.

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

4. **5 of 6 BootROM stages run end-to-end with PMP lock active.** Bisection (commenting out `check_and_load_kernel`) showed everything else completes:
   - read_boot_parts (3 SPI transactions)
   - magic check (real, recovery on mismatch)
   - pubkey SHA-256 + OTP compare (real, recovery on mismatch)
   - signature stub
   - rollback stub
   - clear_scratch
   - **`lock_pmp()` — real, with production-style permissions** (see below)
   - mret to kernel — kernel still boots cleanly in M-mode

5. **PMP lock (Stage 5) — real and isolating.** `lock_pmp` writes:
   | Entry | Region | Permissions | Reason |
   |---|---|---|---|
   | 0 | BootROM (`0x10000-0x20000`) | `RX + L=1` | M-mode keeps execute (so the post-`lock_pmp` `mret` works); kernel cannot write/execute |
   | 1 | OTP (`0xF0000000-0xF000001F`) | `NO_ACCESS + L=1` | Kernel cannot read the root-of-trust hash |
   | 2 | Rollback Counter (`0xF0001000-0xF0001007`) | `NO_ACCESS + L=1` | Kernel cannot fast-forward or read the counter |
   | 3 | catch-all `0x0..2^54` | `RWX + L=1` | DRAM + remaining MMIO available |

   **Defense in depth**: `lock_pmp` *also* sets `mtvec = RECOVERY_ENTRY` and pre-marks `SR_LOCK_PMP` in the status register before the PMP commit, so if any future change to the PMP config accidentally introduces a self-fault, the trap is caught by the recovery firmware (and the SR shows the cause). On the success path, the function clears `SR_LOCK_PMP` after the commit returns.

   **Initial design used `NO_ACCESS+L=1` for the BootROM region** — that self-faulted the very next instruction fetch because `L=1` extends PMP enforcement to M-mode. The current `RX+L=1` keeps execute permission for M-mode while denying write/execute to S/U-mode kernel.

6. **Status Register (SR) peripheral — boot-failure cause tracking.** New custom peripheral at MMIO `0xF0003000` (`hardware/status_register/rtl/sr.scala`). 32-bit register, one bit per verification stage:

   | Bit | Stage | Macro in `bootrom.c` |
   |---|---|---|
   | 0 | `check_manifest_header` | `SR_MANIFEST_HEADER` |
   | 1 | `check_public_key` | `SR_PUBLIC_KEY` |
   | 2 | `check_manifest_signature` | `SR_MANIFEST_SIGNATURE` |
   | 3 | `check_and_load_kernel` | `SR_LOAD_KERNEL` |
   | 4 | `check_rollback_counter` | `SR_ROLLBACK_COUNTER` |
   | 5 | `lock_pmp` | `SR_LOCK_PMP` |

   `enter_recovery(reason_bit)` reads-modify-writes the SR so the recovery firmware can decode which stage failed by reading `*(volatile uint32_t *)0xF0003000`.

7. **Recovery firmware — industry-style failure handoff.** Instead of `halt()` on verification failure, BootROM `mret`s to a separately-built `recovery.riscv` ELF linked at `0x80100000`. This emulates the production pattern used by Apple Recovery OS, Google Titan recovery mode, Android recovery partition, etc.: verification fails → hand off to a recovery image instead of bricking. The recovery image lives in `software/recovery/` with its own linker script (`recovery.ld`) and Makefile (built standalone, bypassing Chipyard's CMake which can't override the global `-T htif.ld`). FESVR loads BOTH `kernel.riscv` and `recovery.riscv` at simulator startup; the BootROM chooses which to `mret` to based on whether verification passes. See [Recovery Handler Design](#recovery-handler-design) below.

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

### 3. ~~Recovery firmware printf invisible (HTIF tohost mismatch)~~ — RESOLVED via sim-exit shortcut

(Originally: BootROM `mret`-ing to `recovery.riscv` produced no visible output because FESVR only watches the *first* ELF's `tohost`/`fromhost` symbols, not recovery's own `.htif` section.)

**Resolution:** Took the second fix candidate listed below — instead of `mret`-ing and then trying to make recovery's HTIF mailbox visible, `enter_recovery()` now writes a known exit-code-encoded value directly to the (kernel) `tohost` address in an infinite loop, exactly mimicking riscv-pk's `_exit`. FESVR sees the write, calls `$stop` with `exit_code = reason_bit`, and the test runner reads that as the verdict. Recovery.riscv still loads at `0x80100000` (FESVR-loaded via `+payload=`) as an architectural artifact — on real silicon the same `enter_recovery` would `mret` there and recovery would `printf` its own diagnostic — but in the sim path we don't need to actually execute it.

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

### D. Sim startup is slow — short timeouts produce false negatives

The Chipyard Verilator binary needs ~60-90s of wall-clock time before the kernel banner appears on the happy path (BootROM verification + crypto + DRAM warm-up). For most of a frustrating day we used 30s timeouts on negative tests, saw "no output ever appears", and chased nonexistent cache-coherency bugs. The fix was just "use 120s".

**Lesson:** for any Chipyard Verilator sim, set timeouts ≥ 120s (or grep for a positive output marker and only kill on its absence). The 30s default is sized for FireSim / FPGA, not software-simulated Rocket.

### E. FESVR *does* see BootROM tohost writes — the bug was HTIF protocol state, not cache

We initially suspected an L1 D-cache coherency bug — "BootROM's tohost write sits dirty in L1 forever, FESVR's TSI poll sees stale DRAM=0." That hypothesis was **wrong**. A diagnostic probe at the top of `bootrom_main` writing one HTIF putc byte (`tohost = (1<<56)|(1<<48)|'H'`) showed `H` appear on FESVR's stdout immediately. So FESVR's view of tohost is *not* cache-stuck.

What was actually happening: HTIF protocol is a request/response handshake. After `putc 'H'` FESVR writes an ACK to `fromhost` and expects the CPU to clear `tohost` before issuing the next operation. The probe didn't clear it; the subsequent `tohost = (exit_code<<1)|1` write was silently *ignored* because the protocol was stuck mid-handshake.

**The fix is structural, not protocol-tuning:** make `enter_recovery()` the *only* tohost-writer in the BootROM (no preceding putc, no preceding diag print via HTIF). Then FESVR sees a clean first-ever tohost write with the exit-syscall bit set and fires `$stop` immediately.

**Lesson:** when an HTIF write goes unnoticed, suspect protocol state poisoning before cache coherency. The two failure modes look identical from outside.

### F. Bootrom contents are baked, but flash hex files are read at sim start

`bootrom.img` goes through Chisel elaboration (see B) and is baked into the simulator binary, so changes need a full re-elaborate + Verilator rebuild (~5-8 min).

But `flash_image/flash_image.hex` and `tempered_flash_image/flash_image.hex` are read by Verilator at **each simulation start** via `$readmemh` in `FlashStorage.sv` (relative to the Verilator working directory `$CHIPYARD_HOME/sims/verilator/`). So swapping the hex file is a zero-cost change — no rebuild needed.

This asymmetry is easy to overlook. The negative test's `build.sh` step `[5/6]` *stages* the tampered hex into the Verilator working dir; bypassing `build.sh` and running `make CONFIG=TemperedSecureBootConfig` manually will compile-link but the sim will read whatever hex is already (or isn't) staged. We hit this bug once: the tempered sim binary ran but `$readmemh` found no file → flash returned all-zeros → BootROM read a zero manifest → still failed but for the wrong reason.

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

**Current shipped state — happy path with real OTP compare + real PMP lock:**
```
[UART] UART0 is here (stdin/stdout).
kernel started successfully rocket
- TestDriver.v:158: Verilog $finish
```
End-to-end clean: BootROM runs Stages 0 (magic), 1 (real OTP compare), 2 (stub), 4 (stub), 5 (clear_scratch + **real PMP lock**), then `mret`s to kernel. Kernel runs in M-mode with PMP isolating it from OTP and the rollback counter, prints success, exits via HTIF.

**Negative test — tampered manifest header (`tests/test_tempering_manifest_header/`) — PASS strong:**
```
[UART] UART0 is here (stdin/stdout).
*** FAILED *** (tohost = 1)
[938305000] %Error: TestHarness.sv:99: Assertion failed: *** FAILED *** (exit code = 1)
    at SimTSI.scala:21 assert(!error, "*** FAILED *** (exit code = %%d)\n", exit >> 1.U)
%Error: TestHarness.sv:99: Verilog $stop
─────────────────────────────────────────
PASS:
  ✓ kernel banner absent
  ✓ FESVR-reported exit code = 1 (= SR_MANIFEST_HEADER bit)
```
A separate `TemperedSecureBootConfig` SoC was built with the SPI flash parameterized to read a manifest whose magic was flipped from `0x54424F53` ('SOBT') to `0x44414544` ('DEAD'). BootROM Stage 0 catches it and calls `enter_recovery(SR_MANIFEST_HEADER)`, which writes `tohost = (1<<1)|1 = 3` in an infinite loop. FESVR shifts the exit-syscall bit off, gets exit code 1 = `SR_MANIFEST_HEADER` bit, and `$stop`s the sim cleanly. Wall-clock ~10s (BootROM fails fast, no full kernel boot).

### Sim exit vs production mret

Both shipped tests (happy path + negative) use the **same `enter_recovery` function** in BootROM. The difference is in how it exits:

- **Happy path:** `enter_recovery` is never called — BootROM completes all stages, `mret`s to kernel @ `0x80000000`, kernel prints banner and `_exit`s via tohost.
- **Sim negative path (current):** `enter_recovery` writes SR + drives FESVR `$stop` with `exit_code = reason_bit`. This is a **sim-only shortcut** that produces a clean machine-checkable verdict.
- **Production negative path (designed but not exercised in sim):** the same `enter_recovery` would `mret` to `recovery.riscv` @ `0x80100000`, where the recovery image would handle re-flash / diagnostics / phone-home. FESVR is the only reason we don't do this in sim — its single-ELF HTIF mailbox model makes recovery's own `printf` invisible (see Discovery E).

The decision was: a strong machine-checkable PASS signal (`exit code = SR_MANIFEST_HEADER bit`) is more valuable than a fragile visible-but-not-exit-able `printf` from recovery. Real silicon would do both.

---

## TODO (in priority order)

1. **More negative tests** — `test_tempering_public_key` already exists scaffolded; verify it also goes PASS strong with exit code = 2 = `SR_PUBLIC_KEY`. Then add a `tempering_signature` variant for stage 2 (when stage 2 is un-stubbed).
2. **Re-test INCREMENT 7 (Ed25519)** — earlier hang may have been zombie-sim contention; clean sim re-test could surprise us by working.
3. **Fix `check_and_load_kernel`** — likely rewrite as single-shot SPI read + one-shot SHA-256 hash. Critical for any real secure boot.
4. **Performance measurement** — boot time breakdown per stage, BootROM image size, gate count.
5. **Final report** — design rationale, threat model, measurements, lessons learned.

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
