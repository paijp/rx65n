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


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    demo = pathlib.Path(args[0] if args else "EnvisionDemo1")
    status_on_lcd = "--status-on-lcd" in sys.argv[1:]

    patch_linker_script(demo)
    if (demo / "src" / "touch_driver.c").exists():
        patch_touch_driver(demo, status_on_lcd)


if __name__ == "__main__":
    main()
