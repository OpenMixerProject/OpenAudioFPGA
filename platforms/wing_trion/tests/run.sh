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
cat > reset.opt <<'EOF'
$ version 1.1
/tb_aes50_b_cdc/reset_check
/tb_aes50_b_cdc/dut/core_rst
/tb_aes50_b_cdc/dut/audio_rst
/tb_aes50_b_cdc/dut/bclk_rst
EOF
for phase in 3 11 17; do
    ghdl --elab-run --std=08 -frelaxed tb_aes50_b_cdc -gG_RMII_PHASE_NS="$phase" \
        --assert-level=error --ieee-asserts=disable --read-wave-opt=reset.opt --vcd=reset.vcd
    python3 "$test_dir/check_reset.py" reset.vcd
done

# Compare all four pin transitions (values and timestamps) with the pinned,
# unpatched core. Use a separate work directory for the upstream entities.
upstream="$test_dir/../../../rtl/aes50/rtl"
aes_sources=()
for source in "${sources[@]}"; do
    if [[ ${source##*/} == aes50_*.vhd ]]; then aes_sources+=("$upstream/${source##*/}"); fi
done
mkdir upstream
ghdl -a --std=08 -frelaxed --workdir=upstream "${aes_sources[@]}" "$test_dir/tb_aes50_sync_pins.vhd"
cat > sync-pins.opt <<'EOF'
$ version 1.1
/tb_aes50_sync_pins/tx
/tb_aes50_sync_pins/de
EOF
for slave in false true; do
    for workdir in . upstream; do
        ghdl --elab-run --std=08 -frelaxed --workdir="$workdir" tb_aes50_sync_pins -gG_SLAVE="$slave" \
            --assert-level=error --ieee-asserts=disable --read-wave-opt=sync-pins.opt --vcd="$workdir/pins.vcd"
        sed '1,/^\$scope /d' "$workdir/pins.vcd" > "$workdir/pins.trace"
    done
    diff -u upstream/pins.trace pins.trace
    echo "PASS pins match upstream at every recorded transition (slave=$slave)"
done
