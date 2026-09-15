# Build a MiniWin EnvisionDemo for the RX65N Envision Kit with GNU RX.
#
#   bash fetch-demo.sh          # toolchain + demo sources
#   make                        # -> EnvisionDemo1.mot
#   make DEMO=EnvisionDemo3     # a different demo
#
# Freestanding on purpose: the prebuilt GNU RX toolchains available without a
# Renesas login ship GCC and its multilibs but no newlib, so there is no libc
# to link against. These demos only reach for strlen and itoa, which shim/
# supplies — see shim/shim.c. Add to it if a demo needs more.

DEMO    ?= EnvisionDemo1
TC      ?= toolchain

CC      := $(TC)/bin/rx-elf-gcc
OBJCOPY := $(TC)/bin/rx-elf-objcopy
SIZE    := $(TC)/bin/rx-elf-size

# RX65N is an RXv2 core; -mcpu=rx64m selects the rxv2 multilib.
# Confirm with: rx-elf-gcc -mcpu=rx64m -print-multi-directory  -> rxv2
CPU     := rx64m

# The toolchain is relocatable, so ask it where its own headers landed
# rather than hardcoding a version-stamped path.
GCCINC  := $(shell $(CC) -print-file-name=include)

CFLAGS  := -mcpu=$(CPU) -O2 -std=gnu99 -ffreestanding -nostdlib \
           -ffunction-sections -fdata-sections \
           -I$(GCCINC) -Ishim/include -I$(DEMO)/generate -I$(DEMO)/src

LDFLAGS := -T $(DEMO)/generate/linker_script.ld -Wl,--gc-sections \
           -Wl,-Map=$(DEMO).map -lgcc

SRCS := $(wildcard $(DEMO)/src/*.c) \
        $(DEMO)/generate/hwinit.c \
        $(DEMO)/generate/inthandler.c \
        $(DEMO)/generate/vects.c \
        $(DEMO)/generate/start.S \
        shim/shim.c

all: $(DEMO).mot

$(DEMO).elf: $(SRCS)
	$(CC) $(CFLAGS) $^ $(LDFLAGS) -o $@
	$(SIZE) $@

$(DEMO).mot: $(DEMO).elf
	$(OBJCOPY) -O srec --srec-forceS3 $< $@
	@echo "built $@ ($$(wc -c < $@) bytes)"

clean:
	rm -f *.elf *.mot *.map

.PHONY: all clean
