# Recovery firmware: small ELF that BootROM mret's to when secure-boot
# verification fails. Built standalone (not via Chipyard's CMake) so we
# can use a custom linker script (recovery.ld) placing the image at
# 0x80100000 instead of the kernel's 0x80000000.

GCC      = riscv64-unknown-elf-gcc
OBJCOPY  = riscv64-unknown-elf-objcopy
OBJDUMP  = riscv64-unknown-elf-objdump

# Match chipyard's tests CMakeLists.txt toolchain config so we get the
# same riscv-pk htif_nano runtime (printf via HTIF tohost/fromhost).
# Note: -specs= must appear only ONCE in a single gcc invocation, otherwise
# the spec file is processed twice and we get "spec 'link' already defined".
SPECS      = -specs=htif_nano.specs
ARCH_FLAGS = -march=rv64imafd -mabi=lp64d -mcmodel=medany
CFLAGS     = -std=gnu99 -O2 -Wall -Wextra -fno-common -fno-builtin-printf

# CRITICAL: force recovery's tohost/fromhost symbols to land at the SAME
# addresses kernel.riscv places them at, so FESVR's single tohost-watcher
# sees recovery's writes too. Without this, recovery's printf/exit are
# invisible to the host and the sim hangs forever.
# kernel.riscv addresses come from: riscv64-unknown-elf-nm kernel.riscv | grep -E "tohost|fromhost"
# (extracted dynamically by build script; hard-coded here as defaults)
KERNEL_TOHOST   ?= 0x80001e00
KERNEL_FROMHOST ?= 0x80001e08

LDFLAGS = -static -T recovery.ld \
          -Wl,--defsym=tohost=$(KERNEL_TOHOST) \
          -Wl,--defsym=fromhost=$(KERNEL_FROMHOST)

SRC    = recovery.c
ELF    = recovery.riscv
BIN    = recovery.bin
DUMP   = recovery.dump

all: $(ELF) $(BIN) $(DUMP)

$(ELF): $(SRC) recovery.ld
	$(GCC) $(SPECS) $(ARCH_FLAGS) $(CFLAGS) $(LDFLAGS) $(SRC) -o $(ELF)

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $(ELF) $(BIN)

$(DUMP): $(ELF)
	$(OBJDUMP) -d $(ELF) > $(DUMP)

clean:
	rm -f $(ELF) $(BIN) $(DUMP)

.PHONY: all clean
