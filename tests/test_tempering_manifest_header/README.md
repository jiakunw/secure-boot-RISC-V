# test_tempering_manifest_header

Negative test: tamper the manifest magic field. BootROM Stage 0
(`check_manifest_header`) must detect the bad magic and hand off to recovery
firmware. Recovery reads the Status Register and prints which stage failed.

## What's tampered

The manifest's 32-bit magic field at offset `0x00` of `flash_image.bin`:

| | Value (LE bytes) | ASCII |
|---|---|---|
| Original | `53 4F 42 54` | `SOBT` (`0x54424F53`) |
| Tampered | `44 45 41 44` | `DEAD` (`0x44414544`) |

The tampered flash image lives at `tempered_flash_image/flash_image.bin`/`.hex`
in this directory. It was generated once at project setup by
`tools/manifest_generators.py` + `tools/sign_firmware.py` and is checked into the
repo. No regeneration needed for re-runs.

## Why a parallel SoC and not just a hex swap?

The Verilator simulator binary loads its SPI flash hex via Verilog `$readmemh`
at startup. The hex file path is baked into the SoC's `WithSecureBootSPI` Scala
config. To use a tampered hex without overwriting the happy-path one, we build
a separate `TemperedSecureBootConfig` that points the SPI at
`tempered_flash_image/flash_image.hex`. This produces a separate simulator
binary `simulator-chipyard.harness-TemperedSecureBootConfig` that coexists with
the happy-path sim.

The Scala config + generation tools live alongside this README so the test is
self-contained.

## One-time setup

Stage the tampered hex into Chipyard's Verilator working directory (Verilator
expects flash hex paths *relative to the working directory*):

```bash
mkdir -p $CHIPYARD_HOME/sims/verilator/tempered_flash_image
cp $SECURE_BOOT_REPO/tests/test_tempering_manifest_header/tempered_flash_image/flash_image.hex \
   $CHIPYARD_HOME/sims/verilator/tempered_flash_image/
```

The tampered hex is only read at simulator startup; no Verilator rebuild needed
after staging it.

(If the simulator binary doesn't exist yet, run
`bash $SECURE_BOOT_REPO/tests/test_tempering_manifest_header/build.sh` once,
which builds it via `make CONFIG=TemperedSecureBootConfig`. ~15-25 min.)

## Run

From any directory with the test environment loaded
(see [tests/README.md](../README.md) for setup):

```bash
$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-TemperedSecureBootConfig \
    "+payload=$SECURE_BOOT_REPO/software/recovery/recovery.riscv" \
    "$SECURE_BOOT_REPO/software/kernel/kernel.riscv"
echo "exit=$?"
```

Wall clock: ~30-90 s (BootROM fails fast at Stage 0 + recovery runs).

## Expected output

```
[UART] UART0 is here (stdin/stdout).
something went wrong, in recovery mode
boot status register = 0x00000001
  - check_manifest_header failed (bit 0)
- /home/.../TestDriver.v:158: Verilog $finish
exit=0
```

## PASS criteria

All five must hold:

1. ✓ `kernel started successfully rocket` **absent** (BootROM rejected the image)
2. ✓ `something went wrong, in recovery mode` present (BootROM successfully
   `mret`'d to recovery at `0x80100000`)
3. ✓ `boot status register = 0x00000001` present (recovery read the SR MMIO
   register and decoded `SR_MANIFEST_HEADER`)
4. ✓ `check_manifest_header failed (bit 0)` present (recovery correctly named
   the failing stage)
5. ✓ `exit=0` (sim exited cleanly via `$finish` after recovery returned)

If you see `exit code = 128`: BootROM's `mret_trap_exit` safety net fired —
recovery wasn't loaded into DRAM. Make sure you used `+payload=` (not positional)
for recovery.riscv.

## Trust-chain steps proven by a single PASS

1. BootROM Stage 0 detected bad magic (Stage 0 logic correct)
2. `enter_recovery(SR_MANIFEST_HEADER)` wrote `0x01` to SR MMIO at `0xF0003000`
3. BootROM pre-armed `mtvec` to `mret_trap_exit` safety stub (never fired —
   mret succeeded)
4. BootROM `mret`'d to `0x80100000`
5. Recovery's `_start` ran through htif_nano crt0 (FP init, TLS, BSS clear,
   `__libc_init_array`)
6. Recovery's `main()` reached, read SR via MMIO, formatted diagnostic lines
7. Each line written via `write(1, ...)` syscall → `htif_syscall` →
   `tohost = ptr_to_syscall_struct` at `0x80001e00`
8. FESVR processed each syscall, printed chars to host stdout
9. `main()` returned 0 → `_exit(0)` → `tohost = 1` → FESVR called `$finish`

A different exit code or missing line would point to which link in the chain
broke.

## Files in this directory

| File | Purpose |
|---|---|
| `README.md` | This file |
| `TemperedSecureBootConfig.scala` | Alternate SoC config pointing SPI at tampered hex; symlinked into chipyard's secureboot dir at build time |
| `tools/manifest_generators.py` | Generates `tempered_flash_image/manifest.bin` with bad magic |
| `tools/sign_firmware.py` | Signs tampered manifest + assembles `flash_image.bin` |
| `tools/flash_image_to_hex.py` | Converts `.bin` → `$readmemh`-format `.hex` |
| `tempered_flash_image/flash_image.{bin,hex}` | Pre-generated tampered artifacts |
| `build.sh` | One-shot rebuild of the entire tempered SoC pipeline |
| `run.sh` | Test runner with PASS-criteria grep; see notes in [tests/README.md](../README.md) about known buffering issues — prefer running the sim command above manually |
