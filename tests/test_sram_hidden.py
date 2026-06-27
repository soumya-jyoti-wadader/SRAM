"""Cocotb testbench for sram.sv — SRAM with Hamming SECDED ECC."""

from __future__ import annotations

import os
import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.runner import get_runner

# ---------------------------------------------------------------------------
# Design parameters (must match golden/sram.sv)
# ---------------------------------------------------------------------------
COLS = 8
ROWS = 1024
ADDR_WIDTH = 14
LATENCY = 2
ECC_BITS = 6
CLK_PERIOD_NS = 10
HOLD_DELAY_NS = 1  # > POR_HLD_DELAY (#0.1) and POR_MEM_DELAY (#0.1)


class SramModel:
    """Byte-wide software model of the SRAM write path."""

    def __init__(self, rows: int = ROWS, cols: int = COLS) -> None:
        self.memory = [0] * rows
        self.mask = (1 << cols) - 1

    def write(self, addr: int, data: int) -> int:
        previous = self.memory[addr]
        self.memory[addr] = data & self.mask
        return previous

    def peek(self, addr: int) -> int:
        return self.memory[addr]


# ---------------------------------------------------------------------------
# Stimulus helpers
# ---------------------------------------------------------------------------
async def start_clocks(dut) -> None:
    Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start(start_high=False)
    Clock(dut.clk_inst, CLK_PERIOD_NS, unit="ns").start(start_high=False)


async def drive_idle(dut) -> None:
    dut.addr.value = 0
    dut.data_in.value = 0
    dut.chip_select.value = 0
    dut.write_enable.value = 0
    dut.write_mask.value = 0


async def apply_reset(dut, hold_cycles: int = 3) -> None:
    dut.global_reset.value = 1
    await drive_idle(dut)
    for _ in range(hold_cycles):
        await RisingEdge(dut.clk_inst)
    dut.global_reset.value = 0
    await RisingEdge(dut.clk_inst)


async def commit_write(dut, addr: int, data: int) -> None:
    """Drive a single write cycle on the write clock."""
    dut.addr.value = addr
    dut.data_in.value = data & 0xFF
    dut.write_mask.value = 0
    dut.chip_select.value = 1
    dut.write_enable.value = 1
    await RisingEdge(dut.clk)
    dut.chip_select.value = 0
    dut.write_enable.value = 0
    await Timer(HOLD_DELAY_NS, unit="ns")


def sample_output(dut) -> int:
    value = dut.data_out.value
    if not value.is_resolvable:
        raise AssertionError(f"data_out contains X/Z: {value}")
    return int(value)


async def write_then_readback(dut, addr: int, stored: int, probe: int) -> int:
    """
    Return the byte already in memory while starting a new write of *probe*.

    Keep chip_select asserted across both phases so the read pipeline is not
    flushed to X.  With LATENCY=2 the stored value appears on data_out after
    the probe write begins and the pipeline fills.
    """
    dut.addr.value = addr
    dut.data_in.value = stored & 0xFF
    dut.write_mask.value = 0
    dut.chip_select.value = 1
    dut.write_enable.value = 1
    await RisingEdge(dut.clk)

    dut.data_in.value = probe & 0xFF
    dut.write_enable.value = 0
    await Timer(HOLD_DELAY_NS, unit="ns")
    for _ in range(LATENCY):
        await RisingEdge(dut.clk_inst)
    await Timer(HOLD_DELAY_NS, unit="ns")
    return sample_output(dut)


async def finish_probe_write(dut) -> None:
    """Commit the probe write that was started during readback."""
    await RisingEdge(dut.clk)
    dut.chip_select.value = 0
    dut.write_enable.value = 0
    await Timer(HOLD_DELAY_NS, unit="ns")


async def read_with_ecc_check(dut, addr: int, expected_data: int) -> tuple[int, int, int]:
    """Perform a read and return (data_out, ecc_single_err, ecc_double_err)."""
    dut.addr.value = addr
    dut.data_in.value = 0
    dut.write_mask.value = 0
    dut.chip_select.value = 1
    dut.write_enable.value = 0
    await RisingEdge(dut.clk)
    await Timer(HOLD_DELAY_NS, unit="ns")
    for _ in range(LATENCY):
        await RisingEdge(dut.clk_inst)
    await Timer(HOLD_DELAY_NS, unit="ns")

    data = sample_output(dut)
    single = int(dut.ecc_single_err.value)
    double = int(dut.ecc_double_err.value)

    dut.chip_select.value = 0
    await Timer(HOLD_DELAY_NS, unit="ns")

    assert data == expected_data, (
        f"read addr {addr:#06x}: expected data {expected_data:#04x}, got {data:#04x}"
    )
    return data, single, double


# ---------------------------------------------------------------------------
# Cocotb tests — basic SRAM
# ---------------------------------------------------------------------------
@cocotb.test()
async def sram_reset_test(dut):
    """global_reset clears ECC flags; read path works after reset."""
    await start_clocks(dut)
    await drive_idle(dut)
    dut.global_reset.value = 0

    await RisingEdge(dut.clk_inst)
    await apply_reset(dut)

    assert int(dut.ecc_single_err.value) == 0, "ecc_single_err should be 0 after reset"
    assert int(dut.ecc_double_err.value) == 0, "ecc_double_err should be 0 after reset"
    assert int(dut.ecc_err_addr.value) == 0, "ecc_err_addr should be 0 after reset"

    await commit_write(dut, 0, 0)
    data, _, _ = await read_with_ecc_check(dut, 0, 0)
    assert data == 0, f"expected data_out=0 after reset+write, got {data:#x}"


@cocotb.test()
async def sram_write_readback_test(dut):
    """Writing twice to the same address returns the first value on data_out."""
    model = SramModel()
    await start_clocks(dut)
    await apply_reset(dut)

    addr = 0x0042
    first = 0xA5
    second = 0x3C

    observed = await write_then_readback(dut, addr, first, second)
    model.write(addr, first)
    assert observed == first, (
        f"readback during second write: expected {first:#04x}, got {observed:#04x}"
    )

    await finish_probe_write(dut)
    model.write(addr, second)

    observed = await write_then_readback(dut, addr, second, 0x00)
    assert observed == second, (
        f"readback after update: expected {second:#04x}, got {observed:#04x}"
    )


@cocotb.test()
async def sram_multi_address_test(dut):
    """Writes to different addresses remain independent."""
    model = SramModel()
    await start_clocks(dut)
    await apply_reset(dut)

    table = {
        0x0001: 0x11,
        0x0002: 0x22,
        0x0100: 0xAB,
        0x03FF: 0xFF,
    }

    for addr, data in table.items():
        await commit_write(dut, addr, data)
        model.write(addr, data)

    for addr, expected in table.items():
        observed = await write_then_readback(dut, addr, expected, 0x55)
        assert observed == expected, (
            f"addr {addr:#06x}: expected {expected:#04x}, got {observed:#04x}"
        )
        await finish_probe_write(dut)


@cocotb.test()
async def sram_random_write_test(dut):
    """Random address/data pairs are stored and read back correctly."""
    model = SramModel()
    await start_clocks(dut)
    await apply_reset(dut)

    rng = random.Random(42)

    for _ in range(32):
        addr = rng.randrange(0, ROWS)
        data = rng.randrange(0, 1 << COLS)

        await commit_write(dut, addr, data)
        model.write(addr, data)

        probe = rng.randrange(0, 1 << COLS)
        observed = await write_then_readback(dut, addr, data, probe)
        expected = model.peek(addr)

        assert observed == expected, (
            f"addr {addr:#06x}: expected {expected:#04x}, got {observed:#04x}"
        )

        await finish_probe_write(dut)
        model.write(addr, probe)


# ---------------------------------------------------------------------------
# Cocotb tests — ECC (sram.sv specific)
# ---------------------------------------------------------------------------
@cocotb.test()
async def ecc_clean_read_no_flags_test(dut):
    """Clean reads must not raise ECC error flags."""
    await start_clocks(dut)
    await apply_reset(dut)

    addr = 0x0020
    data = 0x5A
    await commit_write(dut, addr, data)

    _, single, double = await read_with_ecc_check(dut, addr, data)
    assert single == 0, f"expected ecc_single_err=0, got {single}"
    assert double == 0, f"expected ecc_double_err=0, got {double}"


@cocotb.test()
async def ecc_single_bit_correction_test(dut):
    """Flip one stored data bit; ECC should correct and flag single error."""
    await start_clocks(dut)
    await apply_reset(dut)

    addr = 0x0030
    data = 0xC3
    await commit_write(dut, addr, data)

    stored_val = dut.memory[addr].value
    if not stored_val.is_resolvable:
        raise AssertionError("memory word contains X/Z after write")
    stored = int(stored_val)

    # Corrupt bit 2 of the data field (lower COLS bits of memory word)
    corrupted = stored ^ (1 << 2)
    dut.memory[addr].value = corrupted

    dut.addr.value = addr
    dut.chip_select.value = 1
    dut.write_enable.value = 0
    dut.write_mask.value = 0
    await RisingEdge(dut.clk)
    await Timer(HOLD_DELAY_NS, unit="ns")
    for _ in range(LATENCY):
        await RisingEdge(dut.clk_inst)
    await Timer(HOLD_DELAY_NS, unit="ns")

    observed = sample_output(dut)
    single = int(dut.ecc_single_err.value)
    double = int(dut.ecc_double_err.value)

    dut.chip_select.value = 0

    assert observed == data, (
        f"ECC correction failed: expected {data:#04x}, got {observed:#04x}"
    )
    assert single == 1, f"expected ecc_single_err=1, got {single}"
    assert double == 0, f"expected ecc_double_err=0, got {double}"


@cocotb.test()
async def ecc_double_bit_detection_test(dut):
    """Flip two stored data bits; ECC should flag double error."""
    await start_clocks(dut)
    await apply_reset(dut)

    addr = 0x0040
    data = 0x96
    await commit_write(dut, addr, data)

    stored_val = dut.memory[addr].value
    if not stored_val.is_resolvable:
        raise AssertionError("memory word contains X/Z after write")
    stored = int(stored_val)
    corrupted = stored ^ (1 << 1) ^ (1 << 4)
    dut.memory[addr].value = corrupted

    dut.addr.value = addr
    dut.chip_select.value = 1
    dut.write_enable.value = 0
    dut.write_mask.value = 0
    await RisingEdge(dut.clk)
    await Timer(HOLD_DELAY_NS, unit="ns")
    for _ in range(LATENCY):
        await RisingEdge(dut.clk_inst)
    await Timer(HOLD_DELAY_NS, unit="ns")

    double = int(dut.ecc_double_err.value)
    dut.chip_select.value = 0

    assert double == 1, f"expected ecc_double_err=1, got {double}"


# ---------------------------------------------------------------------------
# Pytest runner (invokes cocotb via cocotb_tools)
# ---------------------------------------------------------------------------
def test_sram_hidden_runner():
    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent.parent

    sources = [proj_path / "sources" / "sram.sv"]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="sram",
        always=True,
    )
    runner.test(
        hdl_toplevel="sram",
        test_module=Path(__file__).stem,
    )
