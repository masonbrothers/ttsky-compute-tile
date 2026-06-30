# Status, Error, and LED Reference

Date: 2026-06-30

## Audience, Purpose, Owner, Freshness

- Audience: Tiny Tapeout bring-up operators, RTL implementers, and test authors.
- Purpose: show what `uo_out[7:0]` means on the board LEDs for status reads,
  error codes, self-test codes, and common manual bring-up sequences.
- Owner: accelerator/Compute Tile architecture.
- Freshness trigger: update this document when `compute_tile_tiny_tapeout_core.v`,
  `info.yaml`, `docs/pinout-plan.md`, or the cocotb protocol test changes.

## How To Read The Diagrams

The diagrams use bit order `L7 ... L0`, matching `uo_out[7] ... uo_out[0]`.
If a board lays LEDs out in the opposite physical order, the bit numbers remain
the source of truth.

```text
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
uo_out:   b7 b6 b5 b4 b3 b2 b1 b0
```

`1` means that output bit is high. `0` means that output bit is low. `P` means
the trace-parity bit is data-dependent.

## Important Rule

`uo_out` is not always a status register. It is whatever the current opcode
selects:

| Opcode | `uo_out` meaning |
| --- | --- |
| `STATUS` | status byte |
| `GATE` | gate acknowledgement code |
| `LOAD_A`, `LOAD_B`, `FAULT` | status byte |
| `COMPUTE` | compute result, `LOCKED_ERR`, or `FAULT_ERR` |
| `READ_RESULT` | result byte or `LOCKED_ERR` |
| `SELF_TEST` | `PASS_CODE`, `FAIL_CODE`, or `LOCKED_ERR` |

For status LEDs, issue a `STATUS` command. For code/result LEDs, issue the
specific command whose output you want to inspect.

## Status Byte Layout

Status byte bit order:

```text
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Meaning:  P  EN ST FD ER RV UN AL
```

| Bit | Name | Meaning |
| --- | --- | --- |
| `L7` | `P` | Trace checksum parity; data-dependent. |
| `L6` | `EN` | Tiny Tapeout `ena` is high. |
| `L5` | `ST` | Self-test has passed. |
| `L4` | `FD` | Compute-disabled/fault mode is active. |
| `L3` | `ER` | Sticky error bit is set. |
| `L2` | `RV` | Result register is valid. |
| `L1` | `UN` | Protected aperture is unlocked. |
| `L0` | `AL` | Alive/status-valid bit, always high while enabled. |

Reset plus `STATUS` should show `0x41`:

```text
0x41 reset status
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     0  1  0  0  0  0  0  1
Meaning:   P  EN ST FD ER RV UN AL
```

Unlocked status usually shows `EN`, `UN`, and `AL`, plus data-dependent parity:

```text
unlocked status
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     P  1  0  0  0  0  1  1
Meaning:   P  EN ST FD ER RV UN AL
```

Unlocked result-valid status usually shows `EN`, `RV`, `UN`, and `AL`, plus
data-dependent parity:

```text
result-valid status
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     P  1  0  0  0  1  1  1
Meaning:   P  EN ST FD ER RV UN AL
```

## Fixed Codes

These codes are fixed by `compute_tile_tiny_tapeout_core.v`.

| Name | Hex | Binary | LEDs high | When seen |
| --- | --- | --- | --- | --- |
| `LOCKED_ERR` | `0xe1` | `11100001` | `L7,L6,L5,L0` | Protected command while locked. |
| `FAULT_ERR` | `0xe2` | `11100010` | `L7,L6,L5,L1` | Compute attempted while fault-disabled. |
| `PASS_CODE` | `0xc3` | `11000011` | `L7,L6,L1,L0` | `SELF_TEST` passed. |
| `FAIL_CODE` | `0x3c` | `00111100` | `L5,L4,L3,L2` | `SELF_TEST` failed. |
| `GATE_UNLOCKED` | `0x55` | `01010101` | `L6,L4,L2,L0` | Gate reports unlocked. |
| `GATE_LOCKED` | `0x0f` | `00001111` | `L3,L2,L1,L0` | Gate reports locked. |
| `CAPABILITY` | `0x7f` | `01111111` | not on `uo_out` | `STATUS` places this on `uio_out`. |

### `LOCKED_ERR` Diagram

```text
0xe1 LOCKED_ERR
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     1  1  1  0  0  0  0  1
```

### `FAULT_ERR` Diagram

```text
0xe2 FAULT_ERR
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     1  1  1  0  0  0  1  0
```

### Self-Test Diagrams

```text
0xc3 PASS_CODE
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     1  1  0  0  0  0  1  1

0x3c FAIL_CODE
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     0  0  1  1  1  1  0  0
```

### Gate Acknowledgement Diagrams

```text
0x55 GATE_UNLOCKED
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     0  1  0  1  0  1  0  1

0x0f GATE_LOCKED
LED bit:  L7 L6 L5 L4 L3 L2 L1 L0
Value:     0  0  0  0  1  1  1  1
```

## Manual Bring-Up Sequence

This sequence mirrors the cocotb test and is useful for LED-based inspection.

| Step | Command | Expected `uo_out` | LED pattern `L7..L0` |
| --- | --- | --- | --- |
| Reset, then `STATUS` | `000xxxxx` | `0x41` | `01000001` |
| Protected read while locked | `READ_RESULT` | `0xe1` | `11100001` |
| Unlock | `GATE`, `imm=5'h1a`, `uio_in=8'ha5` | `0x55` | `01010101` |
| Load `A=0x12`, `B=0x34`, ADD | `COMPUTE`, op `0` | `0x46` | `01000110` |
| Read result | `READ_RESULT` | `0x46` | `01000110` |
| Disable compute and compute | `FAULT`, then `COMPUTE` | `0xe2` | `11100010` |
| Clear fault and self-test | `FAULT`, then `SELF_TEST` | `0xc3` | `11000011` |
| Relock | `GATE`, `imm=5'h05`, `uio_in=8'h5a` | `0x0f` | `00001111` |

## Simulation Reference

Run the Tiny Tapeout protocol simulation from the template test directory:

```sh
uv run --with cocotb --with pytest make SIM=verilator
```

The simulation checks the fixed error/self-test codes, representative compute
results, locked rejection, unlock/relock behavior, and `uio_oe` direction.
