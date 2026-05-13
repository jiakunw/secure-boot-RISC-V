# Secure Boot Validation Test Bundle

Drop this whole `validation_tests/` folder into the root of `secure-boot-RISC-V`.

These tests are written for the current repo layout:

```text
software/bootrom/bootrom.c
software/recovery/recovery.c
hardware/secureboot/SecureBootConfig.scala
hardware/spi_flash/rtl/spi_flash.scala
hardware/otp/rtl/otp.scala
hardware/rollback_counter/rtl/rollback_counter.scala
hardware/ed25519/rtl/ed25519_verifier.scala
metadata/*.bin
flash_image/flash_image.bin
flash_image/flash_image.hex
```

The tests are split into two groups.

## Quick tests

These do not need Verilator. They check that the generated image files and source policy match the secure-boot design.

Run:

```bash
bash validation_tests/run_all.sh --quick
```

This gives fast output you can paste into the report.


## Regenerating stale generated files

If the quick artifact check says the flash kernel region does not match `software/kernel/kernel.bin`, regenerate the files before running simulator tests:

```bash
bash validation_tests/regenerate_artifacts.sh
```

This uses the current kernel, current key files, and existing signing tools in the repo.

## Simulator tests

These modify the boot image, copy the modified hex into Chipyard, run the simulator, collect logs, and restore the original files after each test.

Run:

```bash
bash validation_tests/run_all.sh --sim
```

or run everything:

```bash
bash validation_tests/run_all.sh --all
```

The simulator tests need:

```bash
.env with CHIPYARD_HOME set
built simulator at $CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-SecureBootConfig
built kernel at software/kernel/kernel.riscv
built recovery at software/recovery/recovery.riscv
```

If the simulator is not built yet, run your normal integration/build first:

```bash
bash scripts/integrate_to_chipyard.sh
cd "$CHIPYARD_HOME/sims/verilator"
make CONFIG=SecureBootConfig -j"$(nproc)"
```

## What this covers

The bundle gives each important area multiple checks:

| Area | Covered checks |
|---|---|
| repo/image artifacts | file sizes, manifest fields, flash layout, public-key hash, kernel hash, Ed25519 signature |
| BootROM source policy | stage order, status bits, SPI reads, OTP check, Ed verifier path, rollback, PMP, scratch clear, fence/fence.i |
| manifest/header | good manifest, bad magic, bad header version, bad size/address cases |
| public key / OTP | correct key hash, flipped public key, all-zero public key |
| signature | correct signature, flipped signature, all-zero signature |
| kernel hash/load | correct kernel hash, flipped kernel byte, zero payload size, bad load address |
| whole system | positive boot, negative boot rejection, recovery/status evidence |
| performance | wall-clock timing and log summary for boot runs |

The scripts do not fake results. They print what they actually saw and save logs under `validation_tests/logs/`.
