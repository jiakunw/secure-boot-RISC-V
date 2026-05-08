# Minimal Makefile: build bootrom.img (RV64 only, same as Chipyard default)

GCC      = riscv64-unknown-elf-gcc
OBJCOPY  = riscv64-unknown-elf-objcopy
OBJDUMP  = riscv64-unknown-elf-objdump

CFLAGS_RV64 = -mabi=lp64 -march=rv64ima_zicsr_zifencei
# -ffunction-sections + -fdata-sections + --gc-sections strips unused MonoCypher
# code (BLAKE2b, ChaCha20, X25519) so we fit in the 64 KB BootROM.
# -Os optimizes for size — Ed25519 finite-field arithmetic shrinks notably.
CFLAGS_BOOT = -ffreestanding -fno-builtin -fno-stack-protector -Os -ffunction-sections -fdata-sections
LDFLAGS_BOOT = -Wl,--gc-sections
INCLUDES = -I../crypto/include

# build startup, bootrom C, sha256, and MonoCypher (Ed25519 verification)
SRCS = bootrom.S bootrom.c ../crypto/src/sha256.c ../crypto/src/monocypher.c

TARGET = bootrom.img

default: $(TARGET) bootrom.dump

bootrom.img: bootrom.elf
	$(OBJCOPY) -O binary --change-addresses=-0x10000 $< $@

bootrom.elf: $(SRCS) linker.ld
	$(GCC) $(CFLAGS_RV64) $(CFLAGS_BOOT) $(INCLUDES) -Tlinker.ld $(SRCS) -nostdlib -static $(LDFLAGS_BOOT) -o $@

bootrom.dump: bootrom.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f *.elf *.dump *.img

.PHONY: default clean