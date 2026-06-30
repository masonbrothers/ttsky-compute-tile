## How it works

Compute Tile Smoke Island is a one-tile Tiny Tapeout bring-up design. It exposes a
public status byte, a reset-locked protected command path, two byte operand
registers, a byte result register, a trace checksum, cycle/op/error counters,
fault controls, and a built-in self-test.

The command byte is carried on `ui_in`. The high three bits select the opcode
and the low five bits carry an immediate or read selector. `uo_out` returns the
primary status/result byte. The bidirectional `uio` byte is host-to-design for
write-style commands and design-to-host only for read-style commands, with
`uio_oe=8'hff` when the design drives the lane.

The canonical pin-mode plan is `docs/pinout-plan.md`. It records the current
`ui_in`, `uo_out`, and `uio` byte-lane assignments plus the implemented UART
debug console, SPI RAM, SPI target, QSPI, I2C, and LED/debug variants.
The status/error/LED reference is `docs/status-led-reference.md`.

This byte-lane smoke protocol intentionally does not share the bidirectional
connector with external SPI RAM, QSPI flash/PSRAM, I2C, or UART Pmods. Those
interfaces use overlapping Tiny Tapeout pinout conventions. A later
memory-oriented revision should keep the standard `uio[0:3]` SPI RAM row:
`CS`, `MOSI`, `MISO`, and `SCK`, with the `MISO` pin released by the design. A
useful communication shape is a USB-to-RP2040-to-SPI mailbox: the demo-board
microcontroller handles USB, exposes an SPI RAM-style command/result window,
and the RTL only implements the SPI RAM-side protocol.

For immediate USB-visible debug, the RTL implements a UART console on
`ui_in[3]`/`uo_out[4]`. UART mode auto-enables when `ui_in[3]` is sampled high
on the first enabled clock after reset, matching an idle UART RX line. It can
also be enabled with the byte-lane `GATE` command using `imm=5'h0e` and
`uio_in=8'hc7`. In UART mode, `uo_out[4]` is UART TX instead of status/result
bit 4.

After reset, protected commands are rejected until the host sends the unlock
sequence. The compute path supports ADD, MUL-low, MAX, ReLU, a two-lane unsigned
nibble dot product, and XOR. This is not intended to be a product accelerator;
it is a silicon proof point for command gating, deterministic compute,
observability, and fault hooks.

## How to test

1. Reset the design and read `STATUS` (`ui_in[7:5]=000`).
2. Confirm `uio_out=8'h7f` for capability and the lock bit is clear.
3. Try a protected read while locked and confirm `8'he1`.
4. Unlock with `ui_in={3'b001,5'h1a}` and `uio_in=8'ha5`.
5. Load operands with `LOAD_A` and `LOAD_B`.
6. Run `COMPUTE` with the low three immediate bits selecting the operation.
7. Read the result with `READ_RESULT`.
8. Run `SELF_TEST` and confirm `8'hc3`.
9. Relock with `ui_in={3'b001,5'h05}` and `uio_in=8'h5a`.
10. Enable UART with `ui_in={3'b001,5'h0e}` and `uio_in=8'hc7`, then use
    `ui_in[3]`/`uo_out[4]` as RX/TX for console commands.

The cocotb test in `test/test.py` automates this sequence and also checks that
the bidirectional lane is only driven during read-style commands and that the
UART console can unlock, load operands, compute, read back, and run self-test.

## External hardware

No external hardware is required beyond the Tiny Tapeout board and its normal
clock/reset/control interface.
