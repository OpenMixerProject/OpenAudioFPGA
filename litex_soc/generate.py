#!/usr/bin/env python3
"""
OpenAudioFPGA control bus: LiteX SoC generator.

Generates the CPU-less control SoC of OpenAudioFPGA as Verilog (HDL only, no synthesis):

    i.MX25 SPI (CS0) -> SPIBone -> Wishbone ---------+-> CSRs    0x00000000  ctrl, core
                                                      +-> routing 0x80000000  routing matrix
                                                      +-> aes67   0x90000000  AES67 core

An access without answer (no slave at the address) ends after 1e6 clocks with a bus error,
counted in ctrl_bus_errors. SPIBone answers a bus error like a normal access (a read returns
undefined data): check core_info.aes67 before using the AES67 window (without AES67 core it
answers with a bus error at once).

SPIBone is the burst-capable fork in litex_soc/spi_bone.py (commands 0x02 / 0x03); the host
side is the Linux bus driver in driver/spibone. Nothing here needs the AES67 repository. The
AES67 core keeps the window of the standalone AES67 SPIBone bridge, so the csr.csv of the AES67
aes67_bridge target (and everything built on it) is unchanged.

Usage (LiteX and migen as pinned in litex_soc/requirements.txt, see litex_soc/setup_venv.sh):

    litex_soc/.venv/bin/python litex_soc/generate.py [--family lattice|xilinx|all]

Output: litex_soc/build/<family>/
    gateware/openaudio_soc.v    module openaudio_soc
    csr.csv, csr.json           register map of this bus (the AES67 window is only
                                listed as a memory region, its registers are in the
                                csr.csv of the aes67_bridge target)
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from migen import *
from migen.fhdl.structure import _Fragment
from migen.genlib.resetsync import AsyncResetSynchronizer
from litex.gen import *
from litex.build.generic_platform import Pins, Subsignal
from litex.build.lattice import LatticePlatform
from litex.build.xilinx import XilinxPlatform
from litex.soc.integration.soc_core import SoCCore
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.builder import Builder
from litex.soc.interconnect import wishbone
from litex.soc.interconnect.csr import CSRStatus, CSRStorage, CSRField

from spi_bone import SPIBone


SYS_CLK_FREQ = 50e6     # the RMII clock of the X32 (clk_50m_i of x32_common)

# Wishbone slaves outside of the SoC: (bus name, byte origin, byte size)
WB_SLAVES = [
    ("routing", 0x80000000, 0x10000),   # routing matrix, one word per destination
    ("aes67",   0x90000000, 0x20000),   # AES67 core (aes67_bridge window)
]


# -- IO ----------------------------------------------------------------------------

def _wb_pads(name):
    return (name, 0,
        Subsignal("adr",   Pins(30)),
        Subsignal("dat_w", Pins(32)),
        Subsignal("dat_r", Pins(32)),
        Subsignal("sel",   Pins(4)),
        Subsignal("cyc",   Pins(1)),
        Subsignal("stb",   Pins(1)),
        Subsignal("we",    Pins(1)),
        Subsignal("cti",   Pins(3)),
        Subsignal("bte",   Pins(2)),
        Subsignal("ack",   Pins(1)),
        Subsignal("err",   Pins(1)),
    )

_io = [
    ("clk_sys", 0, Pins(1)),
    ("spibone", 0,
        Subsignal("clk",  Pins(1)),
        Subsignal("cs_n", Pins(1)),
        Subsignal("mosi", Pins(1)),
        Subsignal("miso", Pins(1)),
    ),
    # static information about the build (from the VHDL generics) and the config bits
    ("core", 0,
        Subsignal("info",    Pins(32)),
        Subsignal("version", Pins(32)),
        Subsignal("config",  Pins(8)),
    ),
] + [_wb_pads(f"{name}_wb") for name, _, _ in WB_SLAVES]


def _stub_build(platform, fragment, build_dir="build", build_name="openaudio_soc", run=True, **kwargs):
    """HDL-only build: write the Verilog of the SoC, run no vendor tool."""
    os.makedirs(build_dir, exist_ok=True)
    if not isinstance(fragment, _Fragment):
        fragment = fragment.get_fragment()
    platform.finalize(fragment)
    v_output = platform.get_verilog(fragment, name=build_name)
    v_output.write(os.path.join(build_dir, f"{build_name}.v"))
    return v_output.ns


class LatticeStub(LatticePlatform):
    default_clk_name   = "clk_sys"
    default_clk_period = 1e9 / SYS_CLK_FREQ

    def __init__(self):
        LatticePlatform.__init__(self, "LFE5U-25F-6BG256C", _io, toolchain="diamond")

    def build(self, fragment, **kwargs):
        return _stub_build(self, fragment, **kwargs)


class XilinxStub(XilinxPlatform):
    default_clk_name   = "clk_sys"
    default_clk_period = 1e9 / SYS_CLK_FREQ

    def __init__(self):
        XilinxPlatform.__init__(self, "xc3s1400a-fg484-4", _io, toolchain="ise")

    def build(self, fragment, **kwargs):
        return _stub_build(self, fragment, **kwargs)


PLATFORMS = {"lattice": LatticeStub, "xilinx": XilinxStub}


# -- CSRs ----------------------------------------------------------------------------

class CoreCSRs(LiteXModule):
    """Identification and configuration of the OpenAudioFPGA core."""

    def __init__(self, pads):
        self.info = CSRStatus(fields=[
            CSRField("tdm_lines_in",  size=8, offset=0,  description="TDM8 input lines of the routing matrix (8 sources each)."),
            CSRField("tdm_lines_out", size=8, offset=8,  description="TDM8 output lines of the routing matrix (8 destinations each)."),
            CSRField("aes50_ports",   size=4, offset=16, description="Number of AES50 cores."),
            CSRField("aes67",         size=1, offset=20, description="1 = with AES67 core (bus window aes67)."),
            CSRField("platform",      size=8, offset=24, description="Platform: 1 = X32 Lattice ECP5, 2 = X32 Xilinx Spartan-3A."),
        ], description="Build information (VHDL generics).")
        self.version = CSRStatus(32, description="Gateware version (VHDL constant).")
        self.config = CSRStorage(8, description="Configuration bits (cfg_bits_o of the core; was address 255 of the old routing SPI protocol).")

        # # #

        # a CSRStatus with fields is driven by its fields, not by .status
        self.comb += [
            self.info.fields.tdm_lines_in.eq(pads.info[0:8]),
            self.info.fields.tdm_lines_out.eq(pads.info[8:16]),
            self.info.fields.aes50_ports.eq(pads.info[16:20]),
            self.info.fields.aes67.eq(pads.info[20]),
            self.info.fields.platform.eq(pads.info[24:32]),
            self.version.status.eq(pads.version),
            pads.config.eq(self.config.storage),
        ]


# -- clock / reset ---------------------------------------------------------------------

class _CRG(LiteXModule):
    """sys clock from the clk_sys pad (the top level owns the clocking)."""

    def __init__(self, platform):
        self.rst    = Signal()
        self.cd_sys = ClockDomain()

        # # #

        self.comb += self.cd_sys.clk.eq(platform.request("clk_sys"))
        self.specials += AsyncResetSynchronizer(self.cd_sys, self.rst)


# Wishbone signals by direction, seen from the master
_WB_M_TO_S = ["adr", "dat_w", "sel", "cyc", "stb", "we", "cti", "bte"]
_WB_S_TO_M = ["dat_r", "ack", "err"]


def _wire_master_to_pads(soc, iface, pads):
    """Route a Wishbone interface whose master is in the SoC to pads (a slave outside)."""
    soc.comb += [getattr(pads, n).eq(getattr(iface, n)) for n in _WB_M_TO_S]
    soc.comb += [getattr(iface, n).eq(getattr(pads, n)) for n in _WB_S_TO_M]


# -- SoC -----------------------------------------------------------------------------

class OpenAudioSoC(SoCCore):
    def __init__(self, platform, sys_clk_freq=SYS_CLK_FREQ):
        SoCCore.__init__(self, platform, sys_clk_freq,
            cpu_type                 = "None",
            # one master: the shared interconnect, which (unlike the crossbar) has the bus
            # timeout: an access without answer ends with err after 1e6 clocks (20 ms) and
            # counts in ctrl_bus_errors
            bus_interconnect         = "shared",
            integrated_rom_size      = 0,
            integrated_sram_size     = 0,
            integrated_main_ram_size = 0,
            ident                    = "",
            with_uart                = False,
            with_timer               = False,
        )
        self.add_config("identifier", "OpenAudioFPGA")
        # fixed CSR banks: ctrl first (LiteX convention, ctrl_scratch at 0x4), then core
        self.csr.add("ctrl", n=0, use_loc_if_exists=True)
        self.csr.add("core", n=1, use_loc_if_exists=True)

        self.crg = _CRG(platform)

        # SPI -> Wishbone master. MISO is a plain output (no tristate): the X32 tops
        # drive the MISO pin themselves, with the chip select.
        self.spibone = SPIBone(platform.request("spibone"), with_burst=True, with_tristate=False)
        self.bus.add_master(name="spibone", master=self.spibone.bus)

        self.core = CoreCSRs(platform.request("core"))

        for name, origin, size in WB_SLAVES:
            iface = wishbone.Interface(data_width=32, adr_width=30)
            self.bus.add_slave(name=name, slave=iface,
                region=SoCRegion(origin=origin, size=size, cached=False))
            _wire_master_to_pads(self, iface, platform.request(f"{name}_wb"))


# -- main ----------------------------------------------------------------------------

def build(family, output_dir):
    platform = PLATFORMS[family]()
    soc = OpenAudioSoC(platform)
    builder = Builder(soc,
        output_dir       = output_dir,
        compile_software = False,
        compile_gateware = False,
        csr_json         = os.path.join(output_dir, "csr.json"),
        csr_csv          = os.path.join(output_dir, "csr.csv"),
    )
    builder.build(build_name="openaudio_soc", run=False)
    print(f"{family}: {output_dir}/gateware/openaudio_soc.v, {output_dir}/csr.csv")


def main():
    parser = argparse.ArgumentParser(description="Generate the OpenAudioFPGA control SoC (SPIBone + Wishbone)")
    parser.add_argument("--family", default="all", choices=["lattice", "xilinx", "all"])
    parser.add_argument("--output-dir", default=None, help="output directory (single family only)")
    args = parser.parse_args()

    families = list(PLATFORMS) if args.family == "all" else [args.family]
    if args.output_dir and len(families) > 1:
        parser.error("--output-dir needs a single --family")
    for family in families:
        build(family, args.output_dir or os.path.join(HERE, "build", family))


if __name__ == "__main__":
    main()
