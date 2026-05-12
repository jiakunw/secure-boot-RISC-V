# Negative Tests

Self-contained tamper-detection tests. Each verifies one stage of the BootROM chain-of-trust by corrupting one byte in `flash_image.bin`, running the simulator, and checking that:

1. The kernel does **not** boot normally (no `kernel started successfully` banner)
2. (When recovery printf is visible) The recovery firmware reports which stage caught the tamper via the Status Register

## Prerequisites

You need a built simulator and built recovery image already:
```bash
bash scripts/integrate_to_chipyard.sh
touch hardware/secureboot/SecureBootConfig.scala
cd $CHIPYARD_HOME/sims/verilator && make -j$(nproc) CONFIG=SecureBootConfig
```

Tests do **not** require re-elaborating Verilator — they only modify `flash_image.hex` which is loaded via `$readmemh` at simulator startup.

## Running

```bash
# One test:
bash tests/test_tempering_public_key/run.sh

# All tests:
bash tests/run_all.sh
```

Each test takes ~5 minutes (sim runtime).

## Test inventory

| Test | What it tampers | Expected SR bit | Expected recovery line |
|---|---|---|---|
| `test_tempering_manifest_header` | byte 0 of manifest magic (`'S'` → `0xAC`) | `0x01` (bit 0) | `check_manifest_header failed (bit 0)` |
| `test_tempering_public_key` | byte 5 of flash-resident public key (XOR with `0xFF`) | `0x02` (bit 1) | `check_public_key failed (bit 1)` |

## Safety

Each `run.sh` uses `trap cleanup EXIT` to restore the original `flash_image.bin`, `flash_image.hex`, and the in-Chipyard copy at `$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex` — even on Ctrl-C or sim crash. The repository state after a test is byte-identical to before.

## Known issues

- **Recovery printf may not display.** FESVR scans the *first* ELF passed on the command line for `tohost`/`fromhost` symbols. Since `kernel.riscv` is passed first, FESVR only watches `kernel.riscv`'s tohost; `recovery.riscv`'s tohost writes go unseen. When this is the case, tests rely on the negative signal (absence of kernel banner) to detect tamper-catching. See `PROGRESS.md` for the design path to align both ELFs' tohost addresses.
