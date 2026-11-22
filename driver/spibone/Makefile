# SPDX-License-Identifier: GPL-2.0-or-later
# Out-of-tree Makefile for the LiteX SPIBone bus driver (build it before its
# client drivers, e.g. aes67_eth of the AES67 project, which link against its
# symbols: KBUILD_EXTRA_SYMBOLS=<this directory>/Module.symvers).
#
#   make                 build against the running kernel
#   make KDIR=... ARCH=... CROSS_COMPILE=...   cross-build for the target SoC
#   make install         install the module (run as root, or set INSTALL_MOD_PATH)
#   make clean

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)
INSTALL_MOD_PATH ?=

default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

install: default
	$(MAKE) -C $(KDIR) M=$(PWD) INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) modules_install

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
