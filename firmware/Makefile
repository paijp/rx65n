# Build firmware for the RX65N Envision Kit with GNU RX.
#
#   bash install-toolchain.sh gcc-14.2.0.202607-GNURX-ELF-linux.tar.gz
#
#   bash fetch-lcdtp.sh                # smallest-touchpanel-ui, the real sample
#   make DEMO=lcdtp                    # -> lcdtp.mot
#
#   bash fetch-demo.sh                 # a MiniWin EnvisionDemo instead
#   make                               # -> EnvisionDemo1.mot
#   make DEMO=EnvisionDemo3            # a different demo
#
# Either way the layout is the same — <dir>/src is the program and
# <dir>/generate is e2 studio's startup for this chip — so one rule builds
# both and nothing here knows which is which.
#
# Uses Renesas' own GNU RX, which bundles newlib — so this is an ordinary
# hosted-libc build. Only the startup files are replaced, because the demo
# brings its own (generate/start.S and generate/linker_script.ld).

DEMO    ?= EnvisionDemo1
TC      ?= toolchain

CC      := $(TC)/bin/rx-elf-gcc
OBJCOPY := $(TC)/bin/rx-elf-objcopy
SIZE    := $(TC)/bin/rx-elf-size

# RX65N is an RXv2 core; -mcpu=rx64m selects the rxv2 multilib.
# Confirm with: rx-elf-gcc -mcpu=rx64m -print-multi-directory  -> rxv2
CPU     := rx64m

# GCC 14 rejects incompatible pointer types outright rather than warning.
# tplib.h declares tplib_systemfont as `struct tplib_font_struct *`, an
# incomplete type that is never defined anywhere and is really the
# `struct lcdtp_font_struct *` that gdra_stp() takes — so every call passing
# it is an error now. Demoting it back to a warning is a build-side decision;
# the declaration itself is upstream's to fix, in one place, for all its
# ports at once. (The value is LCDTP_FONT12, which is NULL, so nothing here
# depends on the type being right.)
# -g costs nothing on the board. objcopy -O srec below emits only the
# loadable sections, so the .mot programmed is byte for byte what it was
# without it; the debug information stays in the .elf, which is the file the
# debugger reads anyway. What it buys is every stop naming a function and a
# line instead of an address, and a backtrace that is the call chain rather
# than gdb guessing at stack words. Chasing a wild jump without it means
# reading the map file by hand for every address, which is how several
# readings here went wrong.
#
# Deliberately not -O0: the bug being chased only appears in the build that
# has it, so the build must not change underneath the investigation.
CFLAGS  := -mcpu=$(CPU) -O2 -g -std=gnu99 -nostartfiles \
           -Wno-error=incompatible-pointer-types \
           -ffunction-sections -fdata-sections \
           -I$(DEMO)/generate -I$(DEMO)/src

LDFLAGS := -T $(DEMO)/generate/linker_script.ld -Wl,--gc-sections \
           -Wl,-Map=$(DEMO).map

SRCS := $(wildcard $(DEMO)/src/*.c) \
        $(DEMO)/generate/hwinit.c \
        $(DEMO)/generate/inthandler.c \
        $(DEMO)/generate/vects.c \
        $(DEMO)/generate/start.S

all: $(DEMO).mot

$(DEMO).elf: $(SRCS)
	$(CC) $(CFLAGS) $^ $(LDFLAGS) -o $@
	$(SIZE) $@

# The .ofs* sections are option-setting memory, and rfp-cli's -a does not
# erase it: a second flash of an image containing them fails with
# "E3000101: The data already exist and cannot be overwritten (0xFE7F5D40)".
# Their content is all-FF anyway — the same as an unprogrammed part — so
# dropping them costs nothing and makes the image reflashable.
OFS := -R .ofs1 -R .ofs2 -R .ofs3 -R .ofs4 -R .ofs5 -R .ofs6 -R .ofs7

$(DEMO).mot: $(DEMO).elf
	$(OBJCOPY) -O srec --srec-forceS3 $(OFS) $< $@
	@echo "built $@ ($$(wc -c < $@) bytes)"

clean:
	rm -f *.elf *.mot *.map

.PHONY: all clean
