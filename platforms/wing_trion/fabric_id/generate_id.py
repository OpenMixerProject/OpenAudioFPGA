#!/usr/bin/env python3
"""Stage the 925cc382-based WING identity-only Efinity design; bind its native binary."""
import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT))
from platforms.wing_trion.generate import HOST, PORT_B, emit_efinity
from migen import Case, Cat, ClockDomain, If, Module, Record, Signal
from migen.fhdl import verilog
from spi_bone import SPIBone

BASE = "925cc382a2c65affa7866dc313d598a187b6d0d7"
PROFILE = "wing-compact-t55-fabric-id-v1"
CLOCK = 49152000
IMAGE = "wing-fpga.hex.bin"
FIXED = ("phy_ab_reset_n", "phy_b_txen", "sync_b_a_de", "sync_b_b_de",
         "dsp1_reset_n", "dsp2_reset_n", "dsp4_reset_n")
PIN_SCHEMA = {k: HOST[k] for k in HOST if k != "clk_rmii"}
for name in (*FIXED[:4], "sync_b_a_observe", "sync_b_b_observe"):
    PIN_SCHEMA[name] = PORT_B[name][:3]
for dsp in json.loads((ROOT / "consoles/wing/profile-tdm16.json").read_text())["dsp"]:
    if dsp["reset_n"]:
        PIN_SCHEMA[f"dsp{dsp['id']}_reset_n"] = ("out", *dsp["reset_n"])
PIN_SCHEMA["a9_no_drive"] = ("in", "A9", "GPIOT_TXP23")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def source_identity():
    files = [Path(__file__).resolve(), HERE / "identity.sdc", ROOT / "litex_soc/spi_bone.py",
             ROOT / "litex_soc/requirements.txt", HERE.parent / "generate.py",
             ROOT / "consoles/wing/profile-tdm16.json"]
    sources = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in files}
    digest = sha(json.dumps({"base": BASE, "inputs": sources}, sort_keys=True).encode())
    return digest, sources


def generate(out):
    out.mkdir(parents=True, exist_ok=False)
    digest, sources = source_identity()
    build = int(digest[:8], 16)
    registers = {0x1800: ("magic", 0x57494e47), 0x1804: ("abi", 0x00020000),
                 0x1808: ("build", build), 0x180c: ("caps", 0), 0x1810: ("status", 1)}

    top = Module()
    top.clock_domains.cd_sys = ClockDomain("sys", reset_less=True)
    io = {name: Signal(name=name) for name in PIN_SCHEMA if name != "host_miso"}
    for part in ("in", "out", "oe"):
        io[f"host_miso_{part}"] = Signal(name=f"host_miso_{part}")
    pads = Record([("cs_n", 1), ("clk", 1), ("mosi", 1), ("miso", 1)])
    top.submodules.bridge = bridge = SPIBone(pads, with_tristate=False, with_burst=False,
                                              safe_routing=True, read_only=True)
    started = Signal(8, reset=0)
    # SS0/both selected/unselected immediately disables the physical MISO driver.
    deselect = Signal()
    top.sync += started.eq(Cat(1, started[:-1]))
    top.comb += [top.cd_sys.clk.eq(io["clk_audio"]),
                 deselect.eq(io["ctrl_cs_n"] | ~io["dsp_cs_n"] | ~started[-1]),
                 pads.cs_n.eq(deselect), pads.clk.eq(io["host_sck"]), pads.mosi.eq(io["host_mosi"]),
                 io["host_miso_oe"].eq(~deselect), io["host_miso_out"].eq(pads.miso)]
    top.comb += [io[name].eq(0) for name in FIXED]
    bus = bridge.bus
    # One-clock slave response; no combinational path through the master's FSM.
    top.sync += [bus.ack.eq(0), bus.err.eq(0),
                 If(bus.cyc & bus.stb & ~bus.we & ~bus.ack & ~bus.err,
                    Case(bus.adr, {**{addr >> 2: [bus.dat_r.eq(value), bus.ack.eq(1)]
                                     for addr, (_, value) in registers.items()}, "default": bus.err.eq(1)}))]
    (out / "wing_fpga.v").write_text(str(verilog.convert(top, ios=set(io.values()), name="wing_fpga")))
    emit_efinity(out, PIN_SCHEMA, ["wing_fpga.v"])
    (out / "wing.sdc").write_bytes((HERE / "identity.sdc").read_bytes())
    (out / "board-pins.tsv").write_text("signal\tmode\tball\tresource\trun_policy\n" + "".join(
        f"{n}\t{mode}\t{b}\t{r}\t{'constant low' if n in FIXED else 'SS1-only OE' if mode == 'inout' else 'input'}\n"
        for n, (mode, b, r) in PIN_SCHEMA.items()))
    manifest = dict(profile=PROFILE, source_base=BASE, source_sha256=digest, source_inputs=sources,
                    build_id=build, fabric_clock_hz=CLOCK, rmii_clock_required=False,
                    transport=dict(device="/dev/spibone0", compatible="openmixer,wing-spibone",
                                   chip_select=1, mode=0, max_hz=2000000, address_unit="byte"),
                    configuration=dict(device="/dev/spidev1.0", no_cs=True, width=1, offset=0),
                    registers=[dict(address=a, name=n, value=v, access="RO") for a, (n, v) in registers.items()],
                    pins_sha256=sha((out / "board-pins.tsv").read_bytes()),
                    efinity_inputs={n: sha((out / n).read_bytes()) for n in
                                    ("wing_fpga.v", "wing-fpga.xml", "wing-fpga.peri.xml", "wing.sdc")})
    (out / "manifest.unbound.json").write_text(json.dumps(manifest, indent=2) + "\n")


def bind(out):
    manifest = json.loads((out / "manifest.unbound.json").read_text())
    for name, expected in manifest["efinity_inputs"].items():
        if sha((out / name).read_bytes()) != expected:
            raise ValueError(f"changed synthesis input: {name}")
    data = (out / "outflow" / IMAGE).read_bytes()
    if not ({b"Family: Trion", b"Device: T55F484", b"Width: 1", b"Mode: passive"}
            <= set(data[:256].splitlines()) and data[256:260] == bytes.fromhex("168a2236")):
        raise ValueError(f"not native passive x1: {data[256:272].hex()}")
    manifest["bitstream"] = dict(file=IMAGE, sha256=sha(data), size=len(data))
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    parser.add_argument("--bind", action="store_true")
    args = parser.parse_args()
    (bind if args.bind else generate)(args.out)
