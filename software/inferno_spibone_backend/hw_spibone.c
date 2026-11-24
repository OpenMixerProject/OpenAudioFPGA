/* hw_spibone.c - OpenAudioFPGA /dev/spibone0 backend for OpenInferno inferno-portd
 *
 * License: GPL-3.0-or-later
 */
#include "hw_spibone.h"
#include "../../driver/spibone/spibone_uapi.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

typedef struct {
    int fd;
} spibone_priv_t;

static uint32_t spibone_rd(hw_t *h, uint32_t addr)
{
    spibone_priv_t *p = (spibone_priv_t *)h->priv;
    struct spibone_wb_xfer xfer;
    memset(&xfer, 0, sizeof(xfer));
    xfer.addr = addr;
    if (ioctl(p->fd, SPIBONE_IOC_PEEK, &xfer) < 0) {
        return 0;
    }
    return xfer.val;
}

static void spibone_wr(hw_t *h, uint32_t addr, uint32_t v)
{
    spibone_priv_t *p = (spibone_priv_t *)h->priv;
    struct spibone_wb_xfer xfer;
    memset(&xfer, 0, sizeof(xfer));
    xfer.addr = addr;
    xfer.val  = v;
    (void)ioctl(p->fd, SPIBONE_IOC_POKE, &xfer);
}

static int  spibone_pollfd(hw_t *h)  { (void)h; return -1; }
static void spibone_service(hw_t *h) { (void)h; }

static void spibone_close(hw_t *h)
{
    spibone_priv_t *p = (spibone_priv_t *)h->priv;
    if (p) {
        if (p->fd >= 0) close(p->fd);
        free(p);
    }
    free(h);
}

static const struct hw_ops spibone_ops = {
    spibone_rd,
    spibone_wr,
    spibone_pollfd,
    spibone_service,
    spibone_close
};

hw_t *hw_spibone_open(const char *spibone_path)
{
    int fd = open(spibone_path ? spibone_path : "/dev/spibone0", O_RDWR);
    if (fd < 0) return NULL;

    spibone_priv_t *p = (spibone_priv_t *)calloc(1, sizeof(*p));
    hw_t *h           = (hw_t *)calloc(1, sizeof(*h));
    if (!p || !h) {
        free(p);
        free(h);
        close(fd);
        return NULL;
    }

    p->fd         = fd;
    h->ops        = &spibone_ops;
    h->priv       = p;
    h->port_base  = OAF_INFERNO_BASE;
    h->clock_base = OAF_INFERNO_BASE;
    h->dclk_base  = OAF_FSPHASE_BASE;
    h->cs2k_base  = OAF_CS2K_BASE;
    return h;
}

uint32_t oaf_wb_peek(hw_t *h, uint32_t addr)
{
    return spibone_rd(h, addr);
}

void oaf_wb_poke(hw_t *h, uint32_t addr, uint32_t val)
{
    spibone_wr(h, addr, val);
}
