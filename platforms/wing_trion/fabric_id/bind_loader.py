"""Pin the diagnostic manifest, native binary and readback expectations in the loader."""
import hashlib
import json
import sys
from pathlib import Path


def generate(bundle):
    inputs = {name: (bundle / name).read_bytes() for name in ("manifest.json", "wing-fpga.hex.bin")}
    m = json.loads(inputs["manifest.json"])
    raw = inputs["wing-fpga.hex.bin"]
    if (m["profile"] != "wing-compact-t55-fabric-id-v1" or
        m["source_base"] != "925cc382a2c65affa7866dc313d598a187b6d0d7" or
        m["fabric_clock_hz"] != 49_152_000 or m["rmii_clock_required"] is not False or
        m["configuration"] != dict(device="/dev/spidev1.0", no_cs=True, width=1, offset=0) or
        m["transport"] != dict(device="/dev/spibone0", compatible="openmixer,wing-spibone",
                               chip_select=1, mode=0, max_hz=2000000, address_unit="byte") or
        m["bitstream"] != dict(file="wing-fpga.hex.bin", size=len(raw), sha256=hashlib.sha256(raw).hexdigest()) or
        not {b"Family: Trion", b"Device: T55F484", b"Width: 1", b"Mode: passive"} <= set(raw[:256].splitlines()) or
        raw[256:260] != bytes.fromhex("168a2236")):
        raise ValueError("not the bound native T55 read-only diagnosis profile")
    digest = hashlib.sha256(json.dumps({"base": m["source_base"], "inputs": m["source_inputs"]},
                                      sort_keys=True).encode()).hexdigest()
    build = m["build_id"]
    if digest != m["source_sha256"] or build != int(digest[:8], 16):
        raise ValueError("invalid source identity")
    regs = [(0x1800, "magic", 0x57494e47), (0x1804, "abi", 0x00020000), (0x1808, "build", build),
            (0x180c, "caps", 0), (0x1810, "status", 1)]
    if m["registers"] != [dict(address=a, name=n, value=v, access="RO") for a, n, v in regs]:
        raise ValueError("unexpected register contract")
    lines = [f"#define FABRIC_BUILD_ID 0x{build:08x}u", "static const struct input inputs[] = {"]
    lines += [f'    {{"{name}", {len(data)}, "{hashlib.sha256(data).hexdigest()}"}},' for name, data in inputs.items()]
    lines += ["};", "static const struct { uint32_t addr, value; const char *name; } identity[] = {"]
    lines += [f'    {{0x{a:04x}u, 0x{v:08x}u, "{n}"}},' for a, n, v in regs]
    return "\n".join([*lines, "};", ""])


if __name__ == "__main__":
    sys.stdout.write(generate(Path(sys.argv[1])))
