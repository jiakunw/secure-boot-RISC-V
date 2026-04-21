#!/bin/bash
# Integrate secure-boot-RISC-V repo into Chipyard
# Run from the root of secure-boot-RISC-V

set -e

CHIPYARD=~/Development/chipyard
MYREPO=$(pwd)

# 1. Symlink Chisel source files into Chipyard
mkdir -p $CHIPYARD/generators/chipyard/src/main/scala/secureboot
ln -sf $MYREPO/hardware/secureboot/*.scala \
       $CHIPYARD/generators/chipyard/src/main/scala/secureboot/

# 2. Build the custom BootROM image
cd $MYREPO/software/bootrom
make    # produces bootrom.img

# 3. Copy the BootROM image into Chipyard's testchipip resource directory
cp $MYREPO/software/bootrom/bootrom.img \
   $CHIPYARD/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img

# 4. Build the demo kernel
cd $MYREPO/software/kernel
make    # produces kernel.riscv

echo "Integration done. Now run:"
echo "  cd $CHIPYARD/sims/verilator"
echo "  make CONFIG=SecureBootConfig"