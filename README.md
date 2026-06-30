# Compute Tile Smoke Island for Tiny Tapeout

This is a Tiny Tapeout SKY Verilog project for the first useful Compute Tile silicon
experiment. It is intentionally a bring-up chiplet, not a small LLM accelerator:
the value is in proving power/reset/clock, the public status path, a locked
protected aperture, one byte-sized compute primitive, counters, trace, and fault
hooks on real silicon.

The top module is `tt_um_masonbrothers_compute_tile_top`, following Tiny
Tapeout's `tt_um_*` naming convention and exact 8-input, 8-output,
8-bidirectional port shape.

Latest hardened GDS viewer: https://compute-tile.masonbrothers.ca/

## Template Lineage

This repository is intentionally based on the upstream Tiny Tapeout SKY Verilog
template, not a flattened copy inside the parent AI ASIC repository. Keep the
remotes in this shape:

```sh
origin   https://github.com/masonbrothers/ttsky-compute-tile.git
upstream https://github.com/TinyTapeout/ttsky-verilog-template.git
```

To pick up Tiny Tapeout template updates:

```sh
git fetch upstream
git rebase upstream/main
```

After resolving template changes, run the shared RTL sync from the parent repo
so `src/compute_tile_tiny_tapeout_core.v` matches
`rtl/compute_tile_tiny_tapeout_core.v`.

## Tiny Tapeout HDL Checklist

This project follows Tiny Tapeout's HDL "Important!" checklist:

- the top module is uniquely named `tt_um_masonbrothers_compute_tile_top`;
- `project.v` keeps the exact Tiny Tapeout port contract;
- `src/config.json` keeps the template linter, clock, CTS, and output-buffer
  safety settings unless a hardening issue explicitly requires a reviewed
  change;
- reset drives all internal control, counter, trace, result, and status
  registers to deterministic safe values before any command is accepted;
- the cocotb protocol test exercises every externally visible output bit high
  and low, including `uio_oe`, so synthesis should not optimize the smoke
  datapath into a narrow unobservable fragment;
- the parent CI runs a Yosys synthesis smoke with
  `RTL_TOP=tt_um_masonbrothers_compute_tile_top` so synthesis warnings are
  checked for the Tiny Tapeout wrapper.

## Reset / Unknown-State Contract

The design must not rely on simulator or silicon power-up values. Hosts and
tests assert `rst_n=0` before use, then release reset before the first command.
While disabled or held in reset, `uo_out`, `uio_out`, and `uio_oe` are expected
to be zero; after reset, public status must be readable while protected
commands remain locked.

All internal `*_q` state in `compute_tile_tiny_tapeout_core.v` is reset
explicitly. Any intentional post-reset strap sampling, such as a UART idle-level
strap or a future SPI-mode strap, must be documented with the pin contract and
covered by the cocotb protocol test.

## Pin Contract

- `ui_in[7:5]`: opcode.
- `ui_in[4:0]`: immediate/select field.
- `uo_out[7:0]`: status byte or primary result byte.
- `uio_in[7:0]`: host-written data byte for unlock, operands, and fault control.
- `uio_out[7:0]`: auxiliary read byte for status, trace, counters, or result.
- `uio_oe[7:0]`: `8'hff` only for read-style commands; otherwise high-Z.

## Pinout Compatibility

Tiny Tapeout recommends common pinouts so demo boards, Pmods, and scripts can be
reused across projects. This first smoke build uses `uio[7:0]` as a controlled
parallel byte lane, so it should be tested with no external SPI RAM, QSPI, I2C,
or UART Pmod attached to the bidirectional connector.

The canonical pin-mode plan is [docs/pinout-plan.md](docs/pinout-plan.md). It
covers the current byte-lane smoke mode plus the planned UART console,
RP2040-backed SPI RAM mailbox, SPI target, QSPI, I2C, and LED/debug mappings.
The status/error/LED reference is
[docs/status-led-reference.md](docs/status-led-reference.md).

The metadata still reserves the standard RAM-oriented mapping:

| Pins | Common Tiny Tapeout use | Current smoke use |
| --- | --- | --- |
| `uio[0]` | SPI RAM `CS` | byte lane bit 0 |
| `uio[1]` | SPI RAM `MOSI` | byte lane bit 1 |
| `uio[2]` | SPI RAM `MISO` | byte lane bit 2 |
| `uio[3]` | SPI RAM `SCK` | byte lane bit 3 |
| `uio[4]` | QSPI `SD2` | byte lane bit 4 |
| `uio[5]` | QSPI `SD3` | byte lane bit 5 |
| `uio[6]` | QSPI RAM A `CS` | byte lane bit 6 |
| `uio[7]` | QSPI RAM B `CS` | byte lane bit 7 |

The next RAM-oriented variant should replace byte-lane readback with an SPI RAM
master on `uio[0:3]`: drive `CS`, `MOSI`, and `SCK`; sample `MISO`; and keep
`uio_oe[2]=0`. That gives the demo-board RP2040 a USB-to-SPI path into the
design without putting USB in the RTL. The practical shape is an SPI-RAM
mailbox: host software talks USB to the RP2040, RP2040 firmware exposes a small
SPI RAM window, and the Compute Tile RTL polls command/status/result slots over SPI.

UART-to-USB should be a separate serial-console variant using Tiny Tapeout's
recommended pair `ui_in[3]` as RX and `uo_out[4]` as TX, or the alternate pair
`ui_in[1]` as RX and `uo_out[0]` as TX. USB remains on the demo-board RP2040
side; the user RTL should expose UART or SPI pins, not implement a USB PHY.

I2C should be treated as a later low-speed management option. It needs
open-drain-style behavior: drive `SCL`/`SDA` low or release them with `uio_oe=0`,
instead of driving push-pull highs.

## Opcodes

| Opcode | Name | Behavior |
| --- | --- | --- |
| `000` | `STATUS` | Public status; `uio_out` selects capability, trace, op count, or error count. |
| `001` | `GATE` | Unlock with `ui_in[4:0]=5'h1a` and `uio_in=8'ha5`; relock with `5'h05` and `8'h5a`. |
| `010` | `LOAD_A` | Protected operand A load from `uio_in`. |
| `011` | `LOAD_B` | Protected operand B load from `uio_in`. |
| `100` | `COMPUTE` | Protected ADD, MUL-low, MAX, ReLU, 2-lane nibble dot, or XOR. |
| `101` | `READ_RESULT` | Protected result read; select result, trace, cycle count, or last command. |
| `110` | `FAULT` | Protected compute-disable, error inject, and error clear hook. |
| `111` | `SELF_TEST` | Protected built-in self-test for the byte datapath. |

## Shared RTL Ownership

The canonical core is `rtl/compute_tile_tiny_tapeout_core.v` in the parent repo. The
Tiny Tapeout template also keeps a copy at `src/compute_tile_tiny_tapeout_core.v`
because the template expects source files under `src/`. Run:

```sh
../../scripts/tiny-tapeout/sync-shared-rtl.sh
```

from this directory, or run the same script from the repository root, before
submitting changes. The parent pytest suite checks that the two copies match.

## Test

```sh
cd ttsky-compute-tile/test
make
```

The cocotb test covers reset-held outputs, post-reset public status, locked
rejection, unlock/relock, operand loads, ADD, all byte compute operations,
compute disable, self-test, `uio_oe` direction, and all externally visible output
lanes toggling high and low.

Keep Tiny Tapeout-facing cocotb tests in `ttsky-compute-tile/test` so the template
CI and hardening flow can run them. Keep parent-repo guard tests in
`tests/test_tiny_tapeout_project.py` for shared RTL sync, docs, and metadata
drift checks.
