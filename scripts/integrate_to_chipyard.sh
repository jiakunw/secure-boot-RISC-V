#!/bin/bash
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
echo "[1b/5] Preparing flash image hex..."
if [ -f "$MYREPO/tools/flash_image_to_hex.py" ] && [ -f "$MYREPO/flash_image/flash_image.bin" ]; then
    python3 "$MYREPO/tools/flash_image_to_hex.py" \
        --input "$MYREPO/flash_image/flash_image.bin" \
        --output "$MYREPO/flash_image/flash_image.hex"
    mkdir -p "$CHIPYARD/sims/verilator/flash_image"
    cp "$MYREPO/flash_image/flash_image.hex" "$CHIPYARD/sims/verilator/flash_image/"
    echo "  Copied flash_image.hex for Verilator elaboration."
else
    echo "  (No flash image converter/input found, skipping)"
fi

echo ""
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
echo "[2/5] Building BootROM..."
if [ -f "$MYREPO/software/bootrom/Makefile" ]; then
    cd "$MYREPO/software/bootrom"
    make
    if [ -f "bootrom.img" ]; then
        # BootROM staging paths. We MUST copy to BOTH the SBT source
        # resource dir AND the SBT incremental-compile output dir,
        # because if SBT thinks testchipip is up to date it won't re-copy
        # resources from src/main → target/classes/, and the assembly
        # step will then package the OLD bootrom from target/classes/.
        RES_DIR=$CHIPYARD/generators/testchipip/src/main/resources/testchipip/bootrom
        CLS_DIR=$CHIPYARD/generators/testchipip/src/target/scala-2.13/classes/testchipip/bootrom
        mkdir -p "$RES_DIR" "$CLS_DIR"
        cp bootrom.img "$RES_DIR/bootrom.secureboot.rv64.img"
        cp bootrom.img "$CLS_DIR/bootrom.secureboot.rv64.img"

        # Verify md5 matches at both staging paths — silent stale-copy
        # bugs are extremely painful to debug, so fail loudly here.
        SRC_MD5=$(md5sum bootrom.img        | awk '{print $1}')
        RES_MD5=$(md5sum "$RES_DIR/bootrom.secureboot.rv64.img" | awk '{print $1}')
        CLS_MD5=$(md5sum "$CLS_DIR/bootrom.secureboot.rv64.img" | awk '{print $1}')
        if [ "$SRC_MD5" != "$RES_MD5" ] || [ "$SRC_MD5" != "$CLS_MD5" ]; then
            echo "  Error: bootrom md5 mismatch after copy"
            echo "    source:    $SRC_MD5"
            echo "    resources: $RES_MD5"
            echo "    classes:   $CLS_MD5"
            exit 1
        fi

        # Invalidate downstream caches so the next `make CONFIG=…` actually
        # picks up the new bootrom:
        #   - chipyard.jar:    SBT's assembly output (packages bootrom from classes/)
        #   - generated-src/:  Verilator elaboration output (bakes bootrom into TLROM.sv)
        #   - sim binary:      Verilator-built C++ executable
        rm -f "$CHIPYARD/.classpath_cache/chipyard.jar"
        rm -rf "$CHIPYARD/sims/verilator/generated-src/chipyard.harness.TestHarness.SecureBootConfig"
        rm -rf "$CHIPYARD/sims/verilator/generated-src/chipyard.harness.TestHarness.TemperedSecureBootConfig"
        rm -f  "$CHIPYARD/sims/verilator/simulator-chipyard.harness-SecureBootConfig"
        rm -f  "$CHIPYARD/sims/verilator/simulator-chipyard.harness-TemperedSecureBootConfig"

        echo "  Built, staged, and downstream caches invalidated."
        echo "  Size:  $(stat -c%s bootrom.img) bytes"
        echo "  md5:   $SRC_MD5"
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
if ls $MYREPO/software/kernel/*.c 1> /dev/null 2>&1; then
    cp $MYREPO/software/kernel/*.c   $TESTS_DIR/ 2>/dev/null || true
    cp $MYREPO/software/kernel/*.h   $TESTS_DIR/ 2>/dev/null || true
    echo "  Copied kernel source(s)."
else
    echo "  (No kernel sources, skipping kernel/recovery build)"
    echo ""
    echo "Done (BootROM + Chisel only). Run:"
    echo "  cd $CHIPYARD/sims/verilator"
    echo "  make CONFIG=SecureBootConfig"
    exit 0
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

ELF_PATH="$TESTS_DIR/build/kernel.riscv"
BIN_PATH="$TESTS_DIR/build/kernel.bin"
KERNEL_REPO_DIR="$MYREPO/software/kernel"

if [ -f "$ELF_PATH" ]; then
    echo "  Extracting kernel.bin..."
    riscv64-unknown-elf-objcopy -O binary "$ELF_PATH" "$BIN_PATH"

    cp "$ELF_PATH" "$KERNEL_REPO_DIR/"
    cp "$BIN_PATH" "$KERNEL_REPO_DIR/"
    echo "  Success: kernel.riscv + kernel.bin copied to $KERNEL_REPO_DIR/"
else
    echo "  Error: kernel.riscv was not built successfully"
    exit 1
fi

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
echo "  BootROM staged at both src/main/resources/ and src/target/classes/"
echo "  chipyard.jar + generated-src + sim binaries invalidated"
echo "  → next \`make CONFIG=…\` will fully re-elaborate (~15-25 min)"
echo ""
echo "To run with default Chipyard config (no secure boot):"
echo "  cd $CHIPYARD/sims/verilator"
echo "  make CONFIG=RocketConfig"
echo "  ./simulator-chipyard.harness-RocketConfig $KERNEL_REPO_DIR/kernel.riscv"
echo ""
echo "To run with the secure-boot SoC (recovery passed via +payload=,"
echo "which is FESVR's mechanism to load extra ELFs alongside the primary"
echo "kernel — positional targs[1+] are silently ignored by FESVR):"
echo "  cd $CHIPYARD/sims/verilator"
echo "  make -j\$(nproc) CONFIG=SecureBootConfig"
echo "  ./simulator-chipyard.harness-SecureBootConfig \\"
echo "      +payload=$MYREPO/software/recovery/recovery.riscv \\"
echo "      $KERNEL_REPO_DIR/kernel.riscv"
echo ""
echo "For the tampered-manifest negative test (separate SoC binary):"
echo "  bash $MYREPO/tests/test_tempering_manifest_header/build.sh   # one-time, ~20 min"
echo "  bash $MYREPO/tests/test_tempering_manifest_header/run.sh"
echo ""
echo "For the kernel/pubkey negative tests (reuse SecureBootConfig sim):"
echo "  bash $MYREPO/tests/test_tempering_public_key/build.sh         # one-time, ~5 sec"
echo "  bash $MYREPO/tests/test_tempering_kernel/build.sh             # one-time, ~5 sec"
echo "  bash $MYREPO/tests/test_tempering_public_key/run.sh"
echo "  bash $MYREPO/tests/test_tempering_kernel/run.sh"
