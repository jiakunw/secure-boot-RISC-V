# test_tempering_kernel

Negative test: replace the genuine kernel in flash with a **complete
malicious kernel binary**. BootROM Stage 3 (`check_and_load_kernel`) must
detect that `SHA-256(bad_kernel) ≠ manifest->payload_hash` and hand off to
recovery — BEFORE the malicious payload ever executes.

This is the most dramatic negative test in the suite: the attacker has
substituted an entire working RISC-V program for the kernel. If secure boot
fails to catch it, the malicious code's `say("bad kernel!\n")` would print
to console. The test PASS criteria explicitly checks `"bad kernel!"` does
**not** appear in the log.

## What's tampered

The genuine kernel.bin in flash (offset `0xC0`, 7896 bytes) is replaced
wholesale with `bad_kernel.bin`. The manifest, signature, and public key
are all **unchanged** — Stages 0, 1, 2 will all pass; Stage 3 catches the
tamper by hash mismatch.

| Region | Genuine | Tampered |
|---|---|---|
| Manifest (96 B @ `0x00`) | unchanged | unchanged |
| Signature (64 B @ `0x60`) | unchanged | unchanged |
| Pubkey (32 B @ `0xA0`) | unchanged | unchanged |
| **Kernel (`payload_size` B @ `0xC0`)** | `kernel.bin` | **`bad_kernel.bin`** padded to payload_size |

## Design: build-time tamper

Same pattern as `test_tempering_public_key`:
- `bad_kernel.c` is compiled by this directory's `Makefile` into a real
  RISC-V binary (`bad_kernel.bin`)
- `tools/assemble_flash.py` reads the genuine `metadata/{manifest,signature,public_key}.bin`
  from the main repo, reads `bad_kernel.bin`, pads/truncates it to
  `manifest.payload_size`, and concatenates into `tempered_flash_image/flash_image.bin`
- `build.sh` runs the above + converts to Verilator `$readmemh` format
- Run-time staging is just `cp` of the tampered hex into Chipyard's
  Verilator working directory; cleanup restores the good hex

The main repo's `flash_image/*.bin` is never modified.

```
test_tempering_kernel/
├── README.md
├── bad_kernel.c                       # the malicious "replacement kernel" payload
├── Makefile                           # build bad_kernel.c → bad_kernel.bin
├── build.sh                           # one-time: build bad kernel + assemble tampered flash
├── tools/
│   └── assemble_flash.py              # genuine manifest+sig+pubkey + bad_kernel → tampered flash
├── tempered_flash_image/              # build output (checked in)
│   ├── flash_image.bin                # manifest+sig+pubkey+bad_kernel(padded)
│   └── flash_image.hex                # Verilator $readmemh format
├── bad_kernel.riscv                   # compiled bad kernel ELF (Makefile output)
├── bad_kernel.bin                     # raw binary (Makefile output)
├── bad_kernel.dump                    # disassembly for inspection
└── run.sh                             # automated runner: stage + sim + verdict + restore
```

## One-time setup

Run `build.sh` once to compile bad_kernel + assemble the tampered flash:

```bash
bash tests/test_tempering_kernel/build.sh
```

This is fast (~5 sec: one gcc call + one Python). Output is checked into
the repo so the test is deterministic across hosts.

## Run

Three steps: stage tampered hex into Chipyard, run sim, restore good hex.

```bash
# 1) Stage tampered hex (containing bad_kernel instead of genuine kernel)
cp $SECURE_BOOT_REPO/tests/test_tempering_kernel/tempered_flash_image/flash_image.hex \
   $CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex

# 2) Run sim
$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-SecureBootConfig \
    "+payload=$SECURE_BOOT_REPO/software/recovery/recovery.riscv" \
    "$SECURE_BOOT_REPO/software/kernel/kernel.riscv"
echo "exit=$?"

# 3) Restore good hex
cp $SECURE_BOOT_REPO/flash_image/flash_image.hex \
   $CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex
```

Or use `run.sh` (cleanup trap automatic):
```bash
bash tests/test_tempering_kernel/run.sh
```

Wall clock for step 2: ~60-180 s (BootROM runs through stages 0, 1, 2 in
full, loads the whole bad_kernel image from SPI, runs SHA-256 over it, then
detects the mismatch — most expensive of the three negative tests).

## Expected output

```
[UART] UART0 is here (stdin/stdout).
something went wrong, in recovery mode
boot status register = 0x00000008
  - check_and_load_kernel failed (bit 3) -- kernel hash mismatch / bad params
- /home/.../TestDriver.v:158: Verilog $finish
exit=0
```

Note: `"bad kernel!"` is **never** printed — that string would only appear
if BootROM had failed to reject `bad_kernel.bin` and `mret`'d to it.

## PASS criteria

Six signals must hold (one more than the other tests — the explicit
"malicious payload did not run" check):

1. ✓ `kernel started successfully rocket` **absent** (genuine kernel didn't boot)
2. ✓ `bad kernel!` **absent** (malicious payload did NOT execute — the most critical signal)
3. ✓ `something went wrong, in recovery mode` present
4. ✓ `boot status register = 0x00000008` present (= `SR_LOAD_KERNEL` bit set)
5. ✓ `check_and_load_kernel failed` present (recovery decoded the right stage)
6. ✓ `exit=0` (clean `$finish` after recovery returned)

## Trust-chain steps proven by a single PASS

This test exercises the **most complete trust chain** in the project:

1. BootROM read manifest (96 B) from SPI flash, validated magic ✓
2. BootROM read public key (32 B) from SPI flash, computed SHA-256, compared to OTP ✓
3. BootROM (stub) skipped Ed25519 signature check ✓ (stage 2 stubbed)
4. **BootROM read entire kernel region (7896 B) from SPI flash in one SPI transaction**
5. **BootROM ran SHA-256 over the 7896 loaded bytes**
6. **BootROM compared against `manifest->payload_hash` → mismatch**
7. `enter_recovery(SR_LOAD_KERNEL)` set SR bit 3, mret to recovery @ `0x80100000`
8. Recovery main() read SR via MMIO, printed exact diagnostic, exited cleanly

The malicious binary lived in flash with full executable structure — if
secure boot had been weaker (e.g., signed manifest verifies but kernel hash
not checked), the bad_kernel would have executed and emitted `bad kernel!`.
The test demonstrates that the SHA-256 over the loaded kernel is the
unbreakable link between the signed manifest and the running kernel.

## What's different from the other tampering tests

| | manifest_header | public_key | **kernel (this test)** |
|---|---|---|---|
| Tamper target | Manifest magic | Pubkey byte | **Entire kernel image** |
| Catches at stage | 0 | 1 | **3** |
| Manifest re-signed | Yes (over tampered manifest) | No | **No** |
| Signature still valid | Yes | Yes | **Yes** (signature is over manifest, unchanged) |
| Real cryptographic work in BootROM | Magic compare only | SHA-256 + OTP compare | **SHA-256 over 7896 bytes** |
| What's checked in the PASS criteria | 5 signals | 5 signals | **6 signals** (extra: malicious payload didn't run) |
| Separate SoC binary | Yes | No | No |
| Run-time staging | None (config points at test dir) | `cp` to chipyard flash dir | `cp` to chipyard flash dir |
| Restore step needed | No | Yes | Yes |
