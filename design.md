# Secure Boot Design Notes

## 1. Goal

This project builds a secure boot flow for a Rocket/Chipyard RISC-V system. The CPU starts in BootROM, treats flash as untrusted input, checks the boot image, and only jumps to the kernel after the checks pass.

The main things protected are:

- the boot image in flash
- the public key used for signing
- the manifest fields
- the kernel bytes
- rollback state
- BootROM / OTP / secure MMIO after boot

## 2. Chain of Trust

```text
reset
↓
CPU starts in BootROM
↓
BootROM reads manifest, signature, public key, and kernel from flash
↓
BootROM reads the trusted public-key hash from OTP
↓
BootROM hashes the public key from flash
↓
BootROM compares that hash to the OTP hash
↓
BootROM sends manifest, signature, and public key to the Ed25519 verifier
↓
Ed verifier returns pass or fail
↓
BootROM hashes the loaded kernel with SHA-256
↓
BootROM compares the kernel hash to the signed manifest hash
↓
BootROM checks the manifest version against the rollback counter
↓
BootROM updates the rollback counter if the image is newer
↓
BootROM locks protected regions with PMP
↓
BootROM clears scratch data
↓
BootROM runs fence and fence.i
↓
BootROM jumps to the verified kernel
```

Flash is not trusted. BootROM is the first trusted code.

## 3. Main Components

| Component | What it connects to | What it does |
|---|---|---|
| BootROM | reset path, SPI, OTP, rollback, Ed verifier, PMP CSRs | first trusted code and boot policy |
| SPI flash model | BootROM through SPI/MMIO | stores manifest, signature, public key, and kernel |
| OTP | BootROM through MMIO | stores the trusted public-key hash |
| Ed25519 verifier | BootROM through MMIO | checks the signed manifest |
| SHA-256 code | BootROM C | hashes the loaded kernel |
| Rollback counter | BootROM through MMIO | stores the highest accepted version |
| PMP | BootROM through CSRs | locks protected regions before handoff |
| Recovery image | loaded by FESVR | prints why boot failed |
| Kernel | DRAM | runs only after the checks pass |

## 4. Memory Map

| Region | Address |
|---|---:|
| BootROM | `0x00010000` |
| OTP public-key hash | `0xF0000000` |
| Rollback counter | `0xF0001000` |
| SPI controller | `0xF0002000` |
| Boot status register | `0xF0003000` |
| Ed25519 verifier | `0xF0004000` |
| Kernel DRAM load | `0x80000000` |

## 5. Flash Layout

```text
0x00000  manifest      96 bytes
0x00060  signature     64 bytes
0x000A0  public key    32 bytes
0x000C0  kernel        variable size
```

The manifest is signed. The kernel bytes are hashed and compared to the hash inside the manifest.

## 6. Boot Status Bits

| Bit | Value | Meaning |
|---|---:|---|
| bit 0 | `0x00000001` | manifest header failed |
| bit 1 | `0x00000002` | public key / OTP check failed |
| bit 2 | `0x00000004` | Ed25519 manifest signature failed |
| bit 3 | `0x00000008` | kernel load/hash failed |
| bit 4 | `0x00000010` | rollback check failed |
| bit 5 | `0x00000020` | PMP lock failed |

## 7. Ed25519 Fix

The first Ed implementation tried to run full Ed25519 verification inside BootROM C using MonoCypher. The signing data was valid, and host-side MonoCypher accepted the same manifest, signature, and public key. The problem was that the full curve check did not finish fast enough under Verilator when run as BootROM firmware.

We tried a software lookup-table path first. That found a real table bug: the generated public-key table was only one cached point (`0xA0`) when the code expected a 64-entry table (`0x2800`). That was fixed, but the software Ed path still timed out.

The final fix keeps BootROM in charge of the boot policy, but moves the expensive Ed25519 work to a verifier peripheral.

BootROM now does this:

```text
check public key against OTP
send manifest/signature/public key to Ed verifier
wait for pass/fail
continue only on pass
```

The Ed verifier lives at `0xF0004000`.

| Offset | Register | Purpose |
|---|---|---|
| `0x00` | command | clear or start |
| `0x04` | status | busy, done, pass, error |
| `0x08` | count | bytes received |
| `0x0c` | data | 32-bit input word |

BootROM writes 192 bytes:

```text
96 bytes manifest
64 bytes signature
32 bytes public key
```

The Verilator model writes those bytes to `/tmp` and calls `tools/verify_ed25519_from_files.py`, which uses MonoCypher on the host side.

This should be described as:

```text
BootROM-controlled Ed25519 verifier peripheral.
```

Do not describe it as:

```text
BootROM C computes the full Ed25519 curve operation.
```

## 8. Rollback

BootROM reads the signed manifest version and the rollback counter.

```text
if image version < counter:
    enter recovery

if image version > counter:
    write image version to the counter
    read back and confirm it moved forward
```

The rollback hardware only accepts writes that increase the value. Real cross-reset rollback protection would need nonvolatile storage. The current Chisel model gives the monotonic behavior in simulation.

## 9. PMP Lock

After verification, BootROM programs locked PMP entries.

| Region | Permission |
|---|---|
| BootROM | locked execute-only |
| secure MMIO window | locked no-access |
| DRAM | locked read/write/execute |

The secure MMIO window covers OTP, rollback, SPI, status, and Ed verifier MMIO.

BootROM writes PMP addresses first, then writes the locked config. It reads the PMP CSRs back and enters recovery if the values do not match.

## 10. Scratch Cleanup and Handoff

Before jumping to the kernel, BootROM clears:

- manifest buffer
- signature buffer
- public key buffer
- public key hash buffer
- OTP hash buffer
- kernel hash buffer
- kernel chunk buffer

Then BootROM runs:

```text
fence
fence.i
```

Then BootROM jumps to the signed entry point.

## 11. Active Build Path

BootROM now builds with:

```text
bootrom.S
bootrom.c
sha256.c
```

BootROM should not depend on:

```text
ed25519.o
monocypher.o
secureboot_ed25519_lut.h
generate_ed25519_lut.py
```

The Ed verifier path is:

```text
hardware/ed25519/rtl/ed25519_verifier.scala
hardware/ed25519/vsrc/Ed25519VerifierSim.sv
tools/verify_ed25519_from_files.py
```

## 12. Build and Run

From the repo root:

```bash
export CHIPYARD_HOME=/root/chipyard
export SECURE_BOOT_REPO="$(pwd)"

bash scripts/integrate_to_chipyard.sh
CHIPYARD_HOME=/root/chipyard ./scripts/check_secureboot_freshness.sh
```

Then rebuild the simulator:

```bash
cd /root/chipyard
source env.sh

export CHIPYARD_HOME=/root/chipyard
export SECURE_BOOT_REPO="/mnt/c/Users/lbarc/OneDrive/Documents/Hardware Security/secure-boot-RISC-V"

cd /root/chipyard/sims/verilator

rm -rf generated-src/chipyard.harness.TestHarness.SecureBootConfig
rm -f /root/chipyard/.classpath_cache/chipyard.jar

make CONFIG=SecureBootConfig -j"$(nproc)"
```

Run the positive boot:

```bash
cd /root/chipyard/sims/verilator

set +e
timeout 300 stdbuf -oL ./simulator-chipyard.harness-SecureBootConfig \
  +payload="$SECURE_BOOT_REPO/software/recovery/recovery.riscv" \
  "$SECURE_BOOT_REPO/software/kernel/kernel.riscv" \
  2>&1 | tee /tmp/secureboot_positive.log

RC=${PIPESTATUS[0]}
set -e

echo "sim exit code: $RC"

grep -nE "kernel started|recovery|boot status|signature|public_key|rollback|PMP|FAILED|tohost|Verilog|finish|trap|fault|UART|Terminated" \
  /tmp/secureboot_positive.log || true
```

Expected:

```text
kernel started successfully rocket
sim exit code: 0
```

## 13. Freshness Rules

Do not trust a sim run unless freshness passes.

The common stale mistakes are:

- old BootROM copied into Chipyard resources
- old flash copied into Verilator
- kernel changed but manifest/signature/flash not regenerated
- key changed but OTP hash not regenerated
- SecureBootConfig changed but simulator not rebuilt
- Ed verifier Scala/SV changed but simulator not rebuilt

The freshness script checks:

- required files exist
- public key hash matches OTP hash file
- flash contains the current public key
- staged flash matches repo flash
- staged BootROM matches repo BootROM

## 14. Known Working Results

### Positive boot

```text
[UART] UART0 is here (stdin/stdout).
kernel started successfully rocket
Verilog $finish
sim exit code: 0
```

### Tampered manifest

A byte was flipped inside the signed manifest region without resigning.

```text
[UART] UART0 is here (stdin/stdout).
something went wrong, in recovery mode
boot status register = 0x00000004
  - check_manifest_signature failed (bit 2) -- Ed25519 invalid
Verilog $finish
sim exit code: 0
```

### Positive boot after rollback/PMP/scratch changes

```text
[UART] UART0 is here (stdin/stdout).
kernel started successfully rocket
Verilog $finish
sim exit code: 0
```

## 15. Remaining Validation

Still validate:

- tampered kernel should fail the SHA-256 check
- wrong public key should fail the OTP check
- downgrade image should fail rollback
- post-boot read from protected regions should fault or be denied
- post-boot write to protected regions should fault or be denied
- PMP lock should prevent later PMP reconfiguration
- waveforms should show flash read, OTP read, Ed verifier start/pass, rollback access, PMP lock, and handoff

## 16. Git Notes

Do not commit:

```text
.metals/
.vscode/
*.o
temporary logs
```

Be careful with:

```text
metadata/private_key.bin
```

For a class demo it may already be tracked, but real signing keys should not be committed.
