"""Verify the actual FIT, not just the build-tree inputs."""
import csv
import gzip
import hashlib
import json
import re
import stat
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path
from xml.etree import ElementTree as ET

from bind_loader import generate


def check(condition, what):
    if not condition:
        raise SystemExit(f"FAIL: {what}")


def fdt(path, node, key=None, fmt="s"):
    args = ["-l", str(path), node] if key is None else ["-t", fmt, str(path), node, key]
    return subprocess.check_output(["fdtget", *args], text=True).strip()


def archive(blob):
    data = gzip.decompress(blob)
    entries = {}
    off = 0
    while off + 110 <= len(data):
        header = data[off:off+110]
        check(header.startswith(b"070701"), "initramfs newc magic")
        _, mode, uid, gid, _, _, size, _, _, major, minor, namesize, _ = (
            int(header[i:i+8], 16) for i in range(6,110,8))
        off += 110
        name = data[off:off+namesize-1].decode("ascii")
        off = (off + namesize + 3) & ~3
        if name == "TRAILER!!!":
            check(not any(data[off:]), "no second archive")
            return entries
        check(uid == gid == 0 and name not in entries and off + size <= len(data), "root-owned unique archive entries")
        entries[name] = (mode, major, minor, data[off:off+size])
        off = (off + size + 3) & ~3
    raise SystemExit("FAIL: missing initramfs trailer")


def verify_dtb(path):
    spi = fdt(path, "/aliases", "spi1")
    check(spi.endswith("/spi@200c000") and fdt(path, spi, "status") == "okay", "ECSPI2 alias")
    check(set(fdt(path, spi).splitlines()) == {"config@0", "fpga@1"}, "exactly two SPI children")
    for child, index, compatible in (("config@0", "0", "rohm,dh2228fv"), ("fpga@1", "1", "openmixer,wing-spibone")):
        node = f"{spi}/{child}"
        check(fdt(path, node, "compatible") == compatible and fdt(path, node, "reg", "x") == index and
              fdt(path, node, "spi-max-frequency", "x") == "1e8480" and not fdt(path, node), f"SPI binding {child}")
    soc = "/soc/bus@2000000"
    mux = soc + "/pinctrl@20e0000"
    gpio2, gpio4 = soc + "/gpio@20a0000", soc + "/gpio@20a8000"
    cs = fdt(path, gpio2, "phandle", "x")
    check(fdt(path, spi, "cs-gpios", "x") == f"{cs} 1a 1 {cs} 1b 1", "GPIO2_26/27 active-low only")
    groups = {"ecspi2grp": "13c 50c 7f4 2 2 1b0b0 140 510 7fc 2 2 1b0b0 1d8 5a8 7f8 2 2 1b0b0",
              "t55csgrp": "1dc 5ac 0 5 0 1b0b0 1d4 5a4 0 5 0 1b0b0",
              "fpgactrlgrp": "124 4f4 0 5 0 1b0b0 fc 410 0 5 0 4001b008"}
    handles = []
    for name, pads in groups.items():
        node = f"{mux}/{name}"
        check(fdt(path, node, "fsl,pins", "x") == pads, f"exact pad mux {name}")
        handles.append(fdt(path, node, "phandle", "x"))
    check(fdt(path, spi, "pinctrl-0", "x").split() == handles, "only expected ECSPI2 pad groups")
    # fdtget -t s strips empty members in some implementations; use bytes for offsets.
    for node, index, expected in ((gpio2, 17, b"T55_CRESET_N"), (gpio4, 26, b"T55_CDONE")):
        names = bytes(int(x,16) for x in fdt(path, node, "gpio-line-names", "bx").split()).split(b"\0")
        check(names[index] == expected and names.count(expected) == 1, f"exact named GPIO {expected!r}")
    for alias in ("spi0", "spi2", "spi3", "i2c0", "i2c1", "i2c2", "i2c3", "ethernet0",
                  "usb1", "usb2", "usb3", "mmc0", "mmc1", "mmc2", "mmc3"):
        check(fdt(path, fdt(path, "/aliases", alias), "status") == "disabled", f"{alias} disabled")
    check(fdt(path, "/soc/bus@2100000/usb@2184000", "dr_mode") == "peripheral", "USB peripheral")


def verify_pads(stage):
    with (stage / "board-pins.tsv").open() as pinfile:
        pins = {r["ball"]: r for r in csv.DictReader(pinfile, delimiter="\t")}
    rep = stage / "outflow/wing-fpga.pinout.csv"
    rows = list(csv.DictReader(l for l in rep.read_text().splitlines() if l and not l.startswith("#")))
    check(len(rows) == len({r["Pin Number"] for r in rows}) == 484, "complete T55F484 inventory")
    fixed = {"W9", "U6", "T4", "AA12", "U12", "B14", "A2"}
    check({ball for ball, spec in pins.items() if spec["mode"] == "out"} == fixed, "exact isolation pads")
    check({ball for ball, spec in pins.items() if spec["mode"] == "inout"} == {"V1"}, "exact MISO pad")
    for r in rows:
        ball, name = r["Pin Number"], r["Signal Name"]
        if ball in pins:
            spec = pins[ball]
            check(name.split(".")[0] == spec["signal"] and
                  r["Direction"] == {"in": "Input", "out": "Output", "inout": "Bidirectional"}[spec["mode"]] and
                  r["I/O Bank Voltage"] == "3.3 V", f"pad {ball}")
        elif "User IO" in r["Function"]:
            check(not name and r["Direction"] in ("", "Input"), f"unused pad does not drive {ball}")
    peri = ET.parse(stage / "wing-fpga.peri.xml")
    p = {"p": "http://www.efinixinc.com/peri_design_db"}
    for name in ("a9_no_drive", "sync_b_a_observe", "sync_b_b_observe"):
        gpio = peri.find(f".//p:gpio[@name='{name}']", p)
        check(gpio.get("mode") == "input" and gpio.find("p:input_config", p).get("pull_option") == "none",
              f"pure input, no pull or OE: {name}")
    check(peri.find(".//p:global_unused_config", p).get("state") == "input with weak pullup",
          "documented weak bias on unassigned pads")
    print("PASS: all 484 pins inventoried, only isolation constants and SS1 MISO drive user I/O")


def verify(fit, stage, diag):
    base = fit.parent
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        check(fdt(fit, "/configurations", "default") == "wing", "FIT default configuration")
        check(set(fdt(fit, "/images").splitlines()) == {"kernel", "fdt", "ramdisk"}, "exact FIT images")
        parts = {}
        for i, (name, load, kind) in enumerate((("kernel", "12000000", "kernel"), ("fdt", "13000000", "flat_dt"),
                                                ("ramdisk", "13800000", "ramdisk"))):
            node = f"/images/{name}"
            check(fdt(fit, "/configurations/wing", name) == name and fdt(fit, node, "type") == kind and
                  fdt(fit, node, "load", "x") == load, f"FIT {name} binding")
            path = tmp / name
            subprocess.run(["dumpimage", "-T", "flat_dt", "-p", str(i), "-o", path, fit],
                           check=True, stdout=subprocess.DEVNULL)
            parts[name] = path.read_bytes()
            check(fdt(fit, node + "/hash-1", "algo") == "crc32" and
                  int(fdt(fit, node + "/hash-1", "value", "x"), 16) == zlib.crc32(parts[name]), f"FIT {name} CRC")
        verify_dtb(tmp / "fdt")
        check(parts["fdt"] == (base / "bench.dtb").read_bytes(), "FIT DTB sidecar")
        kernel = parts["kernel"]
        check(kernel[36:40] == bytes.fromhex("18286f01"), "ARM zImage")
        for match in re.finditer(b"\x1f\x8b\x08", kernel):
            try:
                raw = zlib.decompress(kernel[match.start():], wbits=31)
            except zlib.error:
                continue
            offset = raw.find(b"IKCFG_ST\x1f\x8b\x08")
            if offset >= 0:
                config = set(zlib.decompress(raw[offset+8:], wbits=31).decode().splitlines())
                break
        else:
            raise SystemExit("FAIL: missing embedded Linux config")
        required = "SPI_IMX SPIBONE SPI_SPIDEV GPIO_CDEV CRYPTO_USER_API_HASH CRYPTO_SHA256 TMPFS DEVTMPFS USB_G_SERIAL USB_CHIPIDEA_UDC"
        check(all(f"CONFIG_{name}=y" in config for name in required.split()), "required built-in kernel features")
        check(not any(f"CONFIG_{n}={v}" in config for n in ("DEVMEM", "DEVKMEM", "MODULES") for v in "ym"),
              "no devmem/modules")
        blob = parts["ramdisk"]
        check(blob == (base / "initramfs.cpio.gz").read_bytes(), "FIT initramfs sidecar")
        entries = archive(blob)
        bundle = "usr/share/wing-fabric-id"
        applets = "sh cat mount readlink sleep stty timeout tr uname".split()
        here = Path(__file__).resolve().parent
        files = {"init": (0o755, here / "init"), "bin/wing-t55-diag": (0o755, diag), "bin/wing-fabric-id": (0o755, base / "loader"),
                 f"{bundle}/manifest.json": (0o444, stage / "manifest.json"),
                 f"{bundle}/wing-fpga.hex.bin": (0o444, stage / "outflow/wing-fpga.hex.bin")}
        dirs = set("bin dev proc sys run etc usr usr/share".split()) | {bundle}
        check(set(entries) == dirs | set(files) | {f"bin/{a}" for a in applets} |
              {"dev/console", "dev/null", "bin/busybox", "etc/wing-diag-build"}, "strict initramfs allowlist")
        for name in dirs:
            check(stat.S_ISDIR(entries[name][0]), f"directory {name}")
        for name, (mode, path) in files.items():
            check(entries[name][0] == stat.S_IFREG | mode and entries[name][3] == path.read_bytes(), f"bound file {name}")
        for name in applets:
            mode, _, _, data = entries[f"bin/{name}"]
            check(stat.S_ISLNK(mode) and data.rstrip(b"\0") == b"busybox", f"applet {name}")
        for name, dev in (("dev/console", (5, 1)), ("dev/null", (1, 3))):
            check(stat.S_ISCHR(entries[name][0]) and entries[name][1:3] == dev, f"character device {name}")
        for name in ("bin/busybox", "bin/wing-fabric-id"):
            mode, _, _, elf = entries[name]
            check(mode == stat.S_IFREG | 0o755 and elf[:6] == b"\x7fELF\x01\x01" and elf[18:20] == b"\x28\x00",
                  f"ARM executable {name}")
        packaged = tmp / "bundle"
        packaged.mkdir()
        loader = entries["bin/wing-fabric-id"][3]
        for name in ("manifest.json", "wing-fpga.hex.bin"):
            data = entries[f"{bundle}/{name}"][3]
            (packaged / name).write_bytes(data)
            check(hashlib.sha256(data).hexdigest().encode() in loader, f"compiled digest for {name}")
        check(generate(packaged) == (base / "bound.h").read_text(), "compiled bind specification agrees with FIT")
        build = entries["etc/wing-diag-build"][3].decode().strip()
        check(re.fullmatch("[0-9a-f]{64}", build), "Linux build ID")
        print(f"PASS: actual FIT/kernel/DTB/strict initramfs; linux_build={build}")
        print(f"SHA256: {hashlib.sha256(fit.read_bytes()).hexdigest()}  {fit.name}")


if __name__ == "__main__":
    fit, stage, reporter = map(Path, sys.argv[1:])
    verify_pads(stage)
    manifest = json.loads((stage / "manifest.json").read_bytes())
    for name, digest in {**manifest["efinity_inputs"], "board-pins.tsv": manifest["pins_sha256"]}.items():
        check(hashlib.sha256((stage / name).read_bytes()).hexdigest() == digest, f"gateware input digest {name}")
    verify(fit, stage, reporter)
