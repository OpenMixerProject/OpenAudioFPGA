/* hw_spibone.h - OpenAudioFPGA /dev/spibone0 backend for OpenInferno inferno-portd
 *
 * Bridges inferno-portd's 32-bit register accesses over the OpenAudioFPGA
 * Linux spibone Wishbone bus driver (driver/spibone/spibone_uapi.h):
 *   0x81000000..0x810000FF : aes50_ctrl_wb (0x81000040..0x81000048 = CS2000-CP engine)
 *   0xA0000000..0xA00003FF : inferno_wb (aoip_regs, inferno_regs, cpu_pktq, fs_phase)
 *
 * Because /dev/spibone0 serializes Wishbone accesses in the kernel driver,
 * inferno-portd and OpenMixerControl can safely share the FPGA SPI bus
 * without external lockfiles.
 *
 * License: GPL-3.0-or-later
 */
#ifndef OPENAUDIOFPGA_HW_SPIBONE_H
#define OPENAUDIOFPGA_HW_SPIBONE_H

#include <stdint.h>
#include "hw.h"

#define OAF_AES50_BASE       0x81000000u
#define OAF_CLKCTRL_BASE     0x82000000u
#define OAF_CS2K_BASE        0x82000040u
#define OAF_INFERNO_BASE     0xA0000000u
#define OAF_FSPHASE_BASE     0xA0000300u

/* Open an OpenAudioFPGA SPIBone backend (e.g. dev="/dev/spibone0").
 * Configures port_base=0xA0000000, clock_base=0xA0000000,
 * dclk_base=0xA0000300, cs2k_base=0x81000040. */
hw_t *hw_spibone_open(const char *spibone_path);

/* Convenience helpers for OpenAudioFPGA Wishbone registers */
uint32_t oaf_wb_peek(hw_t *h, uint32_t addr);
void     oaf_wb_poke(hw_t *h, uint32_t addr, uint32_t val);

#endif
