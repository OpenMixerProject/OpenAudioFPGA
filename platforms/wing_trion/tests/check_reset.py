#!/usr/bin/env python3
"""Compare bench checkpoints with reset signals from the uninstrumented DUT."""
import sys

RESETS = ("core_rst", "audio_rst", "bclk_rst")
CHECKPOINTS = (
    "normal operation", "assertion with both clocks stopped", "core release with both clocks stopped",
    "first audio rising edge", "first audio falling edge", "second audio rising edge",
    "audio running with BCLK still stopped", "first BCLK rising edge", "first BCLK falling edge",
    "second BCLK rising edge",
)

with open(sys.argv[1]) as wave:
    ids = {}
    for line in wave:
        if line.startswith("$var "):
            _, _, _, code, name, *_ = line.split()
            ids[name.split("[")[0]] = code
        elif line.startswith("$enddefinitions "):
            break
    probe = ids["reset_check"]
    reset_ids = [ids[name] for name in RESETS]
    values = {}
    checked = 0
    for line in wave:
        if line.startswith("b"):
            vector, code = line.split()
            if code == probe and set(vector[1:]) <= {"0", "1"}:
                # The bench strobes after the RTL has settled.
                mismatches = [f"{name} expected {expected}, got {values.get(reset_id)}"
                              for name, reset_id, expected in zip(RESETS, reset_ids, vector[1:].zfill(4)[1:])
                              if values.get(reset_id) != expected]
                if mismatches:
                    raise SystemExit(f"{CHECKPOINTS[checked]}: {', '.join(mismatches)}")
                checked += 1
        elif line[0] in "01xXzZ":
            values[line[1:].strip()] = line[0]
    if checked != len(CHECKPOINTS):
        raise SystemExit(f"expected {len(CHECKPOINTS)} reset checkpoints, checked {checked}")
    print("PASS stopped audio/BCLK reset assertion, retention and two-edge release")
