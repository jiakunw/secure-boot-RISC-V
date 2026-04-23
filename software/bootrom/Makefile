# Minimal Makefile: build bootrom.img (RV64 only, same as Chipyard default)

GCC      = riscv64-unknown-elf-gcc
OBJCOPY  = riscv64-unknown-elf-objcopy
OBJDUMP  = riscv64-unknown-elf-objdump

CFLAGS_RV64 = -mabi=lp64 -march=rv64ima_zicsr

TARGET = bootrom.img

default: $(TARGET) bootrom.dump

bootrom.img: bootrom.elf
	$(OBJCOPY) -O binary --change-addresses=-0x10000 $< $@

bootrom.elf: bootrom.S linker.ld
	$(GCC) $(CFLAGS_RV64) -Tlinker.ld $< -nostdlib -static -o $@

bootrom.dump: bootrom.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f *.elf *.dump *.img

.PHONY: default clean