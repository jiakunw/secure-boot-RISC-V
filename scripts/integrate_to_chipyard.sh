#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERROR: do not source this script."
  echo "Run it with:"
  echo "  bash scripts/integrate_to_chipyard.sh"
  return 1
fi

set -e

# ─────────────────────────────────────────────
# Locate repo + load .env
# ─────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
export SECURE_BOOT_REPO="$REPO_ROOT"

if [ ! -f "$REPO_ROOT/.env" ]; then
    echo "Error: .env not found at $REPO_ROOT/.env"
    echo "Run: cp .env.example .env && edit it to set CHIPYARD_HOME"
    exit 1
fi

source "$REPO_ROOT/.env"

if [ -z "$CHIPYARD_HOME" ] || [ ! -d "$CHIPYARD_HOME" ]; then
    echo "Error: CHIPYARD_HOME invalid: '$CHIPYARD_HOME'"
    exit 1
fi

# Auto-source Chipyard env (RISC-V toolchain)
if [ -f "$CHIPYARD_HOME/env.sh" ]; then
    source "$CHIPYARD_HOME/env.sh"
fi

# Verify toolchain available
if ! command -v riscv64-unknown-elf-gcc &> /dev/null; then
    echo "Error: riscv64-unknown-elf-gcc not in PATH"
    echo "Did you 'source $CHIPYARD_HOME/env.sh'?"
    exit 1
fi

CHIPYARD=$CHIPYARD_HOME
MYREPO=$REPO_ROOT
TESTS_DIR=$CHIPYARD/tests

echo "Using Chipyard at: $CHIPYARD"
echo "Repo root:         $MYREPO"
echo "RISCV toolchain:   $(which riscv64-unknown-elf-gcc)"

# ─────────────────────────────────────────────
# 1. Symlink Chisel sources
# ─────────────────────────────────────────────
echo ""
echo "[1/5] Linking Chisel sources..."
SCALA_OUT_DIR=$CHIPYARD/generators/chipyard/src/main/scala/secureboot
SCALA_SOURCES=$(find "$MYREPO/hardware" -path "*/tb/*" -prune -o -name "*.scala" -type f -print)

if [ -n "$SCALA_SOURCES" ]; then
    mkdir -p "$SCALA_OUT_DIR"
    # Delete ONLY the symlinks pointing into $MYREPO/hardware/ — preserves
    # test-suite symlinks (e.g., TemperedSecureBootConfig.scala installed by
    # tests/*/build.sh, which points into $MYREPO/tests/).
    find "$SCALA_OUT_DIR" -maxdepth 1 -type l -lname "$MYREPO/hardware/*" -delete 2>/dev/null || true

    while IFS= read -r src; do
        ln -sf "$src" "$SCALA_OUT_DIR/"
        echo "  Linked $(basename "$src")"
    done <<< "$SCALA_SOURCES"

    SCALA_COUNT=$(echo "$SCALA_SOURCES" | wc -l)
    echo "  Linked $SCALA_COUNT Chisel file(s)."
else
    echo "  (No Chisel sources yet, skipping)"
fi

# Stage SystemVerilog blackbox sources into Chipyard's resources/vsrc/.
# `HasBlackBoxResource + addResource("/vsrc/Foo.sv")` resolves files via the
# chipyard generator's classpath resources, which is rooted here.
VSRC_OUT_DIR=$CHIPYARD/generators/chipyard/src/main/resources/vsrc
SV_SOURCES=$(find "$MYREPO/hardware" -path "*/tb/*" -prune -o \( -name "*.sv" -o -name "*.v" \) -type f -print | grep -v '^$' || true)

if [ -n "$SV_SOURCES" ]; then
    mkdir -p "$VSRC_OUT_DIR"
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        ln -sf "$src" "$VSRC_OUT_DIR/"
        echo "  Linked $(basename "$src") -> resources/vsrc/"
    done <<< "$SV_SOURCES"
fi

echo ""
echo ""
echo "[1b/5] Linking Ed25519 verifier peripheral..."
mkdir -p "$CHIPYARD/generators/chipyard/src/main/scala/secureboot"
mkdir -p "$CHIPYARD/generators/chipyard/src/main/resources/vsrc"

ED_SRC="$MYREPO/hardware/ed25519/rtl/ed25519_verifier.scala"
ED_DST="$CHIPYARD/generators/chipyard/src/main/scala/secureboot/ed25519_verifier.scala"

if [ "$(readlink -f "$ED_SRC")" = "$(readlink -f "$ED_DST" 2>/dev/null || echo "$ED_DST")" ]; then
    echo "  ed25519_verifier.scala already staged"
else
    cp -f "$ED_SRC" "$ED_DST"
fi

ED_SV_SRC="$MYREPO/hardware/ed25519/vsrc/Ed25519VerifierSim.sv"
ED_SV_DST="$CHIPYARD/generators/chipyard/src/main/resources/vsrc/Ed25519VerifierSim.sv"

if [ "$(readlink -f "$ED_SV_SRC")" = "$(readlink -f "$ED_SV_DST" 2>/dev/null || echo "$ED_SV_DST")" ]; then
    echo "  Ed25519VerifierSim.sv already staged"
else
    cp -f "$ED_SV_SRC" "$ED_SV_DST"
fi

echo "  Linked ed25519_verifier.scala"
echo "  Linked Ed25519VerifierSim.sv"

# Check/patch the subsystem class that mixes in the other secureboot traits.
echo "  Checking DigitalTop Ed25519 trait..."
python3 - "$CHIPYARD/generators/chipyard/src/main/scala" <<'PY2'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

# If already patched anywhere, do not fail.
for p in root.rglob("*.scala"):
    s = p.read_text(errors="ignore")
    if "with chipyard.CanHavePeripherySecureBootEd25519" in s or "with CanHavePeripherySecureBootEd25519" in s:
        print(f"  CanHavePeripherySecureBootEd25519 already patched in {p}")
        raise SystemExit(0)

# Find the actual mixin site, not the trait-definition file.
candidates = []
for p in root.rglob("*.scala"):
    s = p.read_text(errors="ignore")
    if "trait CanHavePeripherySecureBootSR" in s:
        continue
    if re.search(r"with\s+(chipyard\.)?CanHavePeripherySecureBootSR\b", s):
        candidates.append(p)

if not candidates:
    print("Error: could not find DigitalTop/subsystem mixin site with CanHavePeripherySecureBootSR")
    raise SystemExit(1)

target = candidates[0]
s = target.read_text()
m = re.search(r"with\s+(chipyard\.)?CanHavePeripherySecureBootSR\b", s)
if not m:
    print(f"Error: candidate found but SR mixin line missing: {target}")
    raise SystemExit(1)

qualifier = m.group(1) or ""
insert = f"\n  with {qualifier}CanHavePeripherySecureBootEd25519"
s = s[:m.end()] + insert + s[m.end():]
target.write_text(s)
print(f"  Patched {target} with CanHavePeripherySecureBootEd25519")
PY2


echo "[1c/5] Patching Chipyard DigitalTop for secure boot peripherals (OTP + Rollback + SPI + Status Register)..."
DIGITAL_TOP=$CHIPYARD/generators/chipyard/src/main/scala/DigitalTop.scala
if [ -f "$DIGITAL_TOP" ]; then
    if ! grep -q "CanHavePeripherySecureBootOTP" "$DIGITAL_TOP"; then
        sed -i.bak '/with chipyard.example.CanHavePeripheryGCD/i\  with chipyard.CanHavePeripherySecureBootOTP // OTP for pubkey hash root of trust' "$DIGITAL_TOP"
        echo "  Added CanHavePeripherySecureBootOTP to DigitalTop."
    else
        echo "  CanHavePeripherySecureBootOTP already patched."
    fi

    if ! grep -q "CanHavePeripherySecureBootRollback" "$DIGITAL_TOP"; then
        sed -i.bak '/with chipyard.example.CanHavePeripheryGCD/i\  with chipyard.CanHavePeripherySecureBootRollback // Anti-rollback monotonic counter' "$DIGITAL_TOP"
        echo "  Added CanHavePeripherySecureBootRollback to DigitalTop."
    else
        echo "  CanHavePeripherySecureBootRollback already patched."
    fi

    if ! grep -q "CanHavePeripherySecureBootSPI" "$DIGITAL_TOP"; then
        sed -i.bak '/with chipyard.example.CanHavePeripheryGCD/i\  with chipyard.CanHavePeripherySecureBootSPI // Enables the secure-boot MMIO SPI controller' "$DIGITAL_TOP"
        echo "  Added CanHavePeripherySecureBootSPI to DigitalTop."
    else
        echo "  CanHavePeripherySecureBootSPI already patched."
    fi

    if ! grep -q "CanHavePeripherySecureBootSR" "$DIGITAL_TOP"; then
        sed -i.bak '/with chipyard.example.CanHavePeripheryGCD/i\  with chipyard.CanHavePeripherySecureBootSR // Boot-status register: which verification stage failed' "$DIGITAL_TOP"
        echo "  Added CanHavePeripherySecureBootSR to DigitalTop."
    else
        echo "  CanHavePeripherySecureBootSR already patched."
    fi
else
    echo "  Warning: DigitalTop.scala not found; secure boot peripherals will not instantiate."
fi

# ─────────────────────────────────────────────
# 2. Build BootROM
# ─────────────────────────────────────────────
echo ""
echo ""
echo "[1b/5] Ed25519 verifier uses peripheral path; no BootROM LUT generation needed."


echo "[2/5] Building BootROM..."
if [ -f "$MYREPO/software/bootrom/Makefile" ]; then
    cd "$MYREPO/software/bootrom"
    make
    if [ -f "bootrom.img" ]; then
        cp bootrom.img \
           $CHIPYARD/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img
        mkdir -p "$CHIPYARD/sims/verilator/generated-src/chipyard.harness.TestHarness.SecureBootConfig"
        cp bootrom.img \
           "$CHIPYARD/sims/verilator/generated-src/chipyard.harness.TestHarness.SecureBootConfig/bootrom.secureboot.rv64.img"
        BOOTROM_IMG_SIZE=$(stat -c%s bootrom.img)
        echo "  Built and copied to Chipyard."
        echo "  Size: ${BOOTROM_IMG_SIZE} bytes"
        if [ "$BOOTROM_IMG_SIZE" -gt 65536 ]; then
            echo "  Error: bootrom.img exceeds 64 KiB BootROM size"
            exit 1
        fi
    else
        echo "  Error: bootrom.img not produced"
        exit 1
    fi
else
    echo "  (No BootROM Makefile, skipping)"
fi

# ─────────────────────────────────────────────
# 3. Copy kernel + recovery sources
# ─────────────────────────────────────────────
echo ""
echo "[3/5] Copying kernel + recovery sources to Chipyard tests..."

shopt -s nullglob
KERNEL_C_SOURCES=("$MYREPO"/software/kernel/*.c)
KERNEL_H_SOURCES=("$MYREPO"/software/kernel/*.h)
shopt -u nullglob

if [ ${#KERNEL_C_SOURCES[@]} -gt 0 ]; then
    cp "${KERNEL_C_SOURCES[@]}" "$TESTS_DIR/"
    if [ ${#KERNEL_H_SOURCES[@]} -gt 0 ]; then
        cp "${KERNEL_H_SOURCES[@]}" "$TESTS_DIR/"
    fi
    echo "  Copied kernel source(s)."
else
    echo "  Error: no kernel .c sources found in:"
    echo "    $MYREPO/software/kernel"
    echo "  This must exist before manifest/signature/flash can be generated."
    exit 1
fi

## Recovery firmware is built standalone via its own Makefile below (not
## copied into Chipyard's tests dir; it needs a custom linker script that
## conflicts with Chipyard's global -T htif.ld).

# ─────────────────────────────────────────────
# 4. Patch CMakeLists.txt (idempotent)
# ─────────────────────────────────────────────
echo ""
echo "[4/5] Patching CMakeLists.txt..."

CMAKE_FILE=$TESTS_DIR/CMakeLists.txt

if ! grep -q "add_executable(kernel kernel.c)" "$CMAKE_FILE"; then
    cat >> "$CMAKE_FILE" << 'EOF'

# Added by integrate_to_chipyard.sh
add_executable(kernel kernel.c)
add_dump_target(kernel)
EOF
    echo "  Added 'kernel' target."
else
    echo "  Already patched (kernel)."
fi

## (Recovery target intentionally not added to Chipyard's CMakeLists.txt
## because the global -T htif.ld there conflicts with recovery.ld.
## Recovery is built standalone via its own Makefile below.)

# ─────────────────────────────────────────────
# 5. Build kernel + recovery via cmake
# ─────────────────────────────────────────────
echo ""
echo "[5/5] Building kernel + recovery..."

mkdir -p "$TESTS_DIR/build"

# Always reconfigure so CMakeLists.txt changes are picked up
cmake -S "$TESTS_DIR" -B "$TESTS_DIR/build" -D CMAKE_BUILD_TYPE=Debug

cmake --build "$TESTS_DIR/build" --target kernel

# Chipyard may place the final ELF in $TESTS_DIR instead of $TESTS_DIR/build.
ELF_PATH="$TESTS_DIR/build/kernel.riscv"
if [ ! -f "$ELF_PATH" ] && [ -f "$TESTS_DIR/kernel.riscv" ]; then
    ELF_PATH="$TESTS_DIR/kernel.riscv"
fi

BIN_PATH="$TESTS_DIR/build/kernel.bin"
KERNEL_REPO_DIR="$MYREPO/software/kernel"

if [ -f "$ELF_PATH" ]; then
    echo "  Extracting kernel.bin from $ELF_PATH..."
    riscv64-unknown-elf-objcopy -O binary "$ELF_PATH" "$BIN_PATH"

    cp "$ELF_PATH" "$KERNEL_REPO_DIR/kernel.riscv"
    cp "$BIN_PATH" "$KERNEL_REPO_DIR/kernel.bin"
    echo "  Success: kernel.riscv + kernel.bin copied to $KERNEL_REPO_DIR/"
else
    echo "  Error: kernel.riscv was not found after CMake build"
    echo "  Checked: $TESTS_DIR/build/kernel.riscv"
    echo "  Checked: $TESTS_DIR/kernel.riscv"
    exit 1
fi

echo "  Regenerating manifest, signature, and flash image from the rebuilt kernel..."
(
    cd "$MYREPO/tools"
    python3 manifest_generators.py
    python3 sign_firmware.py
    python3 flash_image_to_hex.py \
        --input "$MYREPO/flash_image/flash_image.bin" \
        --output "$MYREPO/flash_image/flash_image.hex"
)
mkdir -p "$CHIPYARD/sims/verilator/flash_image"
cp "$MYREPO/flash_image/flash_image.hex" "$CHIPYARD/sims/verilator/flash_image/"
echo "  Success: flash_image.hex staged for Verilator runtime reads."

# Build recovery firmware standalone via its own Makefile (custom linker
# script recovery.ld placing it at 0x80100000).
if [ -f "$MYREPO/software/recovery/Makefile" ]; then
    echo "  Building recovery firmware..."
    cd "$MYREPO/software/recovery"
    make clean >/dev/null 2>&1 || true
    if make 2>&1 | tail -3; then
        if [ -f "recovery.riscv" ]; then
            echo "  Success: recovery.riscv built (linked at 0x80100000)"
            echo "    Size: $(stat -c%s recovery.riscv) bytes"
        else
            echo "  Error: recovery.riscv was not produced"
            exit 1
        fi
    else
        echo "  Error building recovery firmware"
        exit 1
    fi
fi

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
echo ""
echo "============================================"
echo "Integration complete."
echo "============================================"
echo ""
echo "To run with default Chipyard config (no secure boot):"
echo "  cd $CHIPYARD/sims/verilator"
echo "  make CONFIG=RocketConfig"
echo "  ./simulator-chipyard.harness-RocketConfig $KERNEL_REPO_DIR/kernel.riscv"
echo ""
echo "To run with your secure boot config (recovery passed via +payload=,"
echo "which is FESVR's way to load extra ELFs alongside the primary kernel):"
echo "  cd $CHIPYARD/sims/verilator"
echo "  make CONFIG=SecureBootConfig"
echo "  ./simulator-chipyard.harness-SecureBootConfig \\"
echo "      +payload=$MYREPO/software/recovery/recovery.riscv \\"
echo "      $KERNEL_REPO_DIR/kernel.riscv"
