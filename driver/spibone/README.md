# spibone — LiteX SPIBone bus driver

Linux driver for a LiteX **SPIBone** bridge (4-wire SPI → Wishbone). It owns the
SPI device and is the **only Wishbone master** on the link; everything else uses
it:

- **client drivers** in the kernel: one platform device per available child node
  of the spibone DT node, e.g. the AES67 core (`aes67,eth`, driver `aes67_eth`).
  API: `spibone.h` (single word and burst access, bus lock).
- **userspace** through `/dev/spiboneN` (`spibone_uapi.h`): peek / poke / bursts by
  byte address (the addresses of the LiteX `csr.csv`), used by `aes67d` /
  `aes67cfg` (`--kernel /dev/spibone0`) and OpenX32's OMC.
- **FPGA configuration** over the same SPI link: raw SPI messages
  (`struct spi_ioc_transfer` as for spidev; the chip select stays asserted for
  the whole message).

The wire protocol is the one of `litex/soc/cores/spi/spi_bone.py` plus the burst
commands of the fork in OpenAudioFPGA's `litex_soc/spi_bone.py`. SPIBone resets on a deasserted
chip select, so the chip select has to stay asserted for a whole message (a GPIO
chip select, or a native one that does so).

## Bus state

| State     | Wishbone access | Raw SPI messages | Client devices |
|-----------|-----------------|------------------|----------------|
| `offline` | no (`ENODEV`)   | no               | none           |
| `config`  | no (`ENODEV`)   | yes              | none           |
| `online`  | yes             | no               | created        |

The bus starts `offline` (or `online` with the DT property
`litex,online-at-probe`, for an FPGA that configures itself from flash). Leaving
`online` removes the client devices first. Set it with `SPIBONE_IOC_SET_STATE` or
`/sys/bus/spi/devices/<dev>/state` (`offline` / `config` / `online`).

A typical host that configures the FPGA (OpenX32's OMC):
`config` → raw messages with the bitstream → `online` (on success) / `offline`.

## Device tree

```dts
fpga@0 {
    compatible = "litex,spibone";
    reg = <0>;                      /* chip select */
    spi-max-frequency = <8000000>;  /* spibone samples SCLK with its sys_clk */
    #address-cells = <1>;
    #size-cells = <1>;
    /* litex,online-at-probe; */

    aes67@90000000 {                /* a client device while the bus is online */
        compatible = "aes67,eth";
        reg = <0x90000000 0x20000>; /* its Wishbone window (read by the client) */
    };
};
```

The child `reg` is a Wishbone window: it cannot be translated through the SPI bus,
so the bus driver creates the client devices itself and the clients read `reg`.

## Build

```sh
make                                   # against the running kernel
make KDIR=... ARCH=... CROSS_COMPILE=...
```

Client drivers built out of tree link against its symbols
(`KBUILD_EXTRA_SYMBOLS=<this directory>/Module.symvers`) and include `spibone.h`.
OpenX32 builds the driver into its kernel (`files/spibone/build.sh`, always) and
`aes67_eth` on top of it (`files/aes67/build.sh kernel`, with AES67).

This driver came from the AES67 project (`driver/spibone`); OpenAudioFPGA is its
home now, the AES67 copy is still there until that project is switched over.

## Module parameters

- `spi_hz` (default 0 = `spi-max-frequency`): SPI clock of the Wishbone
  transactions. SPIBone oversamples SCLK with its sys_clk: keep it at or below
  sys_clk / 12. Raw messages carry their own rate per transfer.
- `use_burst` (default 1): use the burst commands `0x02` / `0x03`; 0 for gateware
  without burst support (one transaction per word).

## License

GPL-2.0-or-later (`spibone_uapi.h` with the Linux-syscall-note, so userspace may
include it): GPL-2.0 inside the Linux kernel, which is GPL-2.0-only, and GPL-3.0
together with the rest of OpenAudioFPGA.
