/* Native offline test: only GPIO/SPI operations are mocked; AF_ALG hashes real bytes. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdarg.h>
#include "loader.c"

enum { MOCK_CTRL=101, MOCK_CFG, MOCK_CHIP, MOCK_DONE, MOCK_RESET };
static bool released, mode_set, online;
static unsigned reads, probes;
static size_t transferred;
static const char *test, *fixture;

int __real_open(const char *, int, ...);
int __wrap_open(const char *path, int flags, ...) {
    if (!strcmp(path, CONTROL_SPI)) {
        assert(!strcmp(test, "pass") || !strcmp(test, "no-done") || !strcmp(test, "early-done") ||
               !strcmp(test, "short") || !strcmp(test, "wrong-build") || !strcmp(test, "drop-done") ||
               !strcmp(test, "driver-denies"));
        return MOCK_CTRL;
    }
    if (!strcmp(path, CONFIG_SPI)) return MOCK_CFG;
    if (!strcmp(path, "/dev/mockgpio")) return MOCK_CHIP;
    assert(!strncmp(path, BUNDLE, strlen(BUNDLE)) || !strcmp(path, "/run"));
    assert(!(flags & O_CREAT));
    char redirected[256];
    assert(snprintf(redirected, sizeof redirected, "%s%s", fixture, path) < (int)sizeof redirected);
    return __real_open(redirected, flags);
}

int __wrap_glob(const char *pattern, int flags, int (*error)(const char *, int), glob_t *buf) {
    (void)error;
    assert(!strcmp(pattern, "/dev/gpiochip*") && !flags);
    *buf = (glob_t){.gl_pathc=1, .gl_pathv=calloc(2, sizeof(char *))};
    buf->gl_pathv[0] = strdup("/dev/mockgpio");
    return 0;
}

int __wrap_ioctl(int fd, unsigned long code, ...) {
    va_list ap;
    va_start(ap, code);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (fd == MOCK_CTRL) {
        if (code == SPIBONE_IOC_SET_STATE) {
            assert(*(uint32_t *)arg == SPIBONE_STATE_OFFLINE);
            online = false;
            return 0;
        }
        if (code == SPIBONE_IOC_WING_ENABLE) {
            assert(!online && !probes++ && released && transferred == inputs[1].size);
            assert(*(uint32_t *)arg == FABRIC_BUILD_ID);
            if (!strcmp(test, "driver-denies")) return -1;
            online = true;
            return 0;
        }
        assert(online);
        if (code == SPIBONE_IOC_GET_STATE) {
            *(uint32_t *)arg = SPIBONE_STATE_ONLINE;
            return 0;
        }
        assert(code == SPIBONE_IOC_PEEK && reads < sizeof identity / sizeof *identity);
        struct spibone_wb_xfer *x = arg;
        assert(x->addr == 0x1800 + 4 * reads);
        x->val = identity[reads++].value;
        if (x->addr == 0x1808 && !strcmp(test, "wrong-build")) x->val = 0x2bcf0718u;
        return 0;
    }
    if (fd == MOCK_CFG) {
        if (code == SPI_IOC_WR_MODE32) {
            assert(*(uint32_t *)arg == SPI_NO_CS);
            mode_set = true;
            return 0;
        }
        if (code == SPI_IOC_RD_MODE32) { *(uint32_t *)arg = SPI_NO_CS; return 0; }
        if (code == SPI_IOC_WR_BITS_PER_WORD) { assert(*(uint8_t *)arg == 8); return 0; }
        if (code == SPI_IOC_WR_MAX_SPEED_HZ) { assert(*(uint32_t *)arg == 2000000); return 0; }
        assert(code == SPI_IOC_MESSAGE(1) && mode_set && released && !online && !probes);
        const struct spi_ioc_transfer *x = arg;
        assert(x->len && x->len <= 1024 && x->len <= inputs[1].size-transferred);
        assert(x->speed_hz == 2000000 && x->bits_per_word == 8 && !x->rx_buf && !x->cs_change);
        char path[256];
        assert(snprintf(path, sizeof path, "%s" BUNDLE "wing-fpga.hex.bin", fixture) < (int)sizeof path);
        FILE *file = fopen(path, "rb");
        uint8_t expected[1024];
        assert(file && !fseek(file, (long)transferred, SEEK_SET));
        assert(fread(expected, 1, x->len, file) == x->len);
        fclose(file);
        assert(!memcmp(expected, (const void *)(uintptr_t)x->tx_buf, x->len));
        if (!strcmp(test, "short")) return x->len-1;
        transferred += x->len;
        return x->len;
    }
    if (fd == MOCK_CHIP) {
        if (code == GPIO_V2_GET_LINEINFO_IOCTL) {
            struct gpio_v2_line_info *info = arg;
            assert(info->offset == 17 || info->offset == 26);
            strcpy(info->name, info->offset == 17 ? "T55_CRESET_N" : "T55_CDONE");
            return 0;
        }
        assert(code == GPIO_V2_GET_LINE_IOCTL);
        struct gpio_v2_line_request *req = arg;
        if (req->offsets[0] == 17) {
            assert(req->config.flags == GPIO_V2_LINE_FLAG_OUTPUT && req->config.attrs[0].attr.values == 0);
            assert(mode_set && !online);
            req->fd = MOCK_RESET;
        } else {
            assert(req->offsets[0] == 26 && req->config.flags == GPIO_V2_LINE_FLAG_INPUT);
            req->fd = MOCK_DONE;
        }
        return 0;
    }
    if (fd == MOCK_DONE) {
        assert(code == GPIO_V2_LINE_GET_VALUES_IOCTL);
        struct gpio_v2_line_values *values = arg;
        values->bits = released && (transferred == inputs[1].size || !strcmp(test, "early-done"));
        if (!strcmp(test, "no-done") || (!strcmp(test, "drop-done") && reads == 5)) values->bits = 0;
        return 0;
    }
    assert(fd == MOCK_RESET && code == GPIO_V2_LINE_SET_VALUES_IOCTL && !released);
    assert(((struct gpio_v2_line_values *)arg)->bits == 1);
    released = true;
    return 0;
}

static void inspect_exit(void) {
    assert(!online);
    printf("mock: complete_bytes=%zu probes=%u reads=%u\n", transferred, probes, reads);
}

__attribute__((constructor)) static void setup(void) {
    test = getenv("TEST_CASE");
    fixture = getenv("TEST_FIXTURE");
    const char *prefix = "/dev/shm/wing-id-test.";
    assert(test && fixture && !strncmp(fixture, prefix, strlen(prefix)) && !atexit(inspect_exit));
}
