#!/usr/bin/env bash
# Linux build machine only; mock intercepts every open/glob/ioctl for board paths.
set -euo pipefail
bench=$(realpath "$(dirname "$0")")
gateware=$(realpath "$1")
export TEST_FIXTURE
TEST_FIXTURE=$(mktemp -d /dev/shm/wing-id-test.XXXXXX)
execdir=$(mktemp -d)
trap 'rm -rf -- "$TEST_FIXTURE" "$execdir"' EXIT
runfs=$TEST_FIXTURE/run
bundle=$TEST_FIXTURE/usr/share/wing-fabric-id
mkdir -p "$bundle" "$runfs"
install -m 0444 "$gateware/manifest.json" "$gateware/outflow/wing-fpga.hex.bin" "$bundle/"
if [[ $# == 2 ]]; then
    mock=$(realpath "$2")
else
    python3 -B "$bench/bind_loader.py" "$bundle" > "$execdir/bound.h"
    mock=$execdir/test-loader
    gcc -std=c11 -O2 -Wall -Wextra -Werror -I"$execdir" -I"$bench/../../../driver/spibone" "$bench/mock_loader.c" \
        -Wl,--wrap=open,--wrap=glob,--wrap=ioctl -o "$mock"
fi
ack='LOAD FABRIC ID: RAM, ISOLATION AND R2 VERIFIED'
run() {
    local name=$1 result=$2 expectation=$3 counts=$4 output rc=0
    shift 4
    rm -f "$runfs/wing-fabric-id.attempt"
    touch "$runfs/omc-wing-fpga.json"
    output=$(TEST_CASE=$name "$mock" "$@") || rc=$?
    printf '\n%s: %s\n' "$name" "$output"
    [[ $rc == "$result" && $output == *"$expectation"* && $output == *"$counts"* ]]
    if [[ $name != no-approval ]]; then test ! -e "$runfs/omc-wing-fpga.json"; fi
}
run no-approval 1 'stage=manual-approval offline=untouched' 'probes=0 reads=0'
run pass 0 'result=pass cdone=1 offline=yes' 'probes=1 reads=5' "$ack"
run no-done 1 'stage=cdone-not-high-after-upload offline=yes' 'probes=0 reads=0' "$ack"
run early-done 1 'stage=cdone-high-before-upload offline=yes' 'complete_bytes=0 probes=0 reads=0' "$ack"
run short 1 'stage=short-or-failed-upload offline=yes' 'complete_bytes=0 probes=0 reads=0' "$ack"
run driver-denies 1 'stage=ss1-enable-or-identity offline=yes' 'probes=1 reads=0' "$ack"
run wrong-build 1 'stage=build offline=yes' 'probes=1 reads=3' "$ack"
run drop-done 1 'stage=cdone-lost offline=yes' 'probes=1 reads=5' "$ack"
printf x | dd of="$bundle/manifest.json" bs=1 seek=2 conv=notrunc status=none
run manifest-tamper 1 'stage=manifest.json offline=untouched' 'complete_bytes=0 probes=0 reads=0' "$ack"
install -m 0444 "$gateware/manifest.json" "$bundle/"
printf x | dd of="$bundle/wing-fpga.hex.bin" bs=1 seek=2000 conv=notrunc status=none
run image-tamper 1 'stage=wing-fpga.hex.bin offline=untouched' 'complete_bytes=0 probes=0 reads=0' "$ack"
test -e "$runfs/wing-fabric-id.attempt"
if TEST_CASE=repeat "$mock" "$ack"; then exit 1; fi
echo 'PASS: positive readback and negative controls with real SHA-256; no product receipt'
