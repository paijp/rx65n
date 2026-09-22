#!/usr/bin/env python3
"""Apply the fixes an EnvisionDemo needs before it will actually run.

Upstream's demos are written for e2 studio and are not wrong so much as
unfinished: the linker script ships the default stack the project's own README
tells you to enlarge, and the touch driver's I2C layer desyncs after its first
transaction. Both were found by running the thing on hardware.

Everything here is applied to the fetched sources, not vendored, so upstream
stays the source of truth and each change is visible in one place.

  python3 patch-demo.py EnvisionDemo1 [--status-on-lcd]
"""
import pathlib
import re
import sys


def patch_linker_script(demo):
    """Stop the interrupt stack from growing down into .bss.

    As shipped, the RAM sections are laid out like this:

        .ustack 0x500:   explicit address
        .istack 0x100:   explicit address - the top; the stack grows DOWN
        .data   0x504:   explicit address
        .gcc_exc :       no address
        .bss    :        no address

    An output section with no address and `> RAM` is placed at the region's
    next free address, and the explicitly-addressed sections above do not
    move that pointer. So .bss lands at the region's origin, which is 0:

        00000000 B _bss
        00000000 b _line.0
        0000004c B _lcdtp_polltask
        000000b0 B _ebss
        00000100 ? _istack

    Two things are wrong with that, one of them demonstrated.

    Demonstrated: an object at address 0 has a null address. diag6 draws
    four strings out of a buffer that landed at 0x0 and none of them appear,
    because gdra_stp opens with `if (s == NULL) return;`. The same program's
    other buffer sits at 0x20 and draws fine. Nothing is corrupted; the
    pointer is simply equal to NULL, and every null check in the codebase
    rejects it. That is the whole of what was measured, and it is a good
    reason on its own not to leave .bss at the origin: C has no way to tell
    an object there from no object at all.

    Not demonstrated, but worth removing anyway: .bss ends at 0xb0 and the
    interrupt stack starts at 0x100 growing down, so there are eighty bytes
    between them. That is thin. It has NOT been shown to be the cause of
    anything - the display fault above is fully explained without it, and a
    theory that touching the screen corrupts .bss through nested interrupts
    would need its own evidence before it gets to explain the freeze.

    Upstream's README says to raise .ustack from 0x200 to 0x500, and that was
    applied here first, on the strength of the symptom looking like a stack
    overflow. It is not the fix; it moves .data and leaves .bss at zero. The
    stacks were then moved to 0x20000/0x18000 on the theory that 1KB was
    still too little, which broke the board outright and was wrong anyway -
    the user stack had used a hundred bytes at main.

    The fix is to place .bss where it belongs: both trailing sections get an
    explicit address derived from the end of the one before, so the region
    pointer stops being consulted at all. The stacks stay where upstream put
    them, low in RAM below .data, which is the right place for them - the
    low addresses are where an object must not go, and a stack that runs off
    its end there lands on address 0 rather than quietly on somebody's
    variable.
    """
    ld = demo / "generate" / "linker_script.ld"
    s = ld.read_text()

    if ".ustack 0x200" in s:
        s = s.replace(".ustack 0x200: AT(0x200)", ".ustack 0x500: AT(0x500)")
        s = s.replace(".data 0x204: AT(_mdata)", ".data 0x504: AT(_mdata)")
        print("linker_script.ld: user stack 0x200 -> 0x500")

    if "ADDR(.data) + SIZEOF(.data)" not in s:
        s = s.replace(
            "\t.gcc_exc :\n",
            "\t.gcc_exc ADDR(.data) + SIZEOF(.data) :\n",
            1,
        )
        s = s.replace(
            "\t.bss :\n",
            "\t.bss ADDR(.gcc_exc) + SIZEOF(.gcc_exc) :\n",
            1,
        )
        print("linker_script.ld: .bss placed after .data, off address 0")

    ld.write_text(s)


FAULT_CODES = {
    "INT_Excep_SuperVisorInst": 1,
    "INT_Excep_AccessInst": 2,
    "INT_Excep_UndefinedInst": 3,
    "INT_Excep_FloatingPoint": 4,
    "INT_NonMaskableInterrupt": 5,
    "INT_Excep_BRK": 6,
    "INT_Excep_BSC_BUSERR": 7,
    "INT_Excep_RAM_RAMERR": 8,
    "INT_Excep_FCU_FIFERR": 9,
    "Dummy": 10,
}


def patch_fault_handlers(demo):
    """Make a fault say what it was instead of erasing the evidence.

    As shipped, every handler is an empty function:

        void INT_Excep_AccessInst(void){}

    It was asserted here, several times and at length, that these return
    with RTS where an exception needs RTE, and that this was what walked ISP
    down to zero. That is wrong. interrupt_handlers.h declares all 227 of
    them `__attribute__((interrupt))` and the disassembly shows the
    interrupt prologue and RTE. They return correctly. Empty is the only
    thing wrong with them.

    What empty costs is not a crash, it is silence. Every hang from every
    cause arrives looking the same - SIGTRAP at PC 0 with ISP 0 - with the
    faulting PC overwritten and the fault type gone. Three investigations
    here ended at that picture with nothing further to read.

    So: record which vector fired, and stop. Stopping rather than returning
    is the point - ISP stays where the fault left it, the stacked PC and PSW
    are still under it, and the debugger can read both. The display keeps
    working too, because GLCDC scans the framebuffer without the CPU, so
    whatever was on screen when it died stays there.

    The reserved entries matter as much as the handlers. RelocatableVectors
    ships 54 slots as (fp)0, so an interrupt nothing claims does not reach a
    handler at all: the processor stacks PSW and PC and jumps to address 0.
    Address 0 is RAM, RAM reads as zero, and 0x00 is BRK - whose vector is
    also one of the zeros. It goes round again, eight bytes of interrupt
    stack at a time, until ISP reaches zero. That is a hypothesis fitted to
    fault_code staying 0 while ISP and PC both end at 0, not something
    demonstrated; filling the slots with Dummy is what turns it into a
    question the board can answer, because then the same event leaves
    fault_code 10 and an intact stack.

    Reading it afterwards, with the target halted:

        -data-read-memory-bytes &fault_code 4
        -data-list-register-values x 17        (ISP)
        -data-read-memory-bytes <ISP> 16       (stacked PC, then PSW)

    Only the first fault is recorded; a second one cannot overwrite the first,
    because the first is the one that explains the rest.

    Dummy gets a code too. It is the catch-all for every vector nothing else
    claims, so an interrupt that was enabled without a handler lands there -
    and that is exactly the kind of thing that would look like "the board
    stops when I touch it".
    """
    ih = demo / "generate" / "inthandler.c"
    t = ih.read_text()
    if "rx65n_fault_code" in t:
        return

    preamble = (
        "/* patch-demo.py: an exception records itself and stops, rather than\n"
        "   returning with RTS and faulting forever. See patch-demo.py. */\n"
        "volatile unsigned long rx65n_fault_code = 0UL;\n\n"
        "static void rx65n_fault(unsigned long code)\n"
        "{\n"
        "\tif (rx65n_fault_code == 0UL)\n"
        "\t\trx65n_fault_code = code;\n"
        "\t/* Spin. Returning is what does the damage. */\n"
        "\tfor (;;)\n"
        "\t{\n"
        "\t}\n"
        "}\n\n"
    )

    n = 0
    for name, code in FAULT_CODES.items():
        for old in (
            "void %s(void){/* brk(){  } */}" % name,
            "void %s(void){/* brk(); */}" % name,
            "void %s(void){/* wait(); */}" % name,
            "void %s(void){ }" % name,
            "void %s(void) { }" % name,
        ):
            if old in t:
                t = t.replace(old, "void %s(void){ rx65n_fault(%dUL); }" % (name, code), 1)
                n += 1
                break

    # After the includes, so the helper is defined before anything uses it.
    marker = "void %s(void)" % next(iter(FAULT_CODES))
    t = t.replace(marker, preamble + marker, 1)
    ih.write_text(t)
    print("inthandler.c: %d fault handlers now record and stop" % n)

    # A vector that is 0 sends the processor to address 0 instead of to a
    # handler, which is the one way a fault can happen and leave nothing at
    # all behind. Dummy records code 10 and stops, so it leaves everything.
    vc = demo / "generate" / "vects.c"
    v = vc.read_text()
    z = v.count("(fp)0,")
    if z:
        v = v.replace("(fp)0,", "Dummy,")
        vc.write_text(v)
        print("vects.c: %d reserved vectors now point at Dummy" % z)


def patch_touch_driver(demo, status_on_lcd):
    """Fix the I2C desync, and stop a desync from being able to hang the board.

    The driver waits on flags an ISR sets: `while (!rx_complete_interrupt_flag)`
    and friends. Nothing clears them between transactions, and the NACK on a
    read's final byte can leave rx set. The next read then sails straight
    through its first wait, takes a stale byte, and every wait after that is
    off by one until one of them never completes.

    On hardware this looked like: first touch fine, second touch nothing, board
    frozen. Clearing the three flags at the top of each transaction fixes it.

    The bounded waits are kept regardless. They cost nothing, they turn any
    remaining desync into a recorded code instead of a dead board, and one of
    them is inside an ISR where an unbounded spin freezes everything.
    """
    td = demo / "src" / "touch_driver.c"
    s = td.read_text()

    s = s.replace(
        "extern volatile bool rx_complete_interrupt_flag;",
        "volatile uint32_t touch_wait_status = 0U;\n"
        "extern volatile bool rx_complete_interrupt_flag;",
        1,
    )

    # One code per wait site (10, 20, ...); +1 means that site gave up.
    counter = [0]

    def bound(m):
        counter[0] += 10
        code = counter[0]
        return (
            "{ uint32_t _to = 0U; touch_wait_status = %dU;\n"
            "\t\twhile (!%s) { if (++_to > 400000UL) "
            "{ touch_wait_status = %dU; break; } } }" % (code, m.group(1), code + 1)
        )

    s, n = re.subn(r"while \(!(\w+_complete_interrupt_flag)\)\s*\{\s*\}", bound, s)
    print("touch_driver.c: bounded %d wait loops" % n)

    s = s.replace(
        "\t/* disable read interrupt generation */",
        "\t/* clear flags left over from the previous transaction */\n"
        "\trx_complete_interrupt_flag = false;\n"
        "\ttx_complete_interrupt_flag = false;\n"
        "\tstart_complete_interrupt_flag = false;\n\n"
        "\t/* disable read interrupt generation */",
    )
    print("touch_driver.c: clear stale interrupt flags per transaction")

    # This branch returns true without ever assigning *x/*y, so the caller
    # draws at whatever happened to be on the stack.
    s = s.replace(
        "\t\tfirst_touch_received = true;\n\t\treturn true;",
        "\t\tfirst_touch_received = true;\n\t\treturn false;",
    )
    td.write_text(s)

    ih = demo / "generate" / "inthandler.c"
    t = ih.read_text()
    t = t.replace(
        "\tSCI6.SIMR3.BIT.IICSTIF = 0U;\n    \twhile (SCI6.SIMR3.BIT.IICSTIF != 0U)\n    \t{\n    \t}",
        "\tSCI6.SIMR3.BIT.IICSTIF = 0U;\n    \t{ uint32_t _to = 0U;\n"
        "    \twhile (SCI6.SIMR3.BIT.IICSTIF != 0U) { if (++_to > 100000UL) break; } }",
    )
    ih.write_text(t)

    if status_on_lcd:
        patch_status_display(demo)


def patch_status_display(demo):
    """Print the driver's last wait code bottom-left, when it changes.

    Crude, but it is the whole debug channel this board has out of the box, and
    it is what turned "it hangs somewhere" into "it is stuck at site 50".
    """
    mn = demo / "src" / (demo.name + ".c")
    m = mn.read_text()
    m = m.replace(
        "int main(void)", "extern volatile uint32_t touch_wait_status;\n\nint main(void)", 1
    )
    m = m.replace("\tbool touched;", "\tbool touched;\n\tuint32_t last_status = 0xFFFFFFFFU;", 1)
    m = m.replace(
        "\t\ttouched = touch_get_point(&x, &y);",
        "\t\tif (touch_wait_status != last_status)\n\t\t{\n"
        "\t\t\tlast_status = touch_wait_status;\n"
        "\t\t\tlcd_filled_rectangle(0, 248, 120, 24, BLACK);\n"
        "\t\t\titoa((int)last_status, text, 10);\n"
        "\t\t\tlcd_string(4, 252, text, WHITE);\n\t\t}\n\n"
        "\t\ttouched = touch_get_point(&x, &y);",
        1,
    )
    mn.write_text(m)
    print("%s.c: show touch_wait_status on the LCD" % demo.name)


def patch_bitbang(demo):
    """Give the demo the port's bit-banged I2C in place of SCI6's simple-IIC.

    This is an experiment, not an improvement. The port's own program stops a
    few touches in and it has not been possible to say whether that is the
    bit-banging or everything around it, because the port changed both at
    once. The demo is the other way round: it is a program known to run on
    this board, so swapping one thing in it - the way the touch controller is
    reached, and nothing else - answers the question by itself.

    If the demo runs like this, the bit-banging is sound and the fault is in
    the port. If the demo stops the same way, it is the bit-banging, and
    everything found so far in the port points at it.

    "Known to run" means known to run with the two fixes above applied: as
    shipped it hangs after the first touch. That is the baseline being
    compared against, not the untouched demo.

    The swap is one function's worth. touch_init() keeps its reset pulse and
    its SCI6 setup - SCI6 is simply left configured and unused - but the two
    pins are taken back from it and handed to i2c.h, and touch_get_point()'s
    two transactions become one bit-banged read.
    """
    td = demo / "src" / "touch_driver.c"
    s = td.read_text()
    if not (demo / "src" / "i2c.h").exists():
        print("touch_driver.c: no i2c.h fetched, skipping bit-bang swap")
        return

    s = s.replace(
        '#include "iodefine.h"',
        '#include "iodefine.h"\n'
        '#include "i2c.h"\n\n'
        "/* i2c.h calls this between bit times; the demo has no such task */\n"
        "void (*lcdtp_polltask)() = NULL;\n",
        1,
    )

    # The transaction, in the demo's own terms.
    s = s.replace(
        "bool touch_get_point(uint16_t* x, uint16_t* y)",
        "static bool bitbang_read(uint8_t addr, uint8_t reg, uint8_t *buf,\n"
        "\t\t\t uint16_t len)\n"
        "{\n"
        "\tuint16_t i;\n\n"
        "\ti2cstart();\n"
        "\tif (i2csend(addr << 1)) { i2cstop(); return false; }\n"
        "\tif (i2csend(reg))       { i2cstop(); return false; }\n\n"
        "\ti2cstart();\n"
        "\tif (i2csend((addr << 1) | 1)) { i2cstop(); return false; }\n\n"
        "\tfor (i = 0U; i < len; i++)\n"
        "\t\tbuf[i] = (uint8_t)i2crecv((i == len - 1U)? 1 : 0);\n\n"
        "\ti2cstop();\n"
        "\treturn true;\n"
        "}\n\n"
        "bool touch_get_point(uint16_t* x, uint16_t* y)",
        1,
    )

    s = s.replace(
        "\t/* write register address to touch controller */\n"
        "\twrite_device_data(TOUCH_CONTROLLER_I2C_ADDRESS, &device_register, "
        "sizeof(device_register));\n\n"
        "\t/* read data from touch controller starting at register address "
        "just written */\n"
        "\tread_device_data(TOUCH_CONTROLLER_I2C_ADDRESS, i2c_buffer, "
        "sizeof(i2c_buffer));",
        "\t/* the same transaction, bit-banged instead of through SCI6 */\n"
        "\tif (!bitbang_read(TOUCH_CONTROLLER_I2C_ADDRESS, device_register,\n"
        "\t\t\t  i2c_buffer, sizeof(i2c_buffer)))\n"
        "\t{\n"
        "\t\treturn false;\n"
        "\t}",
        1,
    )

    # touch_init() routes P00/P01 to SCI6; take them back and settle which is
    # which by asking the panel, as the port does.
    s = s.replace(
        "\t/* set up transmit interrupt */\n"
        "\tIR(SCI6, TXI6) = 0U;\n"
        "\tIPR(SCI6, TXI6) = 5U;\n"
        "\tIEN(SCI6, TXI6) = 1U;\n"
        "}",
        "\t/* set up transmit interrupt */\n"
        "\tIR(SCI6, TXI6) = 0U;\n"
        "\tIPR(SCI6, TXI6) = 5U;\n"
        "\tIEN(SCI6, TXI6) = 1U;\n\n"
        "\t/* take P00/P01 back from SCI6 and hand them to i2c.h */\n"
        "\tMPC.PWPR.BIT.B0WI = 0U;\n"
        "\tMPC.PWPR.BIT.PFSWE = 1U;\n"
        "\tMPC.P00PFS.BYTE = 0x00U;\n"
        "\tMPC.P01PFS.BYTE = 0x00U;\n"
        "\tMPC.PWPR.BIT.PFSWE = 0U;\n"
        "\tMPC.PWPR.BIT.B0WI = 1U;\n\n"
        "\t(void)i2cprobe(TOUCH_CONTROLLER_I2C_ADDRESS);\n"
        "}",
        1,
    )

    td.write_text(s)
    print("touch_driver.c: SCI6 simple-IIC -> bit-banged i2c.h")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    demo = pathlib.Path(args[0] if args else "EnvisionDemo1")
    status_on_lcd = "--status-on-lcd" in sys.argv[1:]
    bitbang = "--bitbang" in sys.argv[1:]

    patch_linker_script(demo)
    patch_fault_handlers(demo)
    if (demo / "src" / "touch_driver.c").exists():
        patch_touch_driver(demo, status_on_lcd)
        if bitbang:
            patch_bitbang(demo)


if __name__ == "__main__":
    main()
