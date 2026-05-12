# Tests

Three end-to-end tests for the secure-boot SoC. All run against a Verilator-built
simulator binary. Two negative tests verify that BootROM rejects tampered firmware
and hands off to recovery; one positive test verifies a clean boot.

| Test | What it tampers | Expected BootROM stage | Expected SR bit |
|---|---|---|---|
| **Happy path** (this README) | nothing | all stages pass, mret to kernel | none — kernel banner appears |
| [test_tempering_manifest_header](test_tempering_manifest_header/) | manifest magic (`SOBT` → `DEAD`) | Stage 0 (`check_manifest_header`) | `0x01` |
| [test_tempering_public_key](test_tempering_public_key/) | one byte of public key | Stage 1 (`check_public_key`) | `0x02` |
| [test_tempering_kernel](test_tempering_kernel/) | entire kernel image (replaced with a malicious binary that would print `bad kernel!`) | Stage 3 (`check_and_load_kernel`) | `0x08` |

---

## Environment setup (every new terminal)

```bash
cd /home/wangjiakun/Development/secure-boot-RISC-V
export CONDA_BACKUP_RISCV=${CONDA_BACKUP_RISCV:-}
source .env && source $CHIPYARD_HOME/env.sh
```

This puts `riscv64-unknown-elf-gcc`, Verilator, and python3 on `$PATH` and sets
`$CHIPYARD_HOME`, `$SECURE_BOOT_REPO`. Verify:

```bash
which riscv64-unknown-elf-gcc       # → .../chipyard/.conda-env/.../gcc
echo "$CHIPYARD_HOME"               # → /home/wangjiakun/Development/chipyard
echo "$SECURE_BOOT_REPO"            # → /home/wangjiakun/Development/secure-boot-RISC-V
```

## Prerequisites

The Verilator simulator binaries must already exist:
- `$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-SecureBootConfig` (happy + public-key tests)
- `$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-TemperedSecureBootConfig` (manifest-header test)

If they don't, build them:
```bash
# from $SECURE_BOOT_REPO
bash scripts/integrate_to_chipyard.sh                 # builds BootROM/kernel/recovery
cd $CHIPYARD_HOME/sims/verilator
make -j$(nproc) CONFIG=SecureBootConfig
bash $SECURE_BOOT_REPO/tests/test_tempering_manifest_header/build.sh
```

Each Verilator rebuild is 10-25 min depending on host load and swap pressure.

---

## Happy path — kernel boots cleanly

Run the sim against the **untampered** flash image:

```bash
$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-SecureBootConfig \
    "+payload=$SECURE_BOOT_REPO/software/recovery/recovery.riscv" \
    "$SECURE_BOOT_REPO/software/kernel/kernel.riscv"
echo "exit=$?"
```

### Expected output

```
[UART] UART0 is here (stdin/stdout).
kernel started successfully rocket
- /home/.../TestDriver.v:158: Verilog $finish
exit=0
```

### PASS criteria

- ✓ `kernel started successfully rocket` appears
- ✓ `Verilog $finish` appears (sim ended cleanly, not killed)
- ✓ `exit=0`

Wall clock: ~60-180 s depending on host load.

---

## Negative tests

Each negative test directory has its own `README.md` with the tamper procedure,
sim command, expected output, and PASS criteria. They follow the same shape:

1. Stage tampered artifacts into Chipyard's Verilator working directory
2. Run the appropriate sim binary with `+payload=` for recovery and a positional
   `kernel.riscv`
3. Inspect the sim's stdout for the recovery banner, SR readout, and clean `$finish`

---

## Why `+payload=` and not positional `recovery.riscv`?

FESVR (the simulator's frontend server) loads only `targs[0]` via its symbol-aware
`load_program()`. Additional positional args are silently ignored. To get
recovery.riscv loaded into DRAM at `0x80100000`, it must be passed via the
`+payload=` plusarg — which routes through FESVR's `load_payload` chain.

If you pass recovery as a positional arg (`./sim kernel.riscv recovery.riscv`),
recovery never gets loaded, BootROM's `mret` to `0x80100000` traps on an illegal
instruction (the safety-net stub `mret_trap_exit` fires), and the sim exits with
exit code `0x80` (= 128).

---

## Common output decoding

| Sim host exit | What it means |
|---|---|
| `0` | Clean `$finish` — happy path booted, or recovery main() returned 0 |
| `255` | Verilog `$stop` — assertion fired (`*** FAILED *** (exit code = N)`); the SoC-level exit code N is in the log |
| `124` | External `timeout` killed sim — wall clock exceeded |
| `137` | SIGKILL (host OOM-killed or manual `kill -9`) |
| other | Sim crashed before normal exit |

FESVR's `(exit code = N)` assertion line decodes as: `N = tohost >> 1` where
tohost was the last value the CPU wrote. So `tohost = 3` → exit code 1 →
`SR_MANIFEST_HEADER` was the failing stage.

---

## About the `run.sh` files in each test directory

Each test directory has a `run.sh` that wraps the above commands with cleanup
traps, timeouts, and PASS-criteria grep. **They have known buffering issues**
under certain shell configurations (sim output may not flush to the redirect
file before the verdict block reads it). The `README.md` in each directory
gives copy-paste commands that bypass `run.sh` entirely and are more reliable
for manual verification.
