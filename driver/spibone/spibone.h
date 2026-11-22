/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * LiteX SPIBone bus driver: in-kernel API for client drivers.
 *
 * The spibone driver owns the SPI device of a LiteX SPIBone bridge (4-wire
 * SPI -> Wishbone) and is the only Wishbone master on that link. Client drivers
 * are platform devices created from the child nodes of the spibone DT node
 * (e.g. the AES67 core: aes67@90000000 { compatible = "aes67,eth"; reg = <base
 * size>; }); they reach their registers through the functions below.
 *
 * Addresses are byte addresses of the Wishbone bus (as in the LiteX csr.csv),
 * values are 32-bit words.
 *
 * The bus is "online" only while the FPGA runs a gateware with the bridge. The
 * children exist only while the bus is online: they are created when it goes
 * online and removed before it leaves that state (FPGA (re)configuration). Every
 * access returns -ENODEV while the bus is not online.
 *
 * Locking: the plain functions take the bus lock for one transaction; the
 * _locked variants need spibone_lock() and allow atomic multi-word sequences.
 * All functions sleep (SPI).
 */
#ifndef SPIBONE_H
#define SPIBONE_H

#include <linux/device.h>
#include <linux/types.h>

struct spibone;

/* The bus of a client device (its parent). NULL if the parent is no spibone. */
struct spibone *spibone_get(struct device *child);

void spibone_lock(struct spibone *sb);
void spibone_unlock(struct spibone *sb);
void spibone_assert_held(struct spibone *sb);
bool spibone_online(struct spibone *sb);

int spibone_read_locked(struct spibone *sb, u32 addr, u32 *val);
int spibone_write_locked(struct spibone *sb, u32 addr, u32 val);
int spibone_read(struct spibone *sb, u32 addr, u32 *val);
int spibone_write(struct spibone *sb, u32 addr, u32 val);

/*
 * n consecutive words from / to addr (word-incrementing), streamed with the
 * burst commands of the SPIBone fork (0x02 / 0x03) and chunked internally; with
 * the module parameter use_burst=0 one single-word transaction per word.
 */
int spibone_burst_read_locked(struct spibone *sb, u32 addr, u32 *words, unsigned int n);
int spibone_burst_write_locked(struct spibone *sb, u32 addr, const u32 *words, unsigned int n);

#endif /* SPIBONE_H */
