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
    """Give the user stack 1KB instead of 256 bytes.

    As shipped, .ustack tops out at 0x200 with .istack at 0x100 directly
    below, so the user stack is 256 bytes. Upstream's README says to change it
    to 0x500 (and .data to 0x504) but the committed file never had it applied.

    The symptom is not obviously a stack problem: the board boots, draws, takes
    one touch correctly, returns garbage for the next and then hangs.
    lcd_string plus itoa with a char[10] is just deep enough to run off the end.

    Moving the stacks higher - 0x20000 and 0x18000, with room to spare - was
    tried on the theory that 1KB was still not enough for the port's own
    program, and it was a mistake twice over. The addresses are fine: they are
    real RAM, the linker places them, and start.S loads them. But the board
    then faulted before it reached the display, ending with ISP wrapped past
    zero in an exception storm; and the measurement that should have come
    first says the theory was wrong anyway, because at main the user stack had
    used a hundred bytes. Whatever stops that program after a touch, it is not
    running out of stack.
    """
    ld = demo / "generate" / "linker_script.ld"
    s = ld.read_text()
    if ".ustack 0x200" not in s:
        return
    s = s.replace(".ustack 0x200: AT(0x200)", ".ustack 0x500: AT(0x500)")
    s = s.replace(".data 0x204: AT(_mdata)", ".data 0x504: AT(_mdata)")
    ld.write_text(s)
    print("linker_script.ld: user stack 0x200 -> 0x500")


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
    if (demo / "src" / "touch_driver.c").exists():
        patch_touch_driver(demo, status_on_lcd)
        if bitbang:
            patch_bitbang(demo)


if __name__ == "__main__":
    main()
