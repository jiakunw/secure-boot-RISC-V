#!/bin/bash
set -e

# ─────────────────────────────────────────────
# Locate repo + load .env
# ─────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

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
if ls $MYREPO/hardware/secureboot/*.scala 1> /dev/null 2>&1; then
    mkdir -p $CHIPYARD/generators/chipyard/src/main/scala/secureboot
    
    # Clean stale symlinks first (in case files were renamed/deleted)
    find $CHIPYARD/generators/chipyard/src/main/scala/secureboot \
         -maxdepth 1 -type l -delete 2>/dev/null || true
    
    ln -sf $MYREPO/hardware/secureboot/*.scala \
           $CHIPYARD/generators/chipyard/src/main/scala/secureboot/
    
    SCALA_COUNT=$(ls $MYREPO/hardware/secureboot/*.scala 2>/dev/null | wc -l)
    echo "  Linked $SCALA_COUNT Chisel file(s)."
else
    echo "  (No Chisel sources yet, skipping)"
fi

# ─────────────────────────────────────────────
# 2. Build BootROM
# ─────────────────────────────────────────────
echo ""
echo "[2/5] Building BootROM..."
if [ -f "$MYREPO/software/bootrom/Makefile" ]; then
    cd $MYREPO/software/bootrom
    make
    if [ -f "bootrom.img" ]; then
        cp bootrom.img \
           $CHIPYARD/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img
        echo "  Built and copied to Chipyard."
        echo "  Size: $(stat -c%s bootrom.img) bytes"
    else
        echo "  Error: bootrom.img not produced"
        exit 1
    fi
else
    echo "  (No BootROM Makefile, skipping)"
fi

# ─────────────────────────────────────────────
# 3. Copy kernel sources
# ─────────────────────────────────────────────
echo ""
echo "[3/5] Copying kernel sources to Chipyard tests..."
if ls $MYREPO/software/kernel/*.c 1> /dev/null 2>&1; then
    cp $MYREPO/software/kernel/*.c   $TESTS_DIR/ 2>/dev/null || true
    cp $MYREPO/software/kernel/*.h   $TESTS_DIR/ 2>/dev/null || true
    echo "  Done."
else
    echo "  (No kernel sources, skipping kernel build)"
    echo ""
    echo "Done (BootROM + Chisel only). Run:"
    echo "  cd $CHIPYARD/sims/verilator"
    echo "  make CONFIG=SecureBootConfig"
    exit 0
fi

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
    echo "  Already patched."
fi

# ─────────────────────────────────────────────
# 5. Build kernel via cmake
# ─────────────────────────────────────────────
echo ""
echo "[5/5] Building kernel..."

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
echo "To run with your secure boot config:"
echo "  cd $CHIPYARD/sims/verilator"
echo "  make CONFIG=SecureBootConfig"
echo "  ./simulator-chipyard.harness-SecureBootConfig $KERNEL_REPO_DIR/kernel.riscv"