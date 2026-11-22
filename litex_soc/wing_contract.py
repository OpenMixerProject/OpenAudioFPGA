"""Export the WING userspace contract from the CSR map actually emitted by LiteX."""
import csv
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WING_MAGIC = 0x57494E47
WING_ABI = 0x00020000
WING_CAPABILITIES = 0x0F
CSR_FILES = ("csr.csv", "csr.json", "software/include/generated/csr.h")
BOARD_PROFILE = ROOT / "consoles/wing/profile-tdm16.json"
WING_REGISTERS = (
    "wing_magic", "wing_abi_version", "wing_build_id", "wing_capabilities", "wing_status",
    "wing_dsp_reset_release", "wing_dsp_audio_enable", "wing_dsp_audio_valid",
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest(aes50_ports):
    digest = hashlib.sha256()
    digest.update(bytes([aes50_ports]))
    for directory, pattern in (("rtl/core", "*.vhd"), ("rtl/aes50/rtl", "*.vhd"),
                               ("consoles/wing", "*"), ("platforms/wing_trion", "*"),
                               ("litex_soc", "*.py"), ("litex_soc", "requirements.txt"),
                               (".", ".gitmodules")):
        for path in sorted((ROOT / directory).glob(pattern)):
            if path.is_file():
                digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0")
                digest.update(bytes.fromhex(sha256(path)))
    for path in ("rtl/aes50", "ext/AES67"):
        digest.update(subprocess.check_output(["git", "ls-files", "-s", path], cwd=ROOT))
    return digest.hexdigest()


def export_wing(output, digest, aes50_ports=1):
    out = Path(output)
    with (out / "csr.csv").open(newline="") as f:
        rows = {row[1]: row for row in csv.reader(f) if row and row[0] in ("csr_register", "memory_region")}
    registers = []
    for index, name in enumerate(WING_REGISTERS):
        _, _, offset, size, mode = rows[name]
        # Stable bootstrap addresses also used by driver/spibone/spibone.c.
        assert int(size) == 1 and int(offset, 0) == 0x1800 + 4 * index
        entry = dict(name=name, offset=int(offset, 0), width=32, access=mode.upper())
        if index < 4:
            entry["value"] = (WING_MAGIC, WING_ABI, int(digest[:8], 16), capabilities(aes50_ports))[index]
        if name == "wing_status":
            entry["bits"] = {"ready": 0}
            if aes50_ports:
                entry["bits"]["aes50_b_link"] = 2
        if mode == "rw":
            entry.update(reset=0, write_mask=11 if name == "wing_dsp_reset_release" else 15)
        registers.append(entry)
    manifest = dict(
        schema_version=2, target="wing-compact-t55f484-fork", device="T55F484", toolchain="Efinity 2026.1.132",
        abi_version=WING_ABI, magic=WING_MAGIC, build_id=int(digest[:8], 16), source_sha256=digest,
        feature_flags=capabilities(aes50_ports), num_inputs=768, num_outputs=768,
        num_aes50_ports=aes50_ports, aes50_ports=[dict(port="B", rx=48, tx=48)] if aes50_ports else [],
        benchmark_only=aes50_ports != 1, audio_data_width=32,
        board_qualification="required-before-dsp-fs", fabric_clock_hz=49152000, rmii_clock_hz=50000000,
        registers=registers, routing=dict(base=int(rows["routing"][2], 0), count=768, stride=4, selector_width=10, off=0),
        transport=dict(device="/dev/spibone0", compatible="openmixer,wing-spibone", chip_select=1, mode=0,
                       max_hz=2000000, protocol="litex-spibone-burst", address_unit="byte"),
        csr_sha256={path: sha256(out / path) for path in CSR_FILES},
        bitstream=dict(file="wing-fpga.hex.bin", format="efinity-passive-spi-1x-hex-bin"),
    )
    profile_path = BOARD_PROFILE
    profile = json.loads(profile_path.read_text())
    manifest["audio"] = {k: v for k, v in profile.items() if k != "dsp"}
    manifest["dsp_board_profile_sha256"] = sha256(profile_path)
    shutil.copyfile(profile_path, out / "dsp_board_profile.json")
    channels = {"sources": [], "destinations": []}
    for key, direction, first in (("sources", "tx", 1), ("destinations", "rx", 0)):
        for dsp in profile["dsp"]:
            assert dsp["slots_used"] <= len(dsp[direction]) * profile["slots"]
            for slot_id in range(dsp["slots_used"]):
                lane, slot = divmod(slot_id, profile["slots"])
                channels[key].append(dict(id=dsp["first_id"] + slot_id + first, dsp=dsp["id"], lane=lane,
                                          slot=slot, slot_id=slot_id, dai=dsp[direction][lane][0]))
        if aes50_ports:
            channels[key].extend(dict(id=372 + channel + first, aes50="B", channel=channel + 1)
                                 for channel in range(48))
    manifest["channels"] = channels
    (out / "manifest.unbound.json").write_text(json.dumps(manifest, indent=2) + "\n")


def capabilities(aes50_ports):
    return WING_CAPABILITIES if aes50_ports == 1 else (WING_CAPABILITIES & ~8) | (1 << 31)
