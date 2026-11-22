#!/usr/bin/env python3
"""Stage the fork's mixed-language SoC and WING board wiring for Efinity."""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "litex_soc"))
from generate import build
from wing_contract import BOARD_PROFILE, sha256

NAME = "wing-fpga"
DEVICE = "T55F484"
VERSION = "2026.1.132"
AES50_REV = "bffe14e91636efe0c873adfc8244731d610f9e1c"
HOST = {
    "clk_audio": ("in", "R2", "GPIOL_15"), "clk_rmii": ("in", "M3", "GPIOL_67"),
    "host_sck": ("in", "W1", "GPIOL_01"), "host_mosi": ("in", "V2", "GPIOL_08"),
    "host_miso": ("inout", "V1", "GPIOL_09"), "ctrl_cs_n": ("in", "V6", "GPIOL_04"),
    "dsp_cs_n": ("in", "J2", "GPIOL_117"),
}
PORT_B = {
    "phy_b_dv": ("in", "R10", "GPIOB_RXN01", "dv(0)"),
    "phy_b_rxd0": ("in", "V9", "GPIOB_TXP19", "rxd(0)"),
    "phy_b_rxd1": ("in", "AA15", "GPIOB_RXN20", "rxd(1)"),
    "phy_b_txen": ("out", "U6", "GPIOL_12", "txen(0)"),
    "phy_b_txd0": ("out", "Y14", "GPIOB_RXP16", "txd(0)"),
    "phy_b_txd1": ("out", "AB13", "GPIOB_RXP10", "txd(1)"),
    "phy_b_ref": ("out", "AB15", "GPIOB_RXP14", "clk_rmii"),
    "phy_ab_reset_n": ("out", "W9", "GPIOB_TXN19", "phy_reset(0)"),
    # Observe-only until R vs /RE is distinguished; neither is ever driven.
    "sync_b_a_observe": ("in", "T6", "GPIOL_14", "sync_a_rx(0)"),
    "sync_b_b_observe": ("in", "R7", "GPIOL_18", "sync_b_rx(0)"),
    "sync_b_a_d": ("out", "L6", "GPIOL_72", "sync_a_tx(0)"),
    "sync_b_a_de": ("out", "T4", "GPIOL_13", "sync_a_de(0)"),
    "sync_b_b_d": ("out", "K7", "GPIOL_76", "sync_b_tx(0)"),
    "sync_b_b_de": ("out", "AA12", "GPIOB_RXP05", "sync_b_de(0)"),
}


def emit_top(out, profile, count):
    pins = dict(HOST)
    assignments = []

    def pin(name, mode, location, signal):
        ball, resource = location
        assert name not in pins and all(ball != p[1] and resource != p[2] for p in pins.values()), name
        assert ball not in {"A9", "AB9", "A6", "D10"}
        assert ball not in {"T6", "R7"} or mode == "in"
        pins[name] = (mode, ball, resource)
        left, right = (signal, name) if mode == "in" else (name, signal)
        assignments.append(f"    {left} <= {right};")

    used = {"tx": [], "rx": []}
    owners = {"tx": [], "rx": []}
    width = profile["slots"]
    for i, dsp in enumerate(profile["dsp"]):
        n = dsp["id"]
        assert n == i + 1
        for signal, loc in dsp["spi"].items():
            pin(f"dsp{n}_dpi_{signal}", "in" if signal == "miso" else "out", loc, f"dpi_{signal}({i})")
        pin(f"dsp{n}_clkin", "out", dsp["clkin"], "clkin")
        if dsp["reset_n"]:
            pin(f"dsp{n}_reset_n", "out", dsp["reset_n"], f"reset_n({i})")
        for direction in ("tx", "rx"):
            pin(f"dsp{n}_{direction}_bclk", "out", dsp[f"{direction}_clock"][1:], "bclk")
            pin(f"dsp{n}_{direction}_fs", "out", dsp[f"{direction}_fs"][1:], f"fs({i})")
            for lane, (_, ball, resource) in enumerate(dsp[direction]):
                vec = "from_dsp" if direction == "tx" else "to_dsp"
                slots = min(width, max(0, dsp["slots_used"] - width * lane))
                pin(f"dsp{n}_{direction}_data{lane}", "in" if direction == "tx" else "out",
                    (ball, resource), f"{vec}({len(used[direction])})")
                used[direction].append(((dsp["first_id"] + width * lane) * 64 + slots) if slots else 0)
                owners[direction].append(i)

    for name, (mode, ball, resource, signal) in PORT_B.items():
        # Profile 0 retains the exact same physical clock and stimulus pads.
        if not count and mode == "out" and name != "phy_b_ref":
            signal = "'0'"
        if not count and mode == "in":
            signal = name + "_unused"
        pin(name, mode, (ball, resource), signal)

    lanes = max(map(len, used.values()))
    packs = []
    for direction in ("tx", "rx"):
        packs.extend('"' + ''.join(f'{v:0{width}b}' for v in reversed(seq + [0] * (lanes - len(seq)))) + '"'
                     for seq, width in ((used[direction], 15), (owners[direction], 2)))
    for lane in range(len(used["tx"]), lanes):
        assignments.append(f"    from_dsp({lane}) <= '0';")

    taps = []
    for i in range(1, count):
        assignments.extend((f"    dv({i}) <= stimulus({i * 4});",
                            f"    rxd({i * 2 + 1} downto {i * 2}) <= stimulus({i * 4 + 2} downto {i * 4 + 1});",
                            f"    sync_a_rx({i}) <= stimulus({i * 4 + 3});",
                            f"    sync_b_rx({i}) <= stimulus({i * 4 + 4});"))
        taps.extend(f"{signal}({i})" for signal in ("txen", "phy_reset", "sync_a_tx", "sync_a_de", "sync_b_tx", "sync_b_de"))
        taps.extend(f"txd({bit})" for bit in (2*i, 2*i+1))
    if taps:
        assignments.append("""    process(clk_rmii)
    begin
        if rising_edge(clk_rmii) then
            stimulus <= stimulus(14 downto 0) & (stimulus(15) xor stimulus(13) xor phy_b_dv xor phy_b_rxd0);
            observed <= """ + " xor ".join(taps) + ";\n        end if;\n    end process;")

    ports = []
    for name, (mode, _, _) in pins.items():
        ports.extend(("host_miso_out : out std_logic", "host_miso_oe : out std_logic", "host_miso_in : in std_logic")
                     if mode == "inout" else (f"{name} : {mode} std_logic",))
    (out / "wing_fpga.vhd").write_text(f"""library ieee;
use ieee.std_logic_1164.all;
entity wing_fpga is
    port ({'; '.join(ports)});
end entity;
architecture rtl of wing_fpga is
    signal bclk, clkin : std_logic;
    signal dpi_miso, dpi_sel, dpi_sck, dpi_mosi, reset_n, fs : std_logic_vector(3 downto 0);
    signal from_dsp, to_dsp : std_logic_vector({lanes - 1} downto 0);
    signal dv, txen, phy_reset, sync_a_tx, sync_a_de, sync_b_tx, sync_b_de : std_logic_vector({count - 1} downto 0);
    signal sync_a_rx, sync_b_rx : std_logic_vector({count - 1} downto 0);
    signal rxd, txd : std_logic_vector({2*count - 1} downto 0);
    signal stimulus : std_logic_vector(15 downto 0) := x"19C1";
    signal observed : std_logic := '0';
    signal phy_b_dv_unused, phy_b_rxd0_unused, phy_b_rxd1_unused : std_logic;
    signal sync_b_a_observe_unused, sync_b_b_observe_unused : std_logic;
begin
    console : entity work.wing_common
        generic map ({count}, {lanes}, {packs[0]}, {packs[2]}, {packs[1]}, {packs[3]})
        port map (clk_audio, clk_rmii, host_sck, host_mosi, ctrl_cs_n, dsp_cs_n,
                  host_miso_out, host_miso_oe, bclk, clkin, dpi_miso, dpi_sel, dpi_sck, dpi_mosi,
                  reset_n, fs, from_dsp, to_dsp, dv, sync_a_rx, sync_b_rx, rxd,
                  txen, phy_reset, sync_a_tx, sync_a_de, sync_b_tx, sync_b_de, txd, observed);
{chr(10).join(assignments)}
end architecture;
""")
    (out / "board-pins.tsv").write_text("signal\tdirection\tball\tresource\n" + "".join(
        f"{name}\t{mode}\t{ball}\t{resource}\n" for name, (mode, ball, resource) in pins.items()))
    return pins


def xml(prefix, uri, tag, **attrs):
    return ET.Element(f"{prefix}:{tag}", {f"xmlns:{prefix}": uri, **attrs})


def write_xml(out, name, tree):
    ET.indent(tree)
    ET.ElementTree(tree).write(out / name, encoding="UTF-8", xml_declaration=True)


def emit_efinity(out, pins, sources):
    peri = xml("efxpt", "http://www.efinixinc.com/peri_design_db", "design_db",
               name=NAME, device_def=DEVICE, version=VERSION, db_version="20261009")
    banks = ET.SubElement(ET.SubElement(peri, "efxpt:device_info"), "efxpt:iobank_info")
    for bank in "1A 1B_1C 1D_1E 1F_1G 2A 2B 2C 2D 2E 2F 3D_TR_BR 4A 4B 4C 4D 4E 4F BL TL".split():
        ET.SubElement(banks, "efxpt:iobank", name=bank, iostd="1.2 V" if bank in ("BL", "TL") else "3.3 V LVTTL / LVCMOS")
    gpio = ET.SubElement(peri, "efxpt:gpio_info", device_def=DEVICE)
    for name, (mode, _, resource) in pins.items():
        io = ET.SubElement(gpio, "efxpt:gpio", name=name, gpio_def=resource,
                           mode={"in": "input", "out": "output", "inout": "inout"}[mode],
                           is_lvds_gpio=str("_RX" in resource or "_TX" in resource).lower(),
                           io_standard="3.3 V LVTTL / LVCMOS")
        if mode != "out":
            ET.SubElement(io, "efxpt:input_config", name=name + "_in" if mode == "inout" else name,
                          conn_type="normal", pull_option="weak pullup" if name in ("ctrl_cs_n", "dsp_cs_n") else "none",
                          is_register="false", ddio_type="none")
        if mode != "in":
            ET.SubElement(io, "efxpt:output_config", name=name + "_out" if mode == "inout" else name,
                          register_option="none", clock_name="", drive_strength="1", tied_option="none", ddio_type="none")
        if mode == "inout":
            ET.SubElement(io, "efxpt:output_enable_config", name=name + "_oe", is_register="false")
    ET.SubElement(gpio, "efxpt:global_unused_config", state="input with weak pullup")
    for kind in ("pll", "lvds", "jtag", "ddr"):
        ET.SubElement(peri, f"efxpt:{kind}_info")
    write_xml(out, NAME + ".peri.xml", peri)
    project = xml("efx", "http://www.efinixinc.com/enf_proj", "project", name=NAME, sw_version=VERSION)
    dev = ET.SubElement(project, "efx:device_info")
    for tag, name in (("family", "Trion"), ("device", DEVICE), ("timing_model", "C4")):
        ET.SubElement(dev, f"efx:{tag}", name=name)
    design = ET.SubElement(project, "efx:design_info", def_veri_version="verilog_2k", def_vhdl_version="vhdl_2008")
    ET.SubElement(design, "efx:top_module", name="wing_fpga")
    for source in sources:
        ET.SubElement(design, "efx:design_file", name=source, version="default", library="default")
    interface = ET.SubElement(project, "efx:interface_info")
    for tag in ("default_peri_file", "peri_file"):
        ET.SubElement(interface, "efx:" + tag, name=NAME + ".peri.xml")
    ET.SubElement(ET.SubElement(project, "efx:constraint_info"), "efx:sdc_file", name="wing.sdc")
    for stage, tool, options in (
        ("synthesis", "efx_map", (("work_dir", "work_syn", "string"), ("max_threads", "4", "integer"))),
        ("place_and_route", "efx_pnr", (("work_dir", "work_pnr", "string"), ("seed", "1", "integer"),
                                       ("max_threads", "4", "integer"))),
        ("bitstream_generation", "efx_pgm", (("mode", "passive", "option"), ("width", "1", "option"),
            ("generate_bit", "on", "bool"), ("generate_hexbin", "on", "bool"), ("bitstream_compression", "off", "bool"))),
    ):
        section = ET.SubElement(project, "efx:" + stage, tool_name=tool)
        for key, value, kind in options:
            ET.SubElement(section, "efx:param", name=key, value=value, value_type="e_" + kind)
    write_xml(out, NAME + ".xml", project)


def generate(out, count):
    aes_rtl = ROOT / "rtl/aes50/rtl"
    if (not (aes_rtl / "aes50_core.vhd").exists() or subprocess.check_output(
            ["git", "-C", str(aes_rtl.parent), "rev-parse", "HEAD"], text=True).strip() != AES50_REV):
        raise ValueError(f"initialize the pinned rtl/aes50 submodule ({AES50_REV})")
    subprocess.run(["git", "-C", str(aes_rtl.parent), "diff", "--exit-code", "HEAD", "--", "rtl"], check=True)
    out.mkdir(parents=True, exist_ok=False)
    build("wing", str(out), count)
    pins = emit_top(out, json.loads((out / "dsp_board_profile.json").read_text()), count)
    sources = [*(aes_rtl / (n + ".vhd") for n in (
        "aes50_pkg", "aes50_dpram", "aes50_fifo", "aes50_uart", "aes50_aux_uart_enc", "aes50_aux_uart_dec",
        "aes50_clk_audio", "aes50_link_ctrl", "aes50_tx_framer", "aes50_rx_deframer", "aes50_tdm_serdes", "aes50_core")),
        *(ROOT / f"rtl/core/{n}.vhd" for n in ("audioclk", "audiomatrix_ram", "audiomatrix_ram_read", "audiomatrix_ram_write",
           "tdm_multichan_rx", "tdm_multichan_tx", "routing_wb", "tdm_frame_io", "openaudio_core")),
        ROOT / "consoles/wing/dsp_spi.vhd", ROOT / "consoles/wing/wing_common.vhd"]
    for source in sources:
        shutil.copyfile(source, out / source.name)
    subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p2", "-i",
                    str(Path(__file__).with_name("aes50-wing-cdc.patch"))], cwd=out, check=True)
    names = [source.name for source in sources] + ["wing_fpga.vhd", "gateware/openaudio_soc.v"]
    emit_efinity(out, pins, names)
    (out / "sources.txt").write_text("\n".join(names) + "\n")
    sdc = Path(__file__).with_name("wing.sdc").read_text()
    if count:
        sdc += "\n" + Path(__file__).with_name("aes50.sdc").read_text()
    (out / "wing.sdc").write_text(sdc)


def bind(out):
    manifest = json.loads((out / "manifest.unbound.json").read_text())
    if manifest["benchmark_only"]:
        raise ValueError("benchmark profiles cannot be bound for the loader")
    if manifest.get("dsp_board_profile_sha256") != sha256(BOARD_PROFILE):
        raise ValueError("refusing a different or retired DSP board profile")
    path = out / "outflow" / manifest["bitstream"]["file"]
    raw = path.read_bytes()
    header = raw[:256].splitlines()
    if any(i not in header for i in (b"Family: Trion", b"Device: T55F484", b"Width: 1", b"Mode: passive")) or raw[256:260] != bytes.fromhex("168a2236"):
        raise ValueError("not a native T55F484 passive x1 image with intact preamble")
    for name, digest in {**manifest["csr_sha256"], "dsp_board_profile.json": manifest["dsp_board_profile_sha256"]}.items():
        if sha256(out / name) != digest:
            raise ValueError(f"input digest changed: {name}")
    manifest["bitstream"].update(sha256=sha256(path), size_bytes=len(raw))
    shutil.copyfile(path, out / path.name)
    (out / "manifest.candidate.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--aes50-ports", type=int, choices=range(4), default=1)
    parser.add_argument("--bind", action="store_true")
    args = parser.parse_args()
    if args.bind:
        bind(args.output.resolve())
    else:
        generate(args.output.resolve(), args.aes50_ports)
