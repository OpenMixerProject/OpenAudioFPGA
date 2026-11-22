/* Manual, one-shot identity test. Hash/transport conventions from OpenWING wing-t55.c. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/gpio.h>
#include <linux/if_alg.h>
#include <linux/magic.h>
#include <linux/spi/spidev.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <time.h>
#include <unistd.h>
#include "spibone_uapi.h"

#define BUNDLE "/usr/share/wing-fabric-id/"
#define CONFIG_SPI "/dev/spidev1.0"
#define CONTROL_SPI "/dev/spibone0"
#define SPI_HZ 2000000u
#define ACK "LOAD FABRIC ID: RAM, ISOLATION AND R2 VERIFIED"
_Static_assert(SPIBONE_IOC_WING_ENABLE == _IOW(0xB5, 8, uint32_t), "wrong SPIBone UAPI");

struct input { const char *name; size_t size; const char *hash; };
#include "bound.h"

static int ctrl = -1;

static bool offline(void) {
    uint32_t state = SPIBONE_STATE_OFFLINE;
    return ioctl(ctrl, SPIBONE_IOC_SET_STATE, &state) == 0;
}

static void require(bool ok, const char *step) {
    if (ok) return;
    const char *state = ctrl < 0 ? "untouched" : offline() ? "yes" : "unknown";
    /* No automatic reset/reload: CRESET could remove external isolation again. */
    printf("WING_FABRIC_ID_V1 result=fail stage=%s offline=%s retry=no\n", step, state);
    exit(EXIT_FAILURE);
}

static void ms(unsigned value) {
    struct timespec delay = {.tv_sec = value / 1000, .tv_nsec = (value % 1000) * 1000000L};
    while (nanosleep(&delay, &delay) < 0) require(errno == EINTR, "delay");
}

static bool trusted_file(int fd, mode_t mode, off_t size) {
    struct stat st;
    return fd >= 0 && !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == 0 &&
           (st.st_mode & 07777) == mode && st.st_size == size;
}

static void sha256(const struct input *file, const uint8_t *bytes) {
    const struct sockaddr_alg algorithm = {.salg_family = AF_ALG, .salg_type = "hash", .salg_name = "sha256"};
    int sock = socket(AF_ALG, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    require(sock >= 0 && !bind(sock, (const struct sockaddr *)&algorithm, sizeof algorithm), "sha256-init");
    int job = accept4(sock, NULL, NULL, SOCK_CLOEXEC);
    require(job >= 0, "sha256-open");
    for (size_t off = 0; off < file->size;) {
        size_t count = file->size - off;
        if (count > 4096) count = 4096;
        require(send(job, bytes + off, count, off + count < file->size ? MSG_MORE : 0) == (ssize_t)count,
                "sha256-input");
        off += count;
    }
    uint8_t digest[32];
    require(read(job, digest, sizeof digest) == sizeof digest, "sha256-result");
    close(job);
    close(sock);
    char hex[65];
    for (size_t i = 0; i < sizeof digest; ++i) snprintf(hex + 2*i, 3, "%02x", digest[i]);
    require(!strcmp(hex, file->hash), file->name);
    printf("WING_FABRIC_ID_V1 hash=ok file=%s bytes=%zu sha256=%s\n", file->name, file->size, hex);
}

static uint8_t *read_bound(const struct input *file) {
    char path[128];
    snprintf(path, sizeof path, BUNDLE "%s", file->name);
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    require(trusted_file(fd, 0444, file->size), file->name);
    uint8_t *bytes = malloc(file->size);
    require(bytes != NULL, "allocate");
    for (size_t off = 0; off < file->size;) {
        ssize_t n = read(fd, bytes + off, file->size - off);
        require(n > 0, "file-read");
        off += (size_t)n;
    }
    close(fd);
    sha256(file, bytes);
    return bytes;
}

static void lock_attempt(void) {
    int run = open("/run", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    struct statfs fs;
    require(run >= 0 && !fstat(run, &st) && st.st_uid == 0 && !(st.st_mode & 0022) &&
            !fstatfs(run, &fs) && fs.f_type == TMPFS_MAGIC, "run-tmpfs");
    int lock = openat(run, "wing-t55.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    require(trusted_file(lock, 0600, 0) && !flock(lock, LOCK_EX | LOCK_NB), "lock");
    int attempt = openat(run, "wing-fabric-id.attempt", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    require(attempt >= 0, "once-per-boot");
    close(attempt);
    require(!unlinkat(run, "omc-wing-fpga.json", 0) || errno == ENOENT, "invalidate-product-receipt");
    close(run);
}

static int gpio_line(const char *name, unsigned offset, bool output) {
    glob_t chips;
    require(!glob("/dev/gpiochip*", 0, NULL, &chips), "no-gpiochips");
    int chip = -1;
    for (size_t i = 0; i < chips.gl_pathc; ++i) {
        int fd = open(chips.gl_pathv[i], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        struct gpio_v2_line_info info = {.offset = offset};
        if (fd >= 0 && !ioctl(fd, GPIO_V2_GET_LINEINFO_IOCTL, &info) && !strcmp(name, info.name)) {
            require(chip < 0, "ambiguous-gpio");
            chip = fd;
        } else if (fd >= 0) close(fd);
    }
    globfree(&chips);
    require(chip >= 0, name);
    struct gpio_v2_line_request req = {
        .offsets = {offset}, .num_lines = 1, .consumer = "wing-fabric-id",
        .config.flags = output ? GPIO_V2_LINE_FLAG_OUTPUT : GPIO_V2_LINE_FLAG_INPUT,
    };
    if (output) {
        req.config.num_attrs = 1;
        req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
        req.config.attrs[0].attr.values = 0;  /* Request CRESET already low. */
        req.config.attrs[0].mask = 1;
    }
    require(!ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req), name);
    close(chip);
    return req.fd;
}

static bool cdone(int fd) {
    struct gpio_v2_line_values values = {.mask = 1};
    require(!ioctl(fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &values), "cdone-read");
    return (values.bits & 1) != 0;
}

static void upload(int done, const uint8_t *image, size_t length) {
    int cfg = open(CONFIG_SPI, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    require(cfg >= 0, "ss0-config-endpoint");
    uint32_t mode = SPI_MODE_0 | SPI_NO_CS, hz = SPI_HZ;
    uint8_t width = 8;
    require(!ioctl(cfg, SPI_IOC_WR_MODE32, &mode) && !ioctl(cfg, SPI_IOC_WR_BITS_PER_WORD, &width) &&
            !ioctl(cfg, SPI_IOC_WR_MAX_SPEED_HZ, &hz), "spi-no-cs");
    mode = 0;
    require(!ioctl(cfg, SPI_IOC_RD_MODE32, &mode) && mode == SPI_NO_CS, "spi-no-cs-readback");
    int reset = gpio_line("T55_CRESET_N", 17, true);
    ms(2);
    require(!cdone(done), "cdone-not-low-in-reset");
    printf("WING_FABRIC_ID_V1 cdone=0 stage=reset\n");
    struct gpio_v2_line_values values = {.mask = 1, .bits = 1};
    require(!ioctl(reset, GPIO_V2_LINE_SET_VALUES_IOCTL, &values), "creset-release");
    ms(5);
    require(!cdone(done), "cdone-high-before-upload");
    for (size_t off = 0; off < length;) {
        size_t count = length - off;
        if (count > 1024) count = 1024;
        struct spi_ioc_transfer xfer = {.tx_buf = (uintptr_t)(image + off), .len = count,
                                        .speed_hz = SPI_HZ, .bits_per_word = 8};
        require(ioctl(cfg, SPI_IOC_MESSAGE(1), &xfer) == (int)count, "short-or-failed-upload");
        off += count;
    }
    for (unsigned i = 0; i < 100 && !cdone(done); ++i) ms(1);
    require(cdone(done), "cdone-not-high-after-upload");
    printf("WING_FABRIC_ID_V1 cdone=1 stage=uploaded bytes=%zu offset=0\n", length);
    close(cfg);
    /* Hold the CRESET request high until test exit; then rely on verified board bias. */
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    require(argc == 2 && !strcmp(argv[1], ACK) && geteuid() == 0, "manual-approval");
    umask(077);
    lock_attempt();
    printf("WING_FABRIC_ID_V1 event=start expected_build=0x%08x ss=1 mode=0 spi_hz=%u r2_hz=49152000\n",
           FABRIC_BUILD_ID, SPI_HZ);
    free(read_bound(&inputs[0]));
    uint8_t *image = read_bound(&inputs[1]);
    ctrl = open(CONTROL_SPI, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    require(ctrl >= 0 && offline(), "spi-offline-before-load");
    int done = gpio_line("T55_CDONE", 26, false);
    upload(done, image, inputs[1].size);
    free(image);

    uint32_t build = FABRIC_BUILD_ID, state;
    require(cdone(done) && !ioctl(ctrl, SPIBONE_IOC_WING_ENABLE, &build), "ss1-enable-or-identity");
    require(!ioctl(ctrl, SPIBONE_IOC_GET_STATE, &state) && state == SPIBONE_STATE_ONLINE, "ss1-online");
    for (size_t i = 0; i < sizeof identity / sizeof *identity; ++i) {
        struct spibone_wb_xfer reg = {.addr = identity[i].addr};
        require(cdone(done) && !ioctl(ctrl, SPIBONE_IOC_PEEK, &reg), "ss1-peek");
        printf("WING_FABRIC_ID_V1 reg=%s address=0x%04x value=0x%08x expected=0x%08x\n",
               identity[i].name, reg.addr, reg.val, identity[i].value);
        require(reg.val == identity[i].value, identity[i].name);
    }
    require(cdone(done), "cdone-lost");
    require(offline(), "ss1-offline-after-probe");
    puts("WING_FABRIC_ID_V1 result=pass cdone=1 offline=yes audio_qualified=no");
    return 0;
}
