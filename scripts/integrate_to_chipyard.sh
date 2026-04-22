#!/bin/bash
set -e

# Locate this script and source .env from repo root
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

if [ ! -f "$REPO_ROOT/.env" ]; then
    echo "Error: .env file not found at $REPO_ROOT/.env"
    echo "Copy .env.example to .env and edit your paths:"
    echo "  cp .env.example .env"
    exit 1
fi

source "$REPO_ROOT/.env"

if [ -z "$CHIPYARD_HOME" ]; then
    echo "Error: CHIPYARD_HOME not set in .env"
    exit 1
fi

if [ ! -d "$CHIPYARD_HOME" ]; then
    echo "Error: Chipyard not found at $CHIPYARD_HOME"
    exit 1
fi

CHIPYARD=$CHIPYARD_HOME
MYREPO=$REPO_ROOT

echo "Using Chipyard at: $CHIPYARD"
echo "Repo root: $MYREPO"

# 1. Symlink Chisel source files into Chipyard
mkdir -p $CHIPYARD/generators/chipyard/src/main/scala/secureboot
ln -sf $MYREPO/hardware/secureboot/*.scala \
       $CHIPYARD/generators/chipyard/src/main/scala/secureboot/

# 2. Build BootROM
cd $MYREPO/software/bootrom
make

# 3. Copy BootROM image
cp $MYREPO/software/bootrom/bootrom.img \
   $CHIPYARD/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img

# 4. Build kernel
cd $MYREPO/software/kernel
make

echo ""
echo "Integration done. Now run:"
echo "  cd $CHIPYARD/sims/verilator"
echo "  make CONFIG=SecureBootConfig"