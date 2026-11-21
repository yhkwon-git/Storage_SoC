# Firmware for the SoC tests.
#   make -C fw           build every test into build/fw/<test>.{elf,hex,lst}
#   make -C fw images    also copy the .hex files to fw/images/ (committed, so
#                        the simulation runs without the cross compiler)
# CROSS is the toolchain prefix (default riscv-none-elf-, xPack GCC 15.2.0).

CROSS   ?= riscv-none-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
BUILD   ?= ../build/fw

ARCH    := -march=rv32imc_zicsr_zifencei -mabi=ilp32
CFLAGS  := $(ARCH) -O2 -g -Wall -Wextra -ffreestanding -fno-builtin -nostdlib -Icommon
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -T common/link.ld

TESTS   := hello memtest irq buserr perf
COMMON  := common/crt0.S common/lib.c

.PHONY: all images clean

all: $(TESTS:%=$(BUILD)/%.hex)

$(BUILD)/%.elf: tests/%.c $(COMMON) common/lib.h common/soc.h common/link.ld
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -Wl,-Map=$(BUILD)/$*.map -o $@ $(COMMON) $< -lgcc

$(BUILD)/%.hex: $(BUILD)/%.elf bin2hex64.py
	$(OBJCOPY) -O binary -j .vectors -j .text -j .rodata -j .data $< $(BUILD)/$*.bin
	$(OBJDUMP) -d $< > $(BUILD)/$*.lst
	python3 bin2hex64.py $(BUILD)/$*.bin $@ 16384

images: all
	@mkdir -p images
	cp $(TESTS:%=$(BUILD)/%.hex) images/

clean:
	rm -rf $(BUILD)
