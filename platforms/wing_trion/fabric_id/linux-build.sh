#!/usr/bin/env bash
# In the existing wing-usb-console-builder:trixie image, no network/device access.
set -euo pipefail
umask 022
export LC_ALL=C TZ=UTC ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
export SOURCE_DATE_EPOCH=1767225600 KBUILD_BUILD_USER=openwing KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH")"
bench=/oa/platforms/wing_trion/fabric_id
diag=/openwing/tools/wing-t55-diag
cd /work

if [[ $1 == kernel ]]; then
    for name in busybox-1.38.0.tar.bz2 linux-6.6.30.tar.xz; do
        (cd /archives; grep "  $name\$" "$diag/sources.sha256" | sha256sum --strict -c -)
        tar -xf "/archives/$name"
    done
    dts=linux-6.6.30/arch/arm/boot/dts/nxp/imx
    cp "$diag/wing-t55-diag.dts" /openwing/configs/imx6dl-wing-t55-{bringup,spibone}.dtsi "$dts/"
    cp "$bench/bench.dts" "$dts/wing-t55-fabric-id.dts"
    spi=linux-6.6.30/drivers/spi
    mkdir "$spi/spibone" kernel
    cp /oa/driver/spibone/*.{c,h} /openwing/configs/spibone/{Kbuild,Kconfig} "$spi/spibone/"
    printf '\nCFLAGS_spibone.o += -DWING_FABRIC_ID_ONLY\n' >> "$spi/spibone/Kbuild"
    printf '\nobj-$(CONFIG_SPIBONE) += spibone/\n' >> "$spi/Makefile"
    printf '\nsource "drivers/spi/spibone/Kconfig"\n' >> "$spi/Kconfig"
    cp /openwing/configs/config_linux kernel/.config
    linux-6.6.30/scripts/config --file kernel/.config \
        --enable SPI_SPIDEV --enable SPIBONE --enable CRYPTO_USER_API_HASH \
        --disable DEVMEM --disable DEVKMEM --disable MODULES
    make -C linux-6.6.30 O=/work/kernel olddefconfig
    make -C linux-6.6.30 O=/work/kernel -j"$(nproc)" zImage nxp/imx/wing-t55-fabric-id.dtb

    cd busybox-1.38.0
    make allnoconfig
    { cat "$diag/busybox.config"; printf '%s\n' CONFIG_STTY=y; } > /work/busybox.selected
    awk -F '[ =]' 'NR==FNR { enable[$1]=$0; next }
        !($1 in enable) && !($1 == "#" && $2 in enable) { print }
        END { for (name in enable) print enable[name] }' /work/busybox.selected .config > .config.bench
    mv .config.bench .config
    make oldconfig </dev/null
    while read -r line; do grep -Fxq "$line" .config; done < /work/busybox.selected
    make -j"$(nproc)"
    exit
fi
[[ $1 == package ]]
install -d rootfs/{bin,dev,proc,sys,run,etc,usr/share/wing-fabric-id}
bundle=rootfs/usr/share/wing-fabric-id
install -m 0444 /gateware/manifest.json /gateware/outflow/wing-fpga.hex.bin "$bundle/"
python3 -B "$bench/bind_loader.py" "$bundle" > bound.h
arm-linux-gnueabihf-gcc -std=c11 -O2 -Wall -Wextra -Werror -static \
    -I/work -I/oa/driver/spibone "$bench/loader.c" -o loader
install -m 0755 loader rootfs/bin/wing-fabric-id
install -m 0755 busybox-1.38.0/busybox rootfs/bin/busybox
for applet in sh cat mount readlink sleep stty timeout tr uname; do ln -s busybox "rootfs/bin/$applet"; done
install -m 0755 "$bench/init" rootfs/init
install -m 0755 "$diag/wing-t55-diag" rootfs/bin/wing-t55-diag
cp kernel/arch/arm/boot/zImage .
cp kernel/arch/arm/boot/dts/nxp/imx/wing-t55-fabric-id.dtb bench.dtb
sha256sum zImage bench.dtb loader "$bundle/manifest.json" "$bundle/wing-fpga.hex.bin" \
    rootfs/init rootfs/bin/busybox rootfs/bin/wing-t55-diag | sha256sum | cut -d ' ' -f 1 >rootfs/etc/wing-diag-build
(
    cd rootfs
    find . -mindepth 1 -type d | sort | sed 's/^\.\(.*\)/dir \1 0755 0 0/'
    find . -type f | sort | while read -r file; do
        printf 'file %s %s 0%s 0 0\n' "${file#.}" "$file" "$(stat -c %a "$file")"
    done
    find . -type l | sort | while read -r file; do
        printf 'slink %s %s 0777 0 0\n' "${file#.}" "$(readlink "$file")"
    done
    echo 'nod /dev/console 0600 0 0 c 5 1'
    echo 'nod /dev/null 0666 0 0 c 1 3'
) > initramfs.list
(cd rootfs && ../kernel/usr/gen_init_cpio -t "$SOURCE_DATE_EPOCH" ../initramfs.list) | gzip -n9 > initramfs.cpio.gz
cp "$bench/bench.its" .
mkimage -f bench.its wing-t55-fabric-id.itb
cp wing-t55-fabric-id.itb initramfs.cpio.gz bench.dtb bound.h loader kernel/.config /out/
