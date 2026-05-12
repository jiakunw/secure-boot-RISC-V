# Build the bad_kernel payload for the test_tempering_kernel negative test.
#
# bad_kernel.c is a fake kernel that prints "bad kernel!" — the message an
# attacker would want their replacement firmware to display. BootROM
# Stage 3 (check_and_load_kernel) MUST reject this binary before it ever
# runs, because SHA-256(bad_kernel) ≠ manifest->payload_hash (which is
# SHA-256 of the genuine kernel.bin and was committed at signing time).
#
# Build pipeline matches the genuine kernel:
#   - rv64imafd, lp64d, medany
#   - htif_nano runtime (so write() / printf via HTIF tohost)
#   - htif.ld linker script (placed at 0x80000000, same as kernel)
#
# This binary is never expected to execute — BootROM rejects it. But we
# build it as a real ELF so the "if it had run" story is plausible: it
# would have printed "bad kernel!" had Stage 3 not caught it.

GCC      = riscv64-unknown-elf-gcc
OBJCOPY  = riscv64-unknown-elf-objcopy
OBJDUMP  = riscv64-unknown-elf-objdump

SPECS      = -specs=htif_nano.specs
ARCH_FLAGS = -march=rv64imafd -mabi=lp64d -mcmodel=medany
CFLAGS     = -std=gnu99 -O2 -Wall -Wextra -fno-common -fno-builtin-printf

LDFLAGS = -static -T htif.ld

SRC  = bad_kernel.c
ELF  = bad_kernel.riscv
BIN  = bad_kernel.bin
DUMP = bad_kernel.dump

all: $(BIN) $(DUMP)

$(ELF): $(SRC)
	$(GCC) $(SPECS) $(ARCH_FLAGS) $(CFLAGS) $(LDFLAGS) $(SRC) -o $(ELF)

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $(ELF) $(BIN)

$(DUMP): $(ELF)
	$(OBJDUMP) -d $(ELF) > $(DUMP)

clean:
	rm -f $(ELF) $(BIN) $(DUMP)

.PHONY: all clean
