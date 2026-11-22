#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
stage=$(cd "${1:?Pass a WING project directory from generate.py}" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
sources=()
while IFS= read -r source; do
    if [[ $source == *.vhd ]]; then sources+=("$stage/$source"); fi
done < "$stage/sources.txt"
ghdl -a --std=08 -frelaxed "${sources[@]}" "$test_dir"/tb_*.vhd
for bench in tb_dsp_spi tb_routing_wb tb_sport_frame; do
    ghdl --elab-run --std=08 -frelaxed "$bench" --assert-level=error --ieee-asserts=disable
done
for phase in 3 11 17; do
    ghdl --elab-run --std=08 -frelaxed tb_aes50_b_cdc -gG_RMII_PHASE_NS="$phase" \
        --assert-level=error --ieee-asserts=disable
done
