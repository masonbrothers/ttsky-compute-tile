# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer


OPC_STATUS = 0
OPC_GATE = 1
OPC_LOAD_A = 2
OPC_LOAD_B = 3
OPC_COMPUTE = 4
OPC_READ_RESULT = 5
OPC_FAULT = 6
OPC_SELF_TEST = 7

IMM_UNLOCK = 0x1A
IMM_LOCK = 0x05

KEY_UNLOCK = 0xA5
KEY_LOCK = 0x5A

CAPABILITY = 0x7F
LOCKED_ERR = 0xE1
FAULT_ERR = 0xE2
PASS_CODE = 0xC3
FAIL_CODE = 0x3C
POST_CLOCK_SETTLE_NS = 100


def cmd(opcode, imm=0):
    return ((opcode & 0x7) << 5) | (imm & 0x1F)


def value(signal):
    return int(signal.value)


def observe(dut, observed):
    observed["uo_out"].append(value(dut.uo_out))
    observed["uio_out"].append(value(dut.uio_out))
    observed["uio_oe"].append(value(dut.uio_oe))


def assert_all_bits_toggle(name, samples):
    high_seen = 0
    low_seen = 0
    for sample in samples:
        high_seen |= sample & 0xFF
        low_seen |= (~sample) & 0xFF

    assert high_seen == 0xFF, f"{name} never drove high bits 0x{(~high_seen) & 0xFF:02x}"
    assert low_seen == 0xFF, f"{name} never drove low bits 0x{(~low_seen) & 0xFF:02x}"


async def cycle(dut, command, data=0):
    dut.ui_in.value = command
    dut.uio_in.value = data
    await ClockCycles(dut.clk, 1)
    # Gate-level simulations use UNIT_DELAY=#1; sample well after the delayed
    # cell path has propagated instead of racing the first delayed transition.
    await Timer(POST_CLOCK_SETTLE_NS, unit="ns")


async def load_compute_read(dut, op, operand_a, operand_b):
    await cycle(dut, cmd(OPC_LOAD_A), operand_a)
    await cycle(dut, cmd(OPC_LOAD_B), operand_b)
    await cycle(dut, cmd(OPC_COMPUTE, op), 0)
    compute_value = value(dut.uo_out)
    await cycle(dut, cmd(OPC_READ_RESULT, 0), 0)
    return compute_value, value(dut.uio_out)


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")
    observed = {
        "uo_out": [],
        "uio_out": [],
        "uio_oe": [],
    }

    # Set the clock period to 10 us (100 KHz)
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    dut.ena.value = 0
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await Timer(POST_CLOCK_SETTLE_NS, unit="ns")
    assert value(dut.uo_out) == 0
    assert value(dut.uio_out) == 0
    assert value(dut.uio_oe) == 0
    observe(dut, observed)

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)
    await Timer(POST_CLOCK_SETTLE_NS, unit="ns")
    observe(dut, observed)

    dut._log.info("Public status works after reset")
    dut.ui_in.value = cmd(OPC_STATUS, 0)
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 1)
    await Timer(POST_CLOCK_SETTLE_NS, unit="ns")
    assert value(dut.uo_out) & 0x43 == 0x41
    assert value(dut.uio_out) == CAPABILITY
    assert value(dut.uio_oe) == 0xFF
    observe(dut, observed)

    dut._log.info("Protected writes are rejected while locked")
    await cycle(dut, cmd(OPC_LOAD_A), 0x12)
    await cycle(dut, cmd(OPC_READ_RESULT), 0)
    assert value(dut.uo_out) == LOCKED_ERR
    assert value(dut.uio_out) == LOCKED_ERR
    assert value(dut.uio_oe) == 0xFF
    observe(dut, observed)

    dut._log.info("Unlock, load operands, and run Compute Tile-like byte ops")
    await cycle(dut, cmd(OPC_GATE, IMM_UNLOCK), KEY_UNLOCK)
    assert value(dut.uo_out) == 0x55
    assert value(dut.uio_oe) == 0x00
    observe(dut, observed)

    for op, operand_a, operand_b, expected in [
        (0, 0x12, 0x34, 0x46),  # ADD
        (1, 0x11, 0x22, 0x42),  # MUL-low
        (2, 0xF0, 0x0F, 0xF0),  # MAX
        (3, 0x80, 0x55, 0x00),  # ReLU
        (4, 0x21, 0x43, 0x0B),  # 2-lane nibble dot
        (5, 0xA5, 0x5A, 0xFF),  # XOR
    ]:
        compute_value, read_value = await load_compute_read(dut, op, operand_a, operand_b)
        assert compute_value == expected
        assert value(dut.uio_oe) == 0xFF
        assert read_value == expected
        observe(dut, observed)

    dut._log.info("Disabled design releases outputs and ignores commands")
    dut.ena.value = 0
    dut.ui_in.value = cmd(OPC_COMPUTE, 0)
    dut.uio_in.value = 0xFF
    await ClockCycles(dut.clk, 2)
    await Timer(POST_CLOCK_SETTLE_NS, unit="ns")
    assert value(dut.uo_out) == 0x00
    assert value(dut.uio_out) == 0x00
    assert value(dut.uio_oe) == 0x00
    observe(dut, observed)

    dut.ena.value = 1
    await cycle(dut, cmd(OPC_READ_RESULT, 0), 0)
    assert value(dut.uo_out) == 0xFF
    assert value(dut.uio_out) == 0xFF
    assert value(dut.uio_oe) == 0xFF
    observe(dut, observed)

    dut._log.info("Fault control disables compute and self-test proves the datapath")
    await cycle(dut, cmd(OPC_FAULT), 0x01)
    await cycle(dut, cmd(OPC_COMPUTE, 0), 0)
    assert value(dut.uo_out) == FAULT_ERR
    observe(dut, observed)

    await cycle(dut, cmd(OPC_FAULT), 0x80)
    await cycle(dut, cmd(OPC_SELF_TEST), 0)
    assert value(dut.uo_out) == PASS_CODE
    assert value(dut.uio_out) == PASS_CODE
    assert value(dut.uio_oe) == 0xFF
    assert value(dut.uo_out) != FAIL_CODE
    observe(dut, observed)

    dut._log.info("Relock prevents result reads")
    await cycle(dut, cmd(OPC_GATE, IMM_LOCK), KEY_LOCK)
    assert value(dut.uo_out) == 0x0F
    observe(dut, observed)
    await cycle(dut, cmd(OPC_READ_RESULT), 0)
    assert value(dut.uo_out) == LOCKED_ERR
    observe(dut, observed)

    dut._log.info("All externally visible lanes have full bit coverage")
    assert_all_bits_toggle("uo_out", observed["uo_out"])
    assert_all_bits_toggle("uio_out", observed["uio_out"])
    assert_all_bits_toggle("uio_oe", observed["uio_oe"])
