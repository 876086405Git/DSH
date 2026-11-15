/* Real file I/O through the complete production TinyEMU sources. The only
   device substitute is bounded RAM/IRQ storage; no CPU or guest is started. */
#include <errno.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include "temu.c"
#include "virtio.c"
#include "slirp/libslirp.h"

/* This block-only fixture starts no CPU/network. The full production temu.c
   retains the slirp callback address for its event-wait identity check. Keep
   the real header ABI, but fail if that unrelated callback is ever entered. */
void slirp_select_fill(Slirp *slirp, int *pnfds,
                       fd_set *readfds, fd_set *writefds, fd_set *xfds)
{
    (void)slirp; (void)pnfds; (void)readfds; (void)writefds; (void)xfds;
    fputs("unexpected slirp_select_fill in block-only fixture\n", stderr);
    abort();
}

static uint8_t ram[32768];
static int irq_level;
static uint8_t *test_ram(VIRTIODevice *s, virtio_phys_addr_t address, BOOL write)
{
    (void)s; (void)write;
    return address < sizeof(ram) ? ram + address : NULL;
}
static void test_irq(void *opaque, int number, int level)
{
    (void)opaque; (void)number; irq_level = level;
}

static int queue_write(BlockDevice *bs, uint64_t sector, const uint8_t *data, int bytes)
{
    VIRTIOBlockDevice device = {0};
    IRQSignal irq = {.set_irq = test_irq};
    device.bs = bs; device.common.get_ram_ptr = test_ram; device.common.irq = &irq;
    device.common.queue[0] = (QueueState){.ready = 1, .num = 8, .desc_addr = 256,
        .avail_addr = 1024, .used_addr = 1536};
    BlockRequestHeader header = {.type = VIRTIO_BLK_T_OUT, .sector_num = sector};
    VIRTIODesc descriptors[] = {
        {.addr = 4096, .len = sizeof(header), .flags = VRING_DESC_F_NEXT, .next = 1},
        {.addr = 8192, .len = bytes, .flags = VRING_DESC_F_NEXT, .next = 2},
        {.addr = 28672, .len = 1, .flags = VRING_DESC_F_WRITE},
    };
    memset(ram, 0, sizeof(ram)); irq_level = 0;
    memcpy(ram + 256, descriptors, sizeof(descriptors));
    memcpy(ram + 4096, &header, sizeof(header)); memcpy(ram + 8192, data, bytes);
    ram[28672] = 255;
    int result = virtio_block_recv_request(&device.common, 0, 0, sizeof(header) + bytes, 1);
    if (result || get_le16(ram + 1538) != 1 || get_le32(ram + 1544) != 1 || irq_level != 1)
        return -2;
    return ram[28672];
}

int main(int argc, char **argv)
{
    if (argc != 3) return 90;
    const char *mode = argv[1], *path = argv[2];
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0 || ftruncate(fd, 8192) || close(fd)) return 91;
    int readonly = !strcmp(mode, "readonly"), delayed = !strcmp(mode, "buffered-flush");
    int limited = !strcmp(mode, "efbig") || !strcmp(mode, "short-write") ||
        !strcmp(mode, "virtio-efbig") || delayed;
    BlockDeviceFile buffered = {0}; BlockDevice buffered_device = {.opaque = &buffered};
    char stdio_buffer[16384];
    BlockDevice *bs;
    if (delayed) {
        buffered.f = fopen(path, "r+b"); buffered.mode = BF_MODE_RW; buffered.nb_sectors = 16;
        if (!buffered.f || setvbuf(buffered.f, stdio_buffer, _IOFBF, sizeof(stdio_buffer))) return 92;
        bs = &buffered_device;
    } else {
        bs = block_device_try_init(path, readonly ? BF_MODE_RO : BF_MODE_RW);
        if (!bs) return 92;
    }
    BlockDeviceFile *bf = bs->opaque;
    int file_fd = fileno(bf->f);
    if (limited) {
        struct rlimit limit;
        if (getrlimit(RLIMIT_FSIZE, &limit)) return 93;
        limit.rlim_cur = 4096;
        if (setrlimit(RLIMIT_FSIZE, &limit) || signal(SIGXFSZ, SIG_IGN) == SIG_ERR) return 94;
    }
    uint8_t data[8192]; memset(data, 0x5a, sizeof(data));
    int sectors = !strcmp(mode, "short-write") ? 16 : delayed ? 1 : 8;
    uint64_t sector = limited && strcmp(mode, "short-write") ? 8 : 0;
    if (!strcmp(mode, "seek-error")) sector = UINT64_C(1) << 54;
    int virtio = !strncmp(mode, "virtio-", 7);
    errno = 0;
    int result = virtio ? queue_write(bs, sector, data, sectors * 512) :
        bf_write_async(bs, sector, data, sectors, NULL, NULL);
    int write_errno = errno, prior_error = ferror(bf->f), retry = 0;
    if (!strcmp(mode, "seek-error")) retry = bf_write_async(bs, 0, data, 1, NULL, NULL);
    errno = 0; int retired = block_device_file_retire(bs), retire_errno = errno;
    int retired_again = block_device_file_retire(bs);
    errno = 0; int file_closed = fcntl(file_fd, F_GETFD) < 0 && errno == EBADF;
    uint8_t actual[8192]; struct stat st;
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0 || fstat(fd, &st) || read(fd, actual, sizeof(actual)) != sizeof(actual) || close(fd)) return 95;
    int changed = 0;
    for (unsigned i = 0; i < sizeof(actual); i++) if (actual[i] == 0x5a) changed++;
    int normal = !strcmp(mode, "normal") || !strcmp(mode, "virtio-ok");
    int pass;
    if (normal) pass = result == 0 && prior_error == 0 && retired == 0 && changed == 4096;
    else if (readonly) pass = result < 0 && retired == 0 && changed == 0;
    else if (delayed) pass = result == 0 && prior_error == 0 && retired < 0 && changed == 0;
    else if (!strcmp(mode, "seek-error")) pass = result < 0 && retry < 0 && prior_error == 0 && retired < 0 && changed == 0;
    else pass = (virtio ? result == VIRTIO_BLK_S_IOERR : result < 0) && prior_error && retired < 0 &&
        changed == (!strcmp(mode, "short-write") ? 4096 : 0);
    pass = pass && retired_again == retired && bf->f == NULL && file_closed && st.st_size == 8192;
    printf("{\"case\":\"%s\",\"passed\":%s,\"writeResult\":%d,\"writeErrno\":%d,"
        "\"priorStreamError\":%d,\"retryResult\":%d,\"retireResult\":%d,\"retireErrno\":%d,"
        "\"retireAgain\":%d,\"changedBytes\":%d,\"size\":%lld,\"fileDetached\":%s,\"fileClosed\":%s}\n",
        mode, pass ? "true" : "false", result, write_errno, prior_error, retry, retired, retire_errno,
        retired_again, changed, (long long)st.st_size, bf->f == NULL ? "true" : "false", file_closed ? "true" : "false");
    return pass ? 0 : 1;
}
