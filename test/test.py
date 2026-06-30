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


def cmd(opcode, imm=0):
    return ((opcode & 0x7) << 5) | (imm & 0x1F)


def value(signal):
    return int(signal.value)


async def cycle(dut, command, data=0):
    dut.ui_in.value = command
    dut.uio_in.value = data
    await ClockCycles(dut.clk, 1)
    await Timer(1, unit="ns")


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # Set the clock period to 10 us (100 KHz)
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)

    dut._log.info("Public status works after reset")
    dut.ui_in.value = cmd(OPC_STATUS, 0)
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 1)
    assert value(dut.uo_out) & 0x43 == 0x41
    assert value(dut.uio_out) == CAPABILITY
    assert value(dut.uio_oe) == 0xFF

    dut._log.info("Protected writes are rejected while locked")
    await cycle(dut, cmd(OPC_LOAD_A), 0x12)
    await cycle(dut, cmd(OPC_READ_RESULT), 0)
    assert value(dut.uo_out) == LOCKED_ERR
    assert value(dut.uio_out) == LOCKED_ERR
    assert value(dut.uio_oe) == 0xFF

    dut._log.info("Unlock, load operands, and run compute-tile-like byte ops")
    await cycle(dut, cmd(OPC_GATE, IMM_UNLOCK), KEY_UNLOCK)
    assert value(dut.uo_out) == 0x55
    assert value(dut.uio_oe) == 0x00

    await cycle(dut, cmd(OPC_LOAD_A), 0x12)
    assert value(dut.uio_oe) == 0x00
    await cycle(dut, cmd(OPC_LOAD_B), 0x34)
    await cycle(dut, cmd(OPC_COMPUTE, 0), 0)
    assert value(dut.uo_out) == 0x46

    await cycle(dut, cmd(OPC_READ_RESULT, 0), 0)
    assert value(dut.uo_out) == 0x46
    assert value(dut.uio_out) == 0x46
    assert value(dut.uio_oe) == 0xFF

    await cycle(dut, cmd(OPC_LOAD_A), 0x21)
    await cycle(dut, cmd(OPC_LOAD_B), 0x43)
    await cycle(dut, cmd(OPC_COMPUTE, 4), 0)
    await cycle(dut, cmd(OPC_READ_RESULT, 0), 0)
    assert value(dut.uo_out) == 0x0B

    dut._log.info("Fault control disables compute and self-test proves the datapath")
    await cycle(dut, cmd(OPC_FAULT), 0x01)
    await cycle(dut, cmd(OPC_COMPUTE, 0), 0)
    assert value(dut.uo_out) == FAULT_ERR

    await cycle(dut, cmd(OPC_FAULT), 0x80)
    await cycle(dut, cmd(OPC_SELF_TEST), 0)
    assert value(dut.uo_out) == PASS_CODE
    assert value(dut.uio_out) == PASS_CODE
    assert value(dut.uio_oe) == 0xFF

    dut._log.info("Relock prevents result reads")
    await cycle(dut, cmd(OPC_GATE, IMM_LOCK), KEY_LOCK)
    assert value(dut.uo_out) == 0x0F
    await cycle(dut, cmd(OPC_READ_RESULT), 0)
    assert value(dut.uo_out) == LOCKED_ERR
