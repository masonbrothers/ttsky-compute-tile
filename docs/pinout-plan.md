# Tiny Tapeout Pinout Plan

Date: 2026-06-30

## Audience, Purpose, Owner, Freshness

- Audience: RTL implementers, Tiny Tapeout submitters, firmware authors, and
  bring-up operators.
- Purpose: define how the Compute Tile uses Tiny Tapeout `ui_in`, `uo_out`, and `uio`
  pins across the current smoke design and future UART/SPI/I2C/RAM variants.
- Owner: accelerator/Compute Tile architecture.
- Freshness trigger: update this document when `info.yaml`, `project.v`, the
  command protocol, UART/SPI/I2C transport RTL, RP2040 firmware assumptions, or
  Tiny Tapeout pinout recommendations change.

## Board-Level Constraints

Tiny Tapeout exposes 24 user pins:

- 8 input-only pins: `ui_in[7:0]`.
- 8 output-only pins: `uo_out[7:0]`.
- 8 bidirectional tri-state pins: `uio[7:0]`, with direction controlled by
  `uio_oe[7:0]`.

The demo board also has an RP2040. USB should terminate at the RP2040, not in
the user RTL. The useful RTL choices are therefore UART pins, SPI pins, or a
memory-style SPI mailbox that RP2040 firmware exposes to host software over USB.

Sources:

- Tiny Tapeout pinouts: https://www.tinytapeout.com/specs/pinouts/
- Tiny Tapeout HDL contract: https://tinytapeout.com/hdl/important/

## Mode Strategy

Use one transport mode per build. Do not claim that the same bitstream can safely
drive byte-lane readback, SPI RAM, QSPI, I2C, and UART on the same pins at the
same time.

| Mode | Primary value | Pin cost | Status |
| --- | --- | --- | --- |
| V0 byte-lane smoke | Fastest deterministic bring-up and cocotb testing | all `ui_in`, all `uo_out`, all `uio` as byte lanes | implemented |
| UART console | USB-visible byte/debug console through RP2040 | `ui_in[3]`, `uo_out[4]` | planned, deferred for area |
| SPI RAM mailbox | USB-to-RP2040-to-SPI command/result memory window | `uio[0:3]` | planned, preferred next transport |
| SPI target | RP2040 or external host directly clocks commands into RTL | `uio[0:3]` | optional alternate, conflicts with SPI RAM role |
| QSPI flash/PSRAM | larger external memory experiment | all `uio[7:0]` | later |
| I2C management | slow, simple management bus | one `uio` row | later, lower priority |

## Current V0 Byte-Lane Smoke Pinout

The current checked RTL is a direct byte-lane smoke protocol. It should be used
with no external SPI RAM, QSPI, I2C, or UART Pmod connected to the bidirectional
connector.

### `ui_in` Input Pins

| Pin | V0 signal | Meaning |
| --- | --- | --- |
| `ui_in[0]` | `cmd_imm[0]` | immediate/select bit 0 |
| `ui_in[1]` | `cmd_imm[1]` | immediate/select bit 1 |
| `ui_in[2]` | `cmd_imm[2]` | immediate/select bit 2 |
| `ui_in[3]` | `cmd_imm[3]` | immediate/select bit 3; reserve for UART RX in UART variant |
| `ui_in[4]` | `cmd_imm[4]` | immediate/select bit 4 |
| `ui_in[5]` | `cmd_opcode[0]` | opcode bit 0 |
| `ui_in[6]` | `cmd_opcode[1]` | opcode bit 1 |
| `ui_in[7]` | `cmd_opcode[2]` | opcode bit 2; alternate UART RX reserved for a future variant |

### `uo_out` Output Pins

`uo_out` is both the primary result/status byte and the board-visible LED/debug
surface. In V0, use it as the result byte first and interpret the same bits as
LEDs during manual bring-up.

| Pin | V0 signal | LED/debug interpretation |
| --- | --- | --- |
| `uo_out[0]` | `status_or_result[0]` | alive/status-valid or result bit 0; alternate UART TX in UART variant |
| `uo_out[1]` | `status_or_result[1]` | unlocked or result bit 1 |
| `uo_out[2]` | `status_or_result[2]` | result-valid or result bit 2 |
| `uo_out[3]` | `status_or_result[3]` | error-sticky or result bit 3 |
| `uo_out[4]` | `status_or_result[4]` | self-test pass or result bit 4; preferred UART TX in UART variant |
| `uo_out[5]` | `status_or_result[5]` | compute-disabled/fault mode or result bit 5 |
| `uo_out[6]` | `status_or_result[6]` | enable/activity or result bit 6 |
| `uo_out[7]` | `status_or_result[7]` | trace parity/heartbeat or result bit 7 |

### `uio` Bidirectional Pins

In V0, `uio[7:0]` is a shared byte lane. The core drives `uio_out[7:0]` only for
read-style commands and sets `uio_oe=8'hff`; it releases the lane with
`uio_oe=8'h00` for write-style commands.

| Pin | V0 byte lane | Reserved common role |
| --- | --- | --- |
| `uio[0]` | `data_lane[0]` | SPI RAM `CS` |
| `uio[1]` | `data_lane[1]` | SPI RAM `MOSI` |
| `uio[2]` | `data_lane[2]` | SPI RAM `MISO` |
| `uio[3]` | `data_lane[3]` | SPI RAM `SCK` |
| `uio[4]` | `data_lane[4]` | QSPI `SD2` or lower-row protocol pin |
| `uio[5]` | `data_lane[5]` | QSPI `SD3` or lower-row protocol pin |
| `uio[6]` | `data_lane[6]` | QSPI RAM A `CS` or lower-row protocol pin |
| `uio[7]` | `data_lane[7]` | QSPI RAM B `CS` or lower-row protocol pin |

## Planned UART Console Variant

Use UART for the smallest USB-visible control path. The RP2040 handles USB; the
RTL only exposes UART RX/TX.

Preferred mapping:

| Pin | Direction | Signal |
| --- | --- | --- |
| `ui_in[3]` | input to RTL | UART RX |
| `uo_out[4]` | output from RTL | UART TX |

The full UART RX/TX console is deferred from this smoke island because the first
implementation exceeded the one-tile hardening area budget. When UART is added,
reserve the chosen TX pin and keep only the remaining `uo_out` pins as
LED/status bits. Do not use the chosen RX bit as part of the V0 parallel command
byte.

## Planned SPI RAM Mailbox Variant

This is the preferred next transport for structured host communication and
small RAM-like command/result buffers.

The demo-board RP2040 handles USB and exposes an SPI RAM-style window. The
Compute Tile RTL is the SPI master that polls or updates command/status/result slots.

| Pin | Direction from RTL | Signal | `uio_oe` |
| --- | --- | --- | --- |
| `uio[0]` | output | SPI RAM `CS` | `1` |
| `uio[1]` | output | SPI RAM `MOSI` | `1` |
| `uio[2]` | input | SPI RAM `MISO` | `0` |
| `uio[3]` | output | SPI RAM `SCK` | `1` |

This conflicts with V0 byte-lane readback. A build that implements SPI RAM must
not drive `uio[2]`; keep `uio_oe[2]=0` so MISO remains an input. It also must
not assert `uio_oe=8'hff` for byte-lane reads.

## Optional SPI Target Variant

An SPI target/slave build could let the RP2040 or another host directly clock
commands into the RTL. It uses the same physical pins as SPI RAM but opposite
directions for most signals.

| Pin | Direction from RTL | Signal | `uio_oe` |
| --- | --- | --- | --- |
| `uio[0]` | input | SPI `CS` | `0` |
| `uio[1]` | input | SPI `MOSI` | `0` |
| `uio[2]` | output | SPI `MISO` | `1` only while selected |
| `uio[3]` | input | SPI `SCK` | `0` |

Do not combine the SPI target and SPI RAM roles in one simple build unless an
explicit direction mux, mode strap, and verification plan exist.

## Later QSPI Flash/PSRAM Variant

Use Tiny Tapeout's QSPI Pmod convention when a larger external memory proof is
worth the added RTL and board risk.

| Pin | Signal |
| --- | --- |
| `uio[0]` | `CS0` flash |
| `uio[1]` | `SD0` / MOSI |
| `uio[2]` | `SD1` / MISO |
| `uio[3]` | `SCK` |
| `uio[4]` | `SD2` |
| `uio[5]` | `SD3` |
| `uio[6]` | `CS1` RAM A |
| `uio[7]` | `CS2` RAM B |

This should follow, not precede, the simpler SPI RAM mailbox proof.

## Later I2C Management Variant

I2C is useful for slow management but is lower value than UART or SPI for first
bring-up. If implemented, use open-drain-style behavior: drive low or release;
do not drive push-pull high.

Top-row mapping:

| Pin | Direction from RTL | Signal |
| --- | --- | --- |
| `uio[0]` | input or output-low | optional `INT` |
| `uio[1]` | input or output-low | optional `RESET` |
| `uio[2]` | input or output-low | `SCL` |
| `uio[3]` | input or output-low | `SDA` |

Bottom-row mapping is `uio[4]`/`uio[5]`/`uio[6]`/`uio[7]` with the same roles.

## Decision Rules

1. Keep V0 byte-lane smoke as the deterministic no-Pmod proof.
2. Add UART only when the goal is USB-visible byte/debug console bring-up and
   the implementation still fits the one-tile hardening budget.
3. Add SPI RAM mailbox next when the goal is higher-value host command/result
   buffering or RP2040-backed memory.
4. Use `uo_out` LEDs for observability, but reserve `uo_out[4]` or `uo_out[0]`
   when a UART variant needs TX.
5. Never drive `uio_oe=8'hff` in builds that attach SPI RAM, QSPI, or I2C.
6. Update `info.yaml`, this plan, `README.md`, `docs/info.md`, cocotb tests, and
   any RP2040 firmware notes together when a pin mode changes.
