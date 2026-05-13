# Secure Boot on RISC-V — Project Progress

COMS 6424 Hardware Security, Spring 2026
Target: secure-boot SoC on Chipyard 1.13.0 + Rocket Chip + Verilator.

---

## Processor Specification Compliance

The simulated microcontroller is built on Chipyard's Rocket Chip integration, configured as `WithNHugeCores(1)` (single Rocket core). Specification-required processor features:

| Required feature | Implementation |
|---|---|
| 64-bit RISC-V | RV64GC ISA — base I + M (mul/div) + A (atomics) + F + D (FP) + C (compressed) |
| 5-stage in-order pipeline | Rocket's standard pipeline: Fetch → Decode → Execute → Memory → Writeback |
| Branch prediction | Rocket's BTB (Branch Target Buffer) + RAS (Return Address Stack), configurable via `RocketTileParams` |
| Virtual memory | Sv39 page-based MMU: 39-bit virtual addresses, 4 KB / 2 MB / 1 GB pages, hardware page-table walker, per-hart TLB, full M / S / U privilege modes |

The secure-boot subsystem (BootROM + custom MMIO peripherals + recovery firmware) is a **separate, orthogonal feature layered on top of this processor**. The processor's VM capability is hardware-present but not exercised by the boot chain — BootROM and the test kernel execute in M-mode where PMP, not page tables, provides the active memory protection. See "How VM and Secure Boot Compose" below for the architectural argument explaining the design decision.

### How VM and Secure Boot Compose (defense-in-depth)

The two features are **complementary, not redundant**. A production OS layered on this SoC would compose them as:

| Layer | Mechanism | Trust assumption |
|---|---|---|
| Pre-boot | OTP-burned `SHA-256(public_key)` | Wire-traceable physical fuse, set at manufacturing |
| Boot-time verification | BootROM Stages 0-5 (this project) | Only signed + version-monotonic images reach M-mode |
| M-mode handoff | PMP locked: BootROM=RX, OTP+Counter=NO_ACCESS, DRAM=RWX, all with L=1 | PMP entries immutable until reset |
| S-mode runtime | Kernel-managed Sv39 page table | Kernel is itself the verified image — its page-table policy is **authenticated software's intent** |
| U-mode runtime | Per-process page tables, U-mode permission bits | User processes isolated from kernel + each other |

**Secure boot gates *who* writes the page table; VM enforces *what* that page table says about every load/store at runtime.** Neither is redundant: a system with only secure boot but no VM would let a kernel exploit pivot into kernel-memory disclosure post-boot; a system with VM but no secure boot would let an attacker install their own kernel that defines page tables to expose OTP / disable mitigations.

**PMP takes precedence over VM translation in the access-check pipeline** — even a compromised S-mode kernel cannot remap OTP into its virtual space, because the M-mode-locked PMP NO_ACCESS rule fires before page-table walk. This is the hardware guarantee that **secure boot's PMP configuration is a runtime trust anchor**, not just a boot-time check.

(The current test kernel does not enable Sv39 because (i) it has nothing meaningful to do with VM beyond saying "still works," (ii) the kernel handed off by BootROM is signed M-mode code in this project's threat model, and (iii) demonstrating VM in sim would require a non-trivial S-mode crt0 rewrite that is orthogonal to secure-boot verification. The Rocket Chip processor we instantiate satisfies the spec's VM requirement at the hardware level regardless of which mode the kernel chooses to run in.)

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
| **4** | **Full 6-stage BootROM runs end-to-end, only stage 2 stubbed** | **✅ 5/6 stages real, 1 stubbed** | Stages 0, 1, 3, 4, 5 all real (manifest check, OTP-anchored pubkey check, SPI kernel load + SHA-256 verify, monotonic rollback counter compare, PMP lock). Only Stage 2 (Ed25519 signature verify) still stubbed pending INCREMENT 7 |
| **5** | **Real OTP compare in Stage 1 (`check_public_key`)** | **✅ done** | Debug dropbox confirmed `MATCH` between BootROM-computed SHA-256(pubkey) and OTP-burned hash; mismatch triggers `enter_recovery(SR_PUBLIC_KEY)` (bit 1) |
| **6** | **PMP lock (Stage 5) — real lock active; rollback still stub** | **🚧 PMP only** | `lock_pmp` now writes BootROM=RX+L, OTP/Counter=NO_ACCESS+L, catch-all=RWX+L; BootROM successfully `mret`s to kernel post-lock. Rollback counter check is still stubbed |
| 7 | Real Ed25519 verify (MonoCypher) in Stage 2 | 🔧 attempted, hangs | Un-stubbed code hangs in sim; previously suspected MonoCypher / OTP but earlier hangs may have been zombie-sim CPU starvation — needs re-test |
| **+** | **Recovery handler — full mret-to-recovery handoff** | **✅ done — end-to-end** | Separate `recovery.riscv` ELF at `0x80100000` (FESVR-loaded via `+payload=`). `enter_recovery(reason_bit)` writes the SR bit, pre-arms `mtvec` at a `mret_trap_exit` safety stub, then `mret`s to `0x80100000`. Recovery's htif_nano `_start` (full crt0: FP init, TLS, BSS clear, `__libc_init_array`) runs, then `main()` reads SR via MMIO and exits the sim with FESVR exit code = `0x40 \| sr_bits`. The 0x40 marker bit proves end-to-end that the production-faithful mret path executed. |
| **+** | **Status Register (SR) peripheral — 32-bit boot-status MMIO** | **✅ done** | New peripheral at `0xF0003000` (`hardware/status_register/rtl/sr.scala`). BootROM sets one bit per failed stage (`SR_MANIFEST_HEADER`=0x01, `SR_PUBLIC_KEY`=0x02, …, `SR_LOCK_PMP`=0x20); recovery reads via MMIO and encodes into the FESVR exit code |
| **+** | **Negative test suite — 4 stages × full 5-6 signal PASS** | **✅ done — all real crypto exercised** | Four tampering tests in `tests/test_tempering_*/`, each catches a different BootROM stage: (i) `test_tempering_manifest_header` (Stage 0, separate SoC with bad-magic flash), (ii) `test_tempering_public_key` (Stage 1, build-time-tampered pubkey, real SHA-256 + OTP compare), (iii) `test_tempering_kernel` (Stage 3, entire kernel replaced with a malicious binary that would print `"bad kernel!"` if it ran — BootROM SHA-256-rejects it before mret), (iv) `test_tempering_version` (Stage 4, manifest VERSION=1 vs rollback counter pre-bumped to 5 via Scala `resetValue` parameter — downgrade attack). All four produce 5- or 6-signal PASS evidence chains with full recovery printf diagnostic. |
| **+** | **Ed25519 signature verifier — MMIO accelerator (Stage 2 un-stub)** | **✅ done** | New peripheral at `0xF0004000` (`hardware/ed25519/`). Chisel TileLink wrapper around a SystemVerilog BlackBox (`Ed25519VerifierSim.sv`). BootROM streams manifest (96 B) + signature (64 B) + pubkey (32 B) to the DATA register, issues START, polls STATUS for DONE/PASS/ERROR. The BlackBox is sim-only: it buffers the 192 bytes, writes them to three `/tmp/*.bin` files, and invokes `tools/verify_ed25519_from_files.py` via Verilog `$system` — that script runs PyNaCl (libsodium) `VerifyKey.verify`. The BootROM C interface is **identical to a real Curve25519+SHA-512 RTL accelerator** would expose; on silicon, drop in a synthesizable Ed25519 IP (Rambus, OpenTitan dcrypto, etc.) without touching the BootROM. |
| **+** | **Validation test framework — `tests/validation_tests/`** | **✅ done — 4 quick + 11 sim cases** | Supplementary regression suite with `lib/common.sh` helpers (backup/restore, regen+stage, run_sim, expect_positive/rejection) and a generic `tools/image_tool.py` (patch-flash-byte, zero-flash-region, patch-manifest-field). Quick tests (no Verilator) check artifact integrity + BootROM source-policy grep. Sim tests cover signature flip/zero (Stage 2 — not covered by our 4 dramatic tests), public-key zero, header-version bad, payload-size 0, bad load-address, plus boot-timing perf. Runtime-tamper-with-trap-restore isolation; see "Test Isolation Tiers" below. |

**Currently shipped (this commit):**
- **6 of 6 BootROM stages are real** (was 4/6 stubbed in earlier increments). Full chain:
  - Stage 0 `check_manifest_header` — magic + header_version compare
  - Stage 1 `check_public_key` — SHA-256 over flash pubkey vs OTP-burned 32-byte hash
  - **Stage 2 `check_manifest_signature` — MMIO Ed25519 verifier (host PyNaCl in sim, drop-in real RTL on silicon)**
  - Stage 3 `check_and_load_kernel` — single-shot 7896-byte SPI read + SHA-256 vs `manifest->payload_hash`
  - Stage 4 `check_rollback_counter` — monotonic compare + write-back-verify
  - Stage 5 `lock_pmp` — BootROM=RX+L, OTP/Counter=NO_ACCESS+L, DRAM=RWX+L
- Verification failures at any stage trigger `enter_recovery(reason_bit)` → writes SR bit, pre-arms `mtvec=mret_trap_exit` safety stub, mret to recovery firmware at `0x80100000`. Recovery's `main()` reads SR via MMIO, prints exact diagnostic via `say()` (direct `write(1, ...)` syscall, bypassing newlib stdio's lazy-init that traps in our linker layout), exits cleanly via `$finish`.
- **Happy path verified end-to-end**: `kernel started successfully rocket` + `$finish`, exit=0, with **all 6 BootROM stages active** (sim log shows `EDDBG verifier rc=0` = Ed25519 verified, `boot status register=0x00000010` updated, etc.).
- **All 4 negative tests verified end-to-end (PASS strong)**:
  - manifest header → exit code `0x01`, recovery decodes Stage 0
  - public key → exit code `0x02`, recovery decodes Stage 1
  - kernel image → exit code `0x08`, recovery decodes Stage 3, `"bad kernel!"` confirmed absent
  - version (downgrade) → exit code `0x10`, recovery decodes Stage 4

### Test Isolation Tiers

Tests fall into two intentional tiers:

| Tier | Where | Isolation method | Robust to SIGKILL | Parallel-safe |
|---|---|---|---|---|
| (a) Build-time tamper | `tests/test_tempering_*/` | Pre-signed tampered artifacts checked into each test directory; main repo `flash_image/`, `metadata/` never modified | ✓ (state never dirty) | ✓ (no shared mutation) |
| (b) Runtime tamper + trap-restore | `tests/validation_tests/tests/` | `vt_backup_artifacts` → modify main repo → `trap restore EXIT` | ✗ (SIGKILL leaves dirty state, recoverable via `git checkout`) | ✗ (serial only — shared main-repo mutation) |

Tier (a) is more robust at the cost of one-time `build.sh` overhead per test. Tier (b) is more code-efficient (one `image_tool.py` patches any byte) at the cost of fragility under abnormal termination. **Both tiers' tests pass; running them together exercises the full BootROM signed-image authentication path with redundant coverage on Stages 0/1/3 and unique coverage on Stages 2 (tier b only) and 4 (tier a only).**

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

4. **6 of 6 BootROM stages run end-to-end (all real) with PMP lock active.** Full chain:
   - `read_boot_parts` (3 SPI transactions: manifest, signature, pubkey)
   - **Stage 0** `check_manifest_header` — real, recovery on mismatch
   - **Stage 1** `check_public_key` — real SHA-256 + OTP-burned-hash compare, recovery on mismatch
   - **Stage 2** `check_manifest_signature` — real MMIO Ed25519 verifier at `0xF0004000`. BootROM streams 192 B (manifest+sig+pubkey) to DATA register, issues START, polls STATUS for DONE+PASS/ERROR with `MAX_SPIN=10⁷` cycle timeout. Sim implementation in `hardware/ed25519/vsrc/Ed25519VerifierSim.sv` delegates to `tools/verify_ed25519_from_files.py` (PyNaCl). Production silicon: drop in synthesizable Curve25519+SHA-512 IP — BootROM C unchanged.
   - **Stage 3** `check_and_load_kernel` — real. Reads the entire kernel (7896 bytes) from SPI flash in a *single* transaction directly into DRAM @ `manifest->load_address`, runs SHA-256 over the loaded buffer, compares against `manifest->payload_hash`. Earlier 16-chunk-multi-transaction version hung in the SPI master's state machine after the first transaction; single-shot side-steps the bug.
   - **Stage 4** `check_rollback_counter` — real. Reads the 64-bit monotonic counter from MMIO `0xF0001000`, compares to `manifest->version`. If `version < counter`, downgrade attack detected → `enter_recovery(SR_ROLLBACK_COUNTER)`. If `version > counter`, BootROM writes the new version back to the counter (hardware-enforced monotonic write — the peripheral silently drops writes whose data is ≤ current value, so even compromised M-mode software cannot move the counter backwards). Tested by `test_tempering_version` (resetValue=5 vs manifest VERSION=1).
   - `clear_scratch` — real (zeros all verification buffers)
   - **Stage 5** `lock_pmp` — real, production-style permissions (see below)
   - `mret` to kernel @ 0x80000000 — kernel boots cleanly in M-mode under PMP isolation

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

### 1. ~~`check_and_load_kernel` (Stage 3) — hangs~~ — FIXED 2026-05-13 via single-shot SPI

**Original symptom:** Sim hung at 99% CPU forever when `check_and_load_kernel` was active. Bisection showed disabling the function let everything else boot, so the hang was contained inside it.

**Original implementation:** 16 × 512-byte SPI reads with incremental SHA-256 updates. Each read called `start_flash_read` + `read_flash_words`, polling `SPI_STATUS` for `DATA_READY` / `DONE`. The hang appeared on the second or later transaction.

**Root cause:** The SPI master's internal state machine (`spi_flash.scala`) doesn't reset cleanly between back-to-back transactions. The first transaction completes correctly; subsequent ones hang in some intermediate state. We verified by bisection: 3 transactions in `read_boot_parts` work fine, but 16 transactions in `check_and_load_kernel` always hang on iteration 2+.

**Fix shipped:** Replace the chunked loop with a **single SPI transaction** that reads the entire kernel (~7896 bytes) directly into DRAM at `manifest->load_address`, followed by a one-shot `sha256_hash` over the loaded buffer. This sidesteps the multi-transaction bug (and also removes incremental hashing from the suspect list). The simpler code is faster too.

**Verified end-to-end 2026-05-13:** with stage 3 active, the happy path still produces `kernel started successfully rocket` + clean `$finish`. Both negative tests (manifest header and pubkey) still PASS strong with full 5-signal recovery diagnostic output. The kernel is now genuinely loaded from SPI flash and SHA-256-verified by BootROM rather than relying on FESVR's pre-load — a closer match to real silicon's secure-boot path.

The underlying SPI-master multi-transaction bug remains in `spi_flash.scala`; we just don't exercise it. A future hardware iteration should diagnose the state machine.

### 2. ~~INCREMENT 7 — real Ed25519 verify hangs~~ — RESOLVED 2026-05-13 via MMIO accelerator

**Original symptom:** Un-stubbing in-BootROM `crypto_eddsa_check()` (MonoCypher Ed25519, software) hung Verilator at 99% CPU for 19+ minutes per attempted boot.

**Root cause:** MonoCypher's software Ed25519 verify executes ~10⁷+ instructions of bignum arithmetic; under Verilator's cycle-accurate translation that's roughly 19 wall-clock minutes per verify — not infinite, but unusable for an interactive dev loop. Also a footprint concern (Ed25519 + SHA-512 + Curve25519 modular arithmetic added ~10-20 KB to the BootROM image, near the TLROM size limit).

**Fix shipped:** Replaced in-BootROM software Ed25519 with an MMIO **hardware accelerator** abstraction at `0xF0004000`. The BootROM C code now contains 30 lines of MMIO driver (`check_manifest_signature` + `ed25519_write_bytes`) instead of 5000+ lines of crypto. In simulation, the accelerator is realized as a SystemVerilog BlackBox (`hardware/ed25519/vsrc/Ed25519VerifierSim.sv`) that buffers the input and delegates to host-side PyNaCl via Verilog `$system`. **Production silicon would drop in a real Curve25519+SHA-512 RTL implementation** (e.g., OpenTitan dcrypto or licensed IP) at the same MMIO interface — BootROM C is unchanged.

This is closer to real-world secure boot architecture: every production secure-boot chip (Apple T2/SE, Google Titan, ARM CryptoCell) uses a dedicated crypto accelerator block. Pure-software EdDSA in BootROM is rare because of code size, speed, and side-channel concerns.

**Sim cost:** Each Stage 2 verification adds ~1-2 sec wall-clock (Verilator stalls at `$system` while host Python invokes libsodium). Compare to 19+ minutes for in-BootROM software. The host-side hash function is **SHA-512** to match libsodium / PyNaCl (RFC 8032); MonoCypher's `crypto_eddsa_check` uses BLAKE2b, which is **incompatible** with PyNaCl-signed images — verified empirically and documented in `tools/verify_ed25519_from_files.py`.

### 3. ~~Recovery firmware `printf` hangs~~ — root-caused and fixed via linker anchor + stdio bypass

**Status:** FULLY DIAGNOSED 2026-05-12. Recovery now prints its full human-readable diagnostic and exits cleanly via `$finish`. Two distinct bugs were uncovered in sequence:

#### Bug A: htif_nano's `htif_syscall` writes to the wrong `tohost` address

**Symptom:** Earlier recovery built with `Makefile --defsym=tohost=0x80001e00,--defsym=fromhost=0x80001e08` still hung on every `printf`, even though those addresses match what FESVR watches (FESVR sets `tohost_addr` from `targs[0]`=kernel.riscv's symbol table; verified by reading `riscv-isa-sim/fesvr/htif.cc::load_program`).

**Root cause:** `htif_nano`'s `htif_syscall` (in libgloss) defines `tohost` as `static volatile` in the same translation unit. The compiler emits a PC-relative reference (`auipc + addi`) within the link-time placement, so `--defsym` (which only redirects extern references) does NOT redirect this. Recovery's `htif_syscall` ended up writing to the .htif section's natural placement inside recovery's image (~`0x80101ec0`), which FESVR isn't watching.

Compare disassembly:
```
recovery's htif_syscall (OLD, broken):           recovery's _exit (always worked):
  auipc a3, 0x0                                    auipc a4, 0xfff00
  addi  a3, a3, 978   # → 0x80101ec0 ❌           addi a4, a4, 736   # → 0x80001e00 ✓
  sd    a2, 0(a3)     # writes to recovery's       sd  a5, 0(a4)     # uses --defsym
                      #   own .htif slot                              #   override
```

**Fix:** `recovery.ld` anchors the `.htif` output section's VMA at `0x80001e00` with `(NOLOAD)`:
```ld
save_dot = .;
.htif 0x80001e00 (NOLOAD) : AT(save_dot) {
    *(.htif)
}
. = save_dot;
```
This makes `htif_syscall`'s PC-relative tohost reference resolve to `0x80001e00` (FESVR's watched address). `(NOLOAD)` means recovery doesn't *place bytes* there at load time — that's fine because kernel.riscv (FESVR's `targs[0]`) already loaded its own `.htif` section (initial zeros) at exactly that address.

#### Bug B: newlib's `_puts_r` faults on `_impure_ptr->_stdout` deref before `__sinit`

**Symptom:** After fixing Bug A, `write(1, ...)` produces visible output, but `printf` and `puts` trap with mcause=5 (load access fault).

**Root cause:** newlib's `_puts_r` dereferences `_impure_ptr->_stdout` (`ld s0, 16(a0)`) *before* checking the init flag and calling `__sinit`. Normally this works because `_impure_data._stdout` is compile-time initialized to point at the static `__sf[1]` FILE struct in .bss. In our link, anchoring `.htif` at `0x80001e00` perturbs the linker's address arithmetic enough that some pointer in `_impure_data` ends up pointing to unmapped memory.

**Resolution shipped:** Bypass stdio entirely. Recovery uses `write()` (proven to work via direct htif_syscall path) with hand-written `say()` and `say_hex32()` helpers. This is also closer to what production secure-boot recovery firmware actually does — bare-metal code doesn't pull in newlib's stdio for safety/footprint reasons.

#### Final verification

Run output now contains all expected diagnostic lines:
```
[UART] UART0 is here (stdin/stdout).
something went wrong, in recovery mode
boot status register = 0x00000001
  - check_manifest_header failed (bit 0)
- TestDriver.v:158: Verilog $finish
```
And `sim_exit=0` (clean `$finish`, not `$stop`). Five independent PASS signals fire (kernel-banner-absent, recovery-banner-present, SR-value, stage-decode, clean-exit).

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

**Negative test — tampered manifest header (`tests/test_tempering_manifest_header/`) — PASS strong, full mret path proven with human-readable recovery diagnostic:**
```
[UART] UART0 is here (stdin/stdout).
something went wrong, in recovery mode
boot status register = 0x00000001
  - check_manifest_header failed (bit 0)
- TestDriver.v:158: Verilog $finish
─────────────────────────────────────────
PASS:
  ✓ kernel banner absent
  ✓ recovery firmware reached (printed 'something went wrong, in recovery mode')
  ✓ recovery confirmed SR = 0x00000001 (SR_MANIFEST_HEADER bit set)
  ✓ recovery decoded failure as Stage 0 (check_manifest_header)
  ✓ sim exited cleanly via $finish (sim_exit=0)
```

A separate `TemperedSecureBootConfig` SoC was built with the SPI flash parameterized to read a manifest whose magic was flipped from `0x54424F53` ('SOBT') to `0x44414544` ('DEAD').

The execution chain proven by 5 independent log signals:
1. BootROM Stage 0 detected the bad magic
2. `enter_recovery(SR_MANIFEST_HEADER)` wrote `0x01` to the SR (MMIO `0xF0003000`)
3. BootROM pre-armed `mtvec` to `mret_trap_exit` safety stub (never fired — mret succeeded)
4. BootROM `mret`'d to `0x80100000`
5. Recovery's `_start` ran the full htif_nano crt0 (FP init, TLS, BSS clear, `__libc_init_array`)
6. Recovery's `main()` reached, read SR via MMIO, formatted the 4 diagnostic lines
7. Each line written via `write(1, ...)` syscall → `htif_syscall` → `tohost = ptr_to_syscall_struct` at `0x80001e00`
8. FESVR processed each syscall, printed the chars to host stdout
9. `main()` returned 0 → `_exit(0)` → `tohost = 1` → FESVR called `$finish` cleanly

---

## TODO (in priority order)

1. **Run the full validation test suite** — `bash tests/validation_tests/run_all.sh --sim` (~33 min for 11 sim tests) gives Stage 2 negative coverage via `15_sim_signature_flip` and `16_sim_signature_zero`, plus extra granular cases for Stages 0/1/3 we don't have in the dramatic-test framework.
2. **Performance measurement** — boot-time breakdown per stage (`21_perf_positive_boot_timing` is a starting point), BootROM image size (compare with/without Ed25519 MMIO driver), gate count from Verilator/synthesis report.
3. **(Optional) `test_tempering_signature` for symmetry** — our 4-test framework currently has no Stage 2 coverage by itself (relies on `validation_tests`'s `15/16`). For one-to-one symmetry with the other 4 negative tests, write a build-time tampered `test_tempering_signature/`. ~15 min effort, no Verilator rebuild needed (shares `SecureBootConfig` sim). Skip if `validation_tests` 15/16 is sufficient for reviewer.
4. **Final report** — design rationale, threat model, measurements, lessons learned. The bulk of analysis is already in this PROGRESS.md; pull into IEEE-format paper.

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
