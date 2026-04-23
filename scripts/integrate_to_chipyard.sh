#!/bin/bash
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

if [ ! -f "$REPO_ROOT/.env" ]; then
    echo "Error: .env not found"
    exit 1
fi

source "$REPO_ROOT/.env"

if [ -f "$CHIPYARD_HOME/env.sh" ]; then
    source "$CHIPYARD_HOME/env.sh"
fi

CHIPYARD=$CHIPYARD_HOME
MYREPO=$REPO_ROOT
TESTS_DIR=$CHIPYARD/tests

echo "Using Chipyard at: $CHIPYARD"
echo "Repo root:         $MYREPO"

# ──────────────────────────────────────────────
# 1. Symlink Chisel sources
# ──────────────────────────────────────────────
echo ""
echo "[1/5] Linking Chisel sources..."
if ls $MYREPO/hardware/secureboot/*.scala 1> /dev/null 2>&1; then
    mkdir -p $CHIPYARD/generators/chipyard/src/main/scala/secureboot
    ln -sf $MYREPO/hardware/secureboot/*.scala \
           $CHIPYARD/generators/chipyard/src/main/scala/secureboot/
    echo "  Done."
else
    echo "  (No Chisel sources, skipping)"
fi

# ──────────────────────────────────────────────
# 2. Build BootROM
# ──────────────────────────────────────────────
echo ""
echo "[2/5] Building BootROM..."
cd $MYREPO/software/bootrom
make
cp bootrom.img \
   $CHIPYARD/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img
echo "  Done."

# ──────────────────────────────────────────────
# 3. Copy kernel sources
# ──────────────────────────────────────────────
echo ""
echo "[3/5] Copying kernel sources..."
cp $MYREPO/software/kernel/*.c   $TESTS_DIR/ 2>/dev/null || true
cp $MYREPO/software/kernel/*.h   $TESTS_DIR/ 2>/dev/null || true
echo "  Done."

# ──────────────────────────────────────────────
# 4. Patch CMakeLists.txt (only if not patched)
# ──────────────────────────────────────────────
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

# ──────────────────────────────────────────────
# 5. Build kernel via cmake
# ──────────────────────────────────────────────
echo ""
echo "[5/5] Building kernel..."

mkdir -p "$TESTS_DIR/build"
cmake -S "$TESTS_DIR" -B "$TESTS_DIR/build" -D CMAKE_BUILD_TYPE=Debug
cmake --build "$TESTS_DIR/build" --target kernel

# Define paths for clarity
ELF_PATH="$TESTS_DIR/build/kernel.riscv"
BIN_PATH="$TESTS_DIR/build/kernel.bin"
KERNEL_REPO_DIR="$MYREPO/software/kernel/"

if [ -f "$ELF_PATH" ]; then
    # Extract the raw binary
    echo "  Extracting kernel.bin from kernel.riscv..."
    riscv64-unknown-elf-objcopy -O binary "$ELF_PATH" "$BIN_PATH"
    
    # Copy both back to the repo
    cp "$ELF_PATH" "$KERNEL_REPO_DIR"
    cp "$BIN_PATH" "$KERNEL_REPO_DIR"
    echo "  Success: kernel.riscv and kernel.bin copied to $KERNEL_REPO_DIR"
else
    echo "  Error: kernel.riscv was not built successfully."
    exit 1
fi

echo "  kernel.riscv built and copied to repo."

echo ""
echo "Done. Run:"
echo "  cd $CHIPYARD/sims/verilator"
echo "  ./simulator-chipyard.harness-RocketConfig $MYREPO/software/kernel/kernel.riscv"