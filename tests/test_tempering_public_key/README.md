# test_tempering_public_key

Negative test: flip a byte of the public key in the SPI flash image. The OTP
peripheral is burned with `SHA-256(original public_key.bin)` at silicon
elaboration time, so any bit-flip in the flash-resident pubkey makes
`SHA-256(tampered) ≠ OTP-burned hash`. BootROM Stage 1 (`check_public_key`)
detects the mismatch and hands off to recovery.

## Design: build-time tamper

This test follows the same pattern as `test_tempering_manifest_header`:
the tampered flash image is **pre-generated** by `build.sh` and lives in this
directory. Running the test only requires staging the tampered hex into
Chipyard's working directory and running the regular `SecureBootConfig` sim.
**The main repo's `flash_image/*.bin` is never modified.**

```
test_tempering_public_key/
├── README.md
├── build.sh                          # one-time: generate tampered artifacts
├── tools/
│   └── tamper_pubkey.py              # XOR pubkey byte 5, reassemble flash_image
├── tempered_flash_image/             # build output (checked in)
│   ├── public_key.bin                # 32 B, byte 5 XOR'd with 0xFF
│   ├── flash_image.bin               # original manifest+sig + tampered pubkey + original kernel
│   └── flash_image.hex               # Verilator $readmemh format
└── run.sh                            # automated runner: stage + sim + verdict + restore
```

The signature in the tampered flash is the **original** signature (over the
original manifest). It's still cryptographically valid against the manifest
— BootROM rejects boot at Stage 1 (`check_public_key`) BEFORE the signature
check is ever reached.

## One-time setup

Run `build.sh` once to (re)generate the tampered artifacts:

```bash
bash tests/test_tempering_public_key/build.sh
```

This is fast (~1 sec, pure Python). The output is committed to the repo so the
test is fully deterministic — you only need to re-run `build.sh` if you change
the genuine `metadata/public_key.bin` or `metadata/manifest.bin`.

## Run

The Verilator simulator (`simulator-chipyard.harness-SecureBootConfig`) reads
the flash hex via `$readmemh` from
`$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex` at startup. To
run this test, swap that file with the tampered version, run the sim, then
restore.

```bash
# 1) Stage tampered hex
cp $SECURE_BOOT_REPO/tests/test_tempering_public_key/tempered_flash_image/flash_image.hex \
   $CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex

# 2) Run sim
$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-SecureBootConfig \
    "+payload=$SECURE_BOOT_REPO/software/recovery/recovery.riscv" \
    "$SECURE_BOOT_REPO/software/kernel/kernel.riscv"
echo "exit=$?"

# 3) Restore the good hex from the repo
cp $SECURE_BOOT_REPO/flash_image/flash_image.hex \
   $CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex
```

Wall clock for step 2: ~30-120 s (pubkey SHA-256 + OTP compare runs first,
then fails).

Or use `run.sh` which does all three steps automatically with a cleanup trap:
```bash
bash tests/test_tempering_public_key/run.sh
```

## Expected output (step 2)

```
[UART] UART0 is here (stdin/stdout).
something went wrong, in recovery mode
boot status register = 0x00000002
  - check_public_key failed (bit 1) -- OTP root-of-trust mismatch
- /home/.../TestDriver.v:158: Verilog $finish
exit=0
```

## PASS criteria

All five must hold:

1. ✓ `kernel started successfully rocket` **absent** (BootROM rejected the image)
2. ✓ `something went wrong, in recovery mode` present (BootROM mret'd to recovery)
3. ✓ `boot status register = 0x00000002` present (= `SR_PUBLIC_KEY` bit set)
4. ✓ `check_public_key failed (bit 1) -- OTP root-of-trust mismatch` present
5. ✓ `exit=0` (sim exited cleanly via `$finish` after recovery returned)

## Trust-chain steps proven by a single PASS

This is the strongest crypto demonstration in the project — it exercises the
**real SHA-256 + OTP-anchored root of trust**, not a stub:

1. BootROM read 32 bytes of public key from SPI flash @ offset `0xA0`
2. BootROM ran real SHA-256 over those bytes (MonoCypher implementation)
3. BootROM read 32 bytes from OTP MMIO `0xF0000000` (the at-manufacture-burned
   hash of the genuine pubkey)
4. BootROM did byte-for-byte compare → mismatch on the tampered hash
5. `enter_recovery(SR_PUBLIC_KEY)` set SR bit 1, mret to recovery @ `0x80100000`
6. Recovery's main() read SR via MMIO, printed exact diagnostic, exited cleanly

This proves: an attacker with full control of SPI flash **cannot substitute a
different public key** even if they hold a valid signing key, because they
cannot match the SHA-256 hash burned into OTP at silicon manufacture time.

## What's different from `test_tempering_manifest_header`

| | `test_tempering_manifest_header` | `test_tempering_public_key` |
|---|---|---|
| Tamper target | Manifest magic (`SOBT` → `DEAD`) | Pubkey byte (XOR `0xFF`) |
| Catches at stage | 0 (`check_manifest_header`) | 1 (`check_public_key`) |
| Signature re-signed | Yes (sign tampered manifest) | No (signature is over manifest, unchanged) |
| Separate SoC binary | Yes (`TemperedSecureBootConfig`) | No (reuses `SecureBootConfig`) |
| Verilator rebuild needed | Yes (~20 min one-time) | No |
| What's staged at run time | Nothing (SoC config points to test dir) | Tampered hex → Chipyard's default flash dir |
| Restore step needed | No | Yes (cp back the good hex) |

The `test_tempering_manifest_header` design is more isolated (no chipyard
state changes at run time) but requires a Verilator rebuild. This test trades
that for ~zero rebuild cost by sharing the happy-path sim binary.
