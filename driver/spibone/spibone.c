// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * LiteX SPIBone bus driver.
 *
 * Owns the SPI device of a LiteX SPIBone bridge (4-wire SPI -> Wishbone) and is
 * the only Wishbone master on it:
 *   - in-kernel API for client drivers (spibone.h): single word and burst access
 *   - client devices: one platform device per available DT child node, created
 *     while the bus is online (e.g. the AES67 core, driver aes67_eth)
 *   - /dev/spiboneN for userspace (spibone_uapi.h): peek / poke / bursts, the bus
 *     state, and raw SPI messages to configure the FPGA over the same link
 *
 * Wire protocol (litex/soc/cores/spi/spi_bone.py and its burst fork in
 * OpenAudioFPGA, litex_soc/spi_bone.py):
 *   write:       [0x00][addr BE32][value BE32], then 0xff until the 0x00 ack
 *   read:        [0x01][addr BE32], then 0xff until 0x01 + value BE32
 *   burst write: [0x02][addr BE32][count BE16][count x value BE32], 0xff .. 0x00
 *   burst read:  [0x03][addr BE32][count BE16], per word 0xff .. 0x01 + value
 * Each transaction is one SPI message; the chip select frames the transaction
 * (the bridge resets on a deasserted chip select), so it has to be a GPIO or a
 * native chip select that stays asserted for the whole message.
 *
 * Device tree:
 *   fpga@0 {
 *       compatible = "litex,spibone";
 *       reg = <0>;                          // chip select
 *       spi-max-frequency = <8000000>;      // spibone samples SCLK with its sys_clk
 *       #address-cells = <1>;
 *       #size-cells = <1>;
 *       litex,online-at-probe;              // optional: the gateware is there at boot
 *                                           // (FPGA from flash); else the bus starts
 *                                           // offline and userspace sets it online
 *       aes67@90000000 {                    // client: a platform device while online
 *           compatible = "aes67,eth";
 *           reg = <0x90000000 0x20000>;     // Wishbone window (read by the client)
 *       };
 *   };
 */
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/idr.h>
#include <linux/list.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/spi/spi.h>
#include <linux/spi/spidev.h>
#include <linux/uaccess.h>
#include <linux/unaligned.h>
#include <linux/vmalloc.h>

#include "spibone.h"
#include "spibone_uapi.h"

#define CMD_WRITE		0x00
#define CMD_READ		0x01
#define CMD_BURST_WRITE		0x02
#define CMD_BURST_READ		0x03

/* 0xff padding clocked out to capture the variable-latency response */
#define RESPONSE_SLACK		24
#define BURST_WR_SLACK		8
#define BURST_RD_SLACK		16

/* Burst chunks (words) so that one transfer fits the scratch buffers:
 *   write: 7 (cmd + addr + count) + 4 * N + slack
 *   read:  7 + 7 * N (<= pad + sync + 4 data per word) + slack */
#define SCRATCH_SIZE		2048u
#define BURST_WR_CHUNK		384u	/* 7 + 1536 + 8  = 1551 */
#define BURST_RD_CHUNK		288u	/* 7 + 2016 + 16 = 2039 */

static unsigned int spi_hz;
module_param(spi_hz, uint, 0644);
MODULE_PARM_DESC(spi_hz, "SPI clock in Hz for Wishbone transactions (0 = spi-max-frequency of the DT). "
		 "SPIBone samples SCLK with its sys_clk: keep it at or below sys_clk / 12.");

static bool use_burst = true;
module_param(use_burst, bool, 0644);
MODULE_PARM_DESC(use_burst, "Use the burst commands 0x02 / 0x03 (0 = one transaction per word, for gateware without burst support)");

struct spibone_child {
	struct list_head	 node;
	struct platform_device	*pdev;
};

struct spibone {
	struct spi_device	*spi;
	/* every SPI transaction (Wishbone and raw) */
	struct mutex		 bus_lock;
	/* state changes (taken before bus_lock, never inside it) */
	struct mutex		 state_lock;
	u32			 state;
	struct list_head	 children;
	/* DMA-safe scratch for bursts, guarded by bus_lock */
	u8			*tx;
	u8			*rx;
	int			 id;
	char			 name[16];
	struct miscdevice	 misc;
};

static DEFINE_IDA(spibone_ida);
static struct spi_driver spibone_driver;

static const char *const state_names[] = {
	[SPIBONE_STATE_OFFLINE]	= "offline",
	[SPIBONE_STATE_CONFIG]	= "config",
	[SPIBONE_STATE_ONLINE]	= "online",
};

/* --- SPI ------------------------------------------------------------------- */

static int spibone_xfer(struct spibone *sb, const u8 *tx, u8 *rx, size_t len)
{
	struct spi_transfer t = {
		.tx_buf		= tx,
		.rx_buf		= rx,
		.len		= len,
		.speed_hz	= spi_hz,	/* 0: spi-max-frequency */
	};
	struct spi_message m;

	spi_message_init(&m);
	spi_message_add_tail(&t, &m);
	return spi_sync(sb->spi, &m);
}

/* --- Wishbone access ---------------------------------------------------------- */

struct spibone *spibone_get(struct device *child)
{
	struct device *parent = child ? child->parent : NULL;

	if (!parent || parent->driver != &spibone_driver.driver)
		return NULL;
	return spi_get_drvdata(to_spi_device(parent));
}
EXPORT_SYMBOL_GPL(spibone_get);

void spibone_lock(struct spibone *sb)
{
	mutex_lock(&sb->bus_lock);
}
EXPORT_SYMBOL_GPL(spibone_lock);

void spibone_unlock(struct spibone *sb)
{
	mutex_unlock(&sb->bus_lock);
}
EXPORT_SYMBOL_GPL(spibone_unlock);

void spibone_assert_held(struct spibone *sb)
{
	lockdep_assert_held(&sb->bus_lock);
}
EXPORT_SYMBOL_GPL(spibone_assert_held);

bool spibone_online(struct spibone *sb)
{
	return READ_ONCE(sb->state) == SPIBONE_STATE_ONLINE;
}
EXPORT_SYMBOL_GPL(spibone_online);

int spibone_read_locked(struct spibone *sb, u32 addr, u32 *val)
{
	u8 tx[5 + RESPONSE_SLACK];
	u8 rx[5 + RESPONSE_SLACK];
	int ret, i;

	lockdep_assert_held(&sb->bus_lock);
	if (!spibone_online(sb))
		return -ENODEV;

	tx[0] = CMD_READ;
	put_unaligned_be32(addr, &tx[1]);
	memset(&tx[5], 0xff, RESPONSE_SLACK);

	ret = spibone_xfer(sb, tx, rx, sizeof(tx));
	if (ret)
		return ret;

	/* skip the 0xff the bridge drives while the read is in flight */
	for (i = 5; i + 4 < (int)sizeof(rx); i++) {
		if (rx[i] == CMD_READ) {
			*val = get_unaligned_be32(&rx[i + 1]);
			return 0;
		}
		if (rx[i] != 0xff)
			return -EIO;
	}
	return -ETIMEDOUT;
}
EXPORT_SYMBOL_GPL(spibone_read_locked);

int spibone_write_locked(struct spibone *sb, u32 addr, u32 val)
{
	u8 tx[9 + RESPONSE_SLACK];
	u8 rx[9 + RESPONSE_SLACK];
	int ret, i;

	lockdep_assert_held(&sb->bus_lock);
	if (!spibone_online(sb))
		return -ENODEV;

	tx[0] = CMD_WRITE;
	put_unaligned_be32(addr, &tx[1]);
	put_unaligned_be32(val, &tx[5]);
	memset(&tx[9], 0xff, RESPONSE_SLACK);

	ret = spibone_xfer(sb, tx, rx, sizeof(tx));
	if (ret)
		return ret;

	for (i = 9; i < (int)sizeof(rx); i++) {
		if (rx[i] == CMD_WRITE)
			return 0;
		if (rx[i] != 0xff)
			return -EIO;
	}
	return -ETIMEDOUT;
}
EXPORT_SYMBOL_GPL(spibone_write_locked);

int spibone_read(struct spibone *sb, u32 addr, u32 *val)
{
	int ret;

	mutex_lock(&sb->bus_lock);
	ret = spibone_read_locked(sb, addr, val);
	mutex_unlock(&sb->bus_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(spibone_read);

int spibone_write(struct spibone *sb, u32 addr, u32 val)
{
	int ret;

	mutex_lock(&sb->bus_lock);
	ret = spibone_write_locked(sb, addr, val);
	mutex_unlock(&sb->bus_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(spibone_write);

int spibone_burst_write_locked(struct spibone *sb, u32 addr, const u32 *words, unsigned int n)
{
	lockdep_assert_held(&sb->bus_lock);
	if (!spibone_online(sb))
		return -ENODEV;

	if (!use_burst) {
		unsigned int i;
		int ret;

		for (i = 0; i < n; i++) {
			ret = spibone_write_locked(sb, addr + 4 * i, words[i]);
			if (ret)
				return ret;
		}
		return 0;
	}

	while (n) {
		unsigned int chunk = min(n, BURST_WR_CHUNK);
		unsigned int len, i;
		int ret;

		sb->tx[0] = CMD_BURST_WRITE;
		put_unaligned_be32(addr, &sb->tx[1]);
		put_unaligned_be16((u16)chunk, &sb->tx[5]);
		for (i = 0; i < chunk; i++)
			put_unaligned_be32(words[i], &sb->tx[7 + 4 * i]);
		len = 7 + 4 * chunk;
		memset(&sb->tx[len], 0xff, BURST_WR_SLACK);
		len += BURST_WR_SLACK;

		ret = spibone_xfer(sb, sb->tx, sb->rx, len);
		if (ret)
			return ret;

		/* the 0x00 ack after the last word */
		for (i = 7 + 4 * chunk; i < len; i++) {
			if (sb->rx[i] == CMD_WRITE)
				break;
			if (sb->rx[i] != 0xff)
				return -EIO;
		}
		if (i == len)
			return -ETIMEDOUT;

		addr  += 4 * chunk;
		words += chunk;
		n     -= chunk;
	}
	return 0;
}
EXPORT_SYMBOL_GPL(spibone_burst_write_locked);

int spibone_burst_read_locked(struct spibone *sb, u32 addr, u32 *words, unsigned int n)
{
	lockdep_assert_held(&sb->bus_lock);
	if (!spibone_online(sb))
		return -ENODEV;

	if (!use_burst) {
		unsigned int i;
		int ret;

		for (i = 0; i < n; i++) {
			ret = spibone_read_locked(sb, addr + 4 * i, &words[i]);
			if (ret)
				return ret;
		}
		return 0;
	}

	while (n) {
		unsigned int chunk = min(n, BURST_RD_CHUNK);
		unsigned int len, i, w;
		int ret;

		sb->tx[0] = CMD_BURST_READ;
		put_unaligned_be32(addr, &sb->tx[1]);
		put_unaligned_be16((u16)chunk, &sb->tx[5]);
		len = 7 + 7 * chunk + BURST_RD_SLACK;
		memset(&sb->tx[7], 0xff, len - 7);

		ret = spibone_xfer(sb, sb->tx, sb->rx, len);
		if (ret)
			return ret;

		i = 7;
		for (w = 0; w < chunk; w++) {
			while (i < len && sb->rx[i] == 0xff)
				i++;
			if (i + 5 > len || sb->rx[i] != CMD_READ)
				return -ETIMEDOUT;
			words[w] = get_unaligned_be32(&sb->rx[i + 1]);
			i += 5;
		}

		addr  += 4 * chunk;
		words += chunk;
		n     -= chunk;
	}
	return 0;
}
EXPORT_SYMBOL_GPL(spibone_burst_read_locked);

/* --- client devices (DT child nodes) ------------------------------------------- */

/*
 * The children are created by hand, not with of_platform_populate(): their reg is a
 * Wishbone window that cannot be translated through the SPI bus (of_device_alloc
 * would warn for every node). The clients read reg themselves.
 */
static void spibone_add_children(struct spibone *sb)
{
	struct device *dev = &sb->spi->dev;
	struct device_node *child;

	for_each_available_child_of_node(dev->of_node, child) {
		struct spibone_child *c;
		struct platform_device *pdev;
		int ret;

		c = kzalloc(sizeof(*c), GFP_KERNEL);
		if (!c)
			break;
		pdev = platform_device_alloc(child->name, PLATFORM_DEVID_AUTO);
		if (!pdev) {
			kfree(c);
			break;
		}
		pdev->dev.parent = dev;
		/* platform_device_release() drops this reference */
		device_set_node(&pdev->dev, of_fwnode_handle(of_node_get(child)));
		ret = platform_device_add(pdev);
		if (ret) {
			dev_err(dev, "client %pOFn: %d\n", child, ret);
			platform_device_put(pdev);
			kfree(c);
			continue;
		}
		c->pdev = pdev;
		list_add_tail(&c->node, &sb->children);
	}
}

static void spibone_remove_children(struct spibone *sb)
{
	struct spibone_child *c, *tmp;

	list_for_each_entry_safe_reverse(c, tmp, &sb->children, node) {
		platform_device_unregister(c->pdev);
		list_del(&c->node);
		kfree(c);
	}
}

/* caller holds state_lock (not bus_lock: the clients use the bus while they go) */
static int spibone_set_state(struct spibone *sb, u32 state)
{
	u32 old = sb->state;

	if (state > SPIBONE_STATE_ONLINE)
		return -EINVAL;
	if (state == old)
		return 0;

	if (old == SPIBONE_STATE_ONLINE)
		spibone_remove_children(sb);

	mutex_lock(&sb->bus_lock);
	WRITE_ONCE(sb->state, state);
	mutex_unlock(&sb->bus_lock);

	if (state == SPIBONE_STATE_ONLINE)
		spibone_add_children(sb);

	dev_info(&sb->spi->dev, "bus %s\n", state_names[state]);
	return 0;
}

/* --- raw SPI messages (FPGA configuration) --------------------------------------- */

static int spibone_raw_message(struct spibone *sb, const struct spibone_raw_message *rm)
{
	struct spi_device *spi = sb->spi;
	struct spi_ioc_transfer *u;
	struct spi_transfer *k;
	struct spi_message m;
	u32 saved_mode;
	size_t total = 0;
	unsigned int i;
	int ret;

	if (rm->n_xfers == 0 || rm->n_xfers > SPIBONE_RAW_MAX_XFERS)
		return -EINVAL;
	if (rm->mode & ~(u32)SPI_MODE_X_MASK)
		return -EINVAL;

	u = kvmalloc_array(rm->n_xfers, sizeof(*u), GFP_KERNEL);
	k = kvcalloc(rm->n_xfers, sizeof(*k), GFP_KERNEL);
	if (!u || !k) {
		ret = -ENOMEM;
		goto out_free;
	}
	if (copy_from_user(u, u64_to_user_ptr(rm->xfers), rm->n_xfers * sizeof(*u))) {
		ret = -EFAULT;
		goto out_free;
	}

	spi_message_init(&m);
	for (i = 0; i < rm->n_xfers; i++) {
		total += u[i].len;
		if (u[i].len == 0 || total > SPIBONE_RAW_MAX_BYTES) {
			ret = -EINVAL;
			goto out_bufs;
		}
		if (u[i].tx_buf) {
			void *b = kmalloc(u[i].len, GFP_KERNEL);

			if (!b) {
				ret = -ENOMEM;
				goto out_bufs;
			}
			k[i].tx_buf = b;
			if (copy_from_user(b, u64_to_user_ptr(u[i].tx_buf), u[i].len)) {
				ret = -EFAULT;
				goto out_bufs;
			}
		}
		if (u[i].rx_buf) {
			k[i].rx_buf = kmalloc(u[i].len, GFP_KERNEL);
			if (!k[i].rx_buf) {
				ret = -ENOMEM;
				goto out_bufs;
			}
		}
		k[i].len		= u[i].len;
		k[i].speed_hz		= u[i].speed_hz;
		k[i].bits_per_word	= u[i].bits_per_word;
		k[i].cs_change		= !!u[i].cs_change;
		k[i].delay.value	= u[i].delay_usecs;
		k[i].delay.unit		= SPI_DELAY_UNIT_USECS;
		k[i].word_delay.value	= u[i].word_delay_usecs;
		k[i].word_delay.unit	= SPI_DELAY_UNIT_USECS;
		spi_message_add_tail(&k[i], &m);
	}

	mutex_lock(&sb->bus_lock);
	if (sb->state != SPIBONE_STATE_CONFIG) {
		ret = -EBUSY;
	} else {
		saved_mode = spi->mode;
		spi->mode = (spi->mode & ~SPI_MODE_X_MASK) | rm->mode;
		ret = spi_setup(spi);
		if (!ret)
			ret = spi_sync(spi, &m);
		spi->mode = saved_mode;
		spi_setup(spi);
	}
	mutex_unlock(&sb->bus_lock);

	for (i = 0; !ret && i < rm->n_xfers; i++) {
		if (k[i].rx_buf && u[i].rx_buf &&
		    copy_to_user(u64_to_user_ptr(u[i].rx_buf), k[i].rx_buf, u[i].len))
			ret = -EFAULT;
	}

out_bufs:
	for (i = 0; i < rm->n_xfers; i++) {
		kfree(k[i].tx_buf);
		kfree(k[i].rx_buf);
	}
out_free:
	kvfree(u);
	kvfree(k);
	return ret;
}

/* --- /dev/spiboneN ---------------------------------------------------------------- */

static struct spibone *file_to_sb(struct file *f)
{
	return container_of(f->private_data, struct spibone, misc);
}

static long spibone_ioctl_burst(struct spibone *sb, unsigned int cmd, void __user *uarg)
{
	struct spibone_wb_burst b;
	u32 *words;
	int ret;

	if (copy_from_user(&b, uarg, sizeof(b)))
		return -EFAULT;
	if (b.count == 0 || b.count > 65535)
		return -EINVAL;

	words = kvmalloc_array(b.count, sizeof(u32), GFP_KERNEL);
	if (!words)
		return -ENOMEM;

	if (cmd == SPIBONE_IOC_BURST_WRITE) {
		if (copy_from_user(words, u64_to_user_ptr(b.words), b.count * sizeof(u32))) {
			ret = -EFAULT;
			goto out;
		}
		mutex_lock(&sb->bus_lock);
		ret = spibone_burst_write_locked(sb, b.addr, words, b.count);
		mutex_unlock(&sb->bus_lock);
	} else {
		mutex_lock(&sb->bus_lock);
		ret = spibone_burst_read_locked(sb, b.addr, words, b.count);
		mutex_unlock(&sb->bus_lock);
		if (!ret && copy_to_user(u64_to_user_ptr(b.words), words, b.count * sizeof(u32)))
			ret = -EFAULT;
	}
out:
	kvfree(words);
	return ret;
}

static long spibone_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct spibone *sb = file_to_sb(f);
	void __user *uarg = (void __user *)arg;
	struct spibone_wb_xfer x;
	struct spibone_raw_message rm;
	u32 state;
	int ret;

	switch (cmd) {
	case SPIBONE_IOC_PEEK:
		if (copy_from_user(&x, uarg, sizeof(x)))
			return -EFAULT;
		ret = spibone_read(sb, x.addr, &x.val);
		if (ret)
			return ret;
		return copy_to_user(uarg, &x, sizeof(x)) ? -EFAULT : 0;

	case SPIBONE_IOC_POKE:
		if (copy_from_user(&x, uarg, sizeof(x)))
			return -EFAULT;
		return spibone_write(sb, x.addr, x.val);

	case SPIBONE_IOC_BURST_READ:
	case SPIBONE_IOC_BURST_WRITE:
		return spibone_ioctl_burst(sb, cmd, uarg);

	case SPIBONE_IOC_GET_STATE:
		state = READ_ONCE(sb->state);
		return put_user(state, (u32 __user *)uarg);

	case SPIBONE_IOC_SET_STATE:
		if (get_user(state, (u32 __user *)uarg))
			return -EFAULT;
		mutex_lock(&sb->state_lock);
		ret = spibone_set_state(sb, state);
		mutex_unlock(&sb->state_lock);
		return ret;

	case SPIBONE_IOC_RAW_MESSAGE:
		if (copy_from_user(&rm, uarg, sizeof(rm)))
			return -EFAULT;
		return spibone_raw_message(sb, &rm);

	default:
		return -ENOTTY;
	}
}

static const struct file_operations spibone_fops = {
	.owner		= THIS_MODULE,
	.unlocked_ioctl	= spibone_ioctl,
	.compat_ioctl	= compat_ptr_ioctl,
};

/* --- sysfs: state ------------------------------------------------------------------ */

static ssize_t state_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct spibone *sb = spi_get_drvdata(to_spi_device(dev));

	return sysfs_emit(buf, "%s\n", state_names[READ_ONCE(sb->state)]);
}

static ssize_t state_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	struct spibone *sb = spi_get_drvdata(to_spi_device(dev));
	int state, ret;

	state = sysfs_match_string(state_names, buf);
	if (state < 0)
		return state;
	mutex_lock(&sb->state_lock);
	ret = spibone_set_state(sb, state);
	mutex_unlock(&sb->state_lock);
	return ret ? ret : count;
}
static DEVICE_ATTR_RW(state);

static struct attribute *spibone_attrs[] = {
	&dev_attr_state.attr,
	NULL,
};
ATTRIBUTE_GROUPS(spibone);

/* --- probe / remove ------------------------------------------------------------- */

static int spibone_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	struct spibone *sb;
	int ret;

	sb = devm_kzalloc(dev, sizeof(*sb), GFP_KERNEL);
	if (!sb)
		return -ENOMEM;
	sb->spi = spi;
	mutex_init(&sb->bus_lock);
	mutex_init(&sb->state_lock);
	INIT_LIST_HEAD(&sb->children);
	sb->state = SPIBONE_STATE_OFFLINE;

	sb->tx = devm_kmalloc(dev, SCRATCH_SIZE, GFP_KERNEL);
	sb->rx = devm_kmalloc(dev, SCRATCH_SIZE, GFP_KERNEL);
	if (!sb->tx || !sb->rx)
		return -ENOMEM;

	spi->mode = (spi->mode & ~SPI_MODE_X_MASK) | SPI_MODE_0;
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	if (ret)
		return dev_err_probe(dev, ret, "spi_setup\n");

	spi_set_drvdata(spi, sb);

	sb->id = ida_alloc(&spibone_ida, GFP_KERNEL);
	if (sb->id < 0)
		return sb->id;
	snprintf(sb->name, sizeof(sb->name), "spibone%d", sb->id);
	sb->misc.minor	= MISC_DYNAMIC_MINOR;
	sb->misc.name	= sb->name;
	sb->misc.fops	= &spibone_fops;
	sb->misc.parent	= dev;
	ret = misc_register(&sb->misc);
	if (ret) {
		ida_free(&spibone_ida, sb->id);
		return ret;
	}

	dev_info(dev, "/dev/%s, %u Hz\n", sb->name, spi_hz ? spi_hz : spi->max_speed_hz);

	if (of_property_read_bool(dev->of_node, "litex,online-at-probe")) {
		mutex_lock(&sb->state_lock);
		spibone_set_state(sb, SPIBONE_STATE_ONLINE);
		mutex_unlock(&sb->state_lock);
	}
	return 0;
}

static void spibone_remove(struct spi_device *spi)
{
	struct spibone *sb = spi_get_drvdata(spi);

	mutex_lock(&sb->state_lock);
	spibone_set_state(sb, SPIBONE_STATE_OFFLINE);
	mutex_unlock(&sb->state_lock);
	misc_deregister(&sb->misc);
	ida_free(&spibone_ida, sb->id);
}

static const struct of_device_id spibone_of_match[] = {
	{ .compatible = "litex,spibone" },
	{ }
};
MODULE_DEVICE_TABLE(of, spibone_of_match);

/* the SPI core matches the modalias: the DT compatible without the vendor prefix */
static const struct spi_device_id spibone_spi_ids[] = {
	{ "spibone" },
	{ }
};
MODULE_DEVICE_TABLE(spi, spibone_spi_ids);

static struct spi_driver spibone_driver = {
	.driver = {
		.name		= "spibone",
		.of_match_table	= spibone_of_match,
		.dev_groups	= spibone_groups,
	},
	.id_table	= spibone_spi_ids,
	.probe		= spibone_probe,
	.remove		= spibone_remove,
};
module_spi_driver(spibone_driver);

MODULE_DESCRIPTION("LiteX SPIBone (SPI -> Wishbone) bus driver");
MODULE_AUTHOR("OpenAudioFPGA project");
MODULE_LICENSE("GPL");
