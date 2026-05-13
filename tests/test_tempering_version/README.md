# test_tempering_version

Negative test: **rollback / downgrade attack**. Install an old (lower-version)
signed firmware on a chip whose rollback counter has already been advanced
by a newer firmware. BootROM Stage 4 (`check_rollback_counter`) must
detect `manifest.version < counter` and hand off to recovery.

## What's tampered

| | Value | Effect |
|---|---|---|
| Manifest magic | `0x54424F53` (`SOBT`, genuine) | Stage 0 passes |
| Manifest signature | valid Ed25519 over manifest | Stage 2 passes (stubbed anyway) |
| Public key | genuine | Stage 1 (SHA-256 + OTP compare) passes |
| Kernel | genuine | Stage 3 (SHA-256 hash compare) passes |
| **Manifest `version`** | **`1`** (vs counter reset to `5`) | **Stage 4 rejects** |

The manifest is a **fully valid, correctly signed** firmware — just an
older version. Without rollback protection, an attacker could install such
firmware and exploit any vulnerability patched in newer versions.

## Why a separate SoC

This test is the only one that requires changing **hardware behavior** to
demonstrate the attack: the rollback counter must contain a value > 1
*at sim start* to model "an earlier newer firmware already bumped the
counter". In real silicon this state would persist across reboots via
eFuse / anti-fuse storage; in Verilator, registers reset to 0 every run.

We work around this by elaborating a separate
`TamperedRollbackSecureBootConfig` SoC with the rollback counter
peripheral's `resetValue` set to `5`. The peripheral was extended in
`hardware/rollback_counter/rtl/rollback_counter.scala` to accept this
parameter (default `0` preserves real-silicon-faithful behavior).

## Design overview

```
test_tempering_version/
├── README.md
├── TamperedRollbackSecureBootConfig.scala   # SoC: rollback counter resetValue=5,
│                                             # SPI flash points at tempered hex
├── tools/
│   ├── manifest_generators.py               # genuine-magic manifest with VERSION=1
│   ├── sign_firmware.py                     # real signing — valid Ed25519
│   └── flash_image_to_hex.py                # bin → Verilator $readmemh format
├── tempered_flash_image/                    # build.sh output (checked in)
│   ├── manifest.bin                         # VERSION=1, genuine magic
│   ├── signature.bin                        # valid Ed25519 sig over manifest
│   ├── flash_image.bin                      # manifest + sig + pubkey + kernel
│   └── flash_image.hex                      # Verilator $readmemh format
├── build.sh                                 # one-time: generate artifacts + build sim (~20 min)
└── run.sh                                   # automated runner: sim + verdict
```

## One-time setup

```bash
bash tests/test_tempering_version/build.sh
```

This (a) regenerates `tempered_flash_image/*` from the main repo's
metadata, (b) stages the hex into Chipyard's Verilator working directory,
(c) symlinks the SoC config into Chipyard, (d) builds the
`TamperedRollbackSecureBootConfig` sim binary (~15-25 min Verilator
build).

## Run

```bash
$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-TamperedRollbackSecureBootConfig \
    "+payload=$SECURE_BOOT_REPO/software/recovery/recovery.riscv" \
    "$SECURE_BOOT_REPO/software/kernel/kernel.riscv"
echo "exit=$?"
```

Or:
```bash
bash tests/test_tempering_version/run.sh
```

Wall clock: ~60-180 s. BootROM runs through Stages 0, 1, 2, 3 in full
(real crypto every step), then catches the downgrade at Stage 4.

## Expected output

```
[UART] UART0 is here (stdin/stdout).
something went wrong, in recovery mode
boot status register = 0x00000010
  - check_rollback_counter failed (bit 4) -- version too old
- /home/.../TestDriver.v:158: Verilog $finish
exit=0
```

## PASS criteria

Five signals:

1. ✓ `kernel started successfully rocket` **absent**
2. ✓ `something went wrong, in recovery mode` present
3. ✓ `boot status register = 0x00000010` present (= `SR_ROLLBACK_COUNTER` bit 4)
4. ✓ `check_rollback_counter failed` present
5. ✓ `exit=0` (clean `$finish`)

## Trust-chain story

This test exercises ALL preceding stages with **real cryptography** before
the rollback check fires:

1. BootROM read manifest from SPI flash, validated `SOBT` magic ✓
2. BootROM read pubkey from SPI flash, SHA-256'd it, compared to OTP-burned hash ✓
3. BootROM (stub) skipped Ed25519 signature check — signature is genuinely valid ✓
4. BootROM read full kernel (7896 B) from SPI flash, SHA-256'd it, matched manifest's payload_hash ✓
5. **BootROM read rollback counter MMIO: `0xF0001000` → `5`**
6. **BootROM read manifest.version: `1`**
7. **`1 < 5` → `enter_recovery(SR_ROLLBACK_COUNTER)`**
8. Recovery main() read SR, printed exact diagnostic, exited cleanly

Without the rollback counter check (Stage 4), a signed-but-old firmware
would pass *every other stage* and execute. This test demonstrates that
the monotonic counter is the **only** defense against re-installing
previously-patched-out vulnerable firmware.

## Hardware change in this commit

`hardware/rollback_counter/rtl/rollback_counter.scala`:
- Added `resetValue: BigInt = 0` to `SecureBootRollbackParams`
- Used `RegInit(params.resetValue.U(64.W))` instead of `RegInit(0.U(64.W))`
- Added `resetValue` parameter to `WithSecureBootRollback` config

Default `resetValue=0` preserves real-silicon-faithful behavior for the
happy path and all other tests. Only this test elaborates with non-zero
`resetValue=5`.

## What's different from the other tampering tests

| | manifest_header | public_key | kernel | **version (this test)** |
|---|---|---|---|---|
| Tamper target | Manifest magic | Pubkey byte | Kernel image | **Manifest `version` field** |
| Stage caught at | 0 | 1 | 3 | **4** |
| Real crypto exercised | magic compare | SHA-256+OTP | SHA-256+OTP+SHA-256-kernel | **all preceding + counter compare** |
| Hardware change | None | None | None | **rollback counter `resetValue` param** |
| Separate SoC binary | Yes | No | No | **Yes** (needs hardware param override) |
| Verilator rebuild needed | One-time (~20 min) | No | No | **One-time (~20 min)** |
