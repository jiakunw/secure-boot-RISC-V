GCC      = riscv64-unknown-elf-gcc
OBJCOPY  = riscv64-unknown-elf-objcopy
OBJDUMP  = riscv64-unknown-elf-objdump

CFLAGS_RV64 = -mabi=lp64 -march=rv64ima_zicsr_zifencei
COMMON_CFLAGS = -ffreestanding -fno-builtin -fno-stack-protector -ffunction-sections -fdata-sections
INCLUDES = -I../crypto/include
LDFLAGS_BOOT = -Wl,--gc-sections

CFLAGS_BOOT = $(CFLAGS_RV64) $(COMMON_CFLAGS) -O2 $(INCLUDES)

TARGET = bootrom.img
OBJS = bootrom_start.o bootrom_main.o sha256.o

default: $(TARGET) bootrom.dump

bootrom.img: bootrom.elf
	$(OBJCOPY) -O binary --change-addresses=-0x10000 $< $@

bootrom.elf: $(OBJS) linker.ld
	$(GCC) $(CFLAGS_RV64) -Tlinker.ld $(OBJS) -nostdlib -static $(LDFLAGS_BOOT) -o $@

bootrom_start.o: bootrom.S
	$(GCC) $(CFLAGS_BOOT) -x assembler-with-cpp -c $< -o $@

bootrom_main.o: bootrom.c
	$(GCC) $(CFLAGS_BOOT) -c $< -o $@

sha256.o: ../crypto/src/sha256.c
	$(GCC) $(CFLAGS_BOOT) -c $< -o $@

bootrom.dump: bootrom.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f *.elf *.dump *.img *.o

.PHONY: default clean
