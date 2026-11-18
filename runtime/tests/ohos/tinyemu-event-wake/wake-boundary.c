/* Actual CPU/CLINT, actual run loop and actual slirp remaining helper.
 * One finite deterministic boundary per process. select and the following CPU
 * batch are explicit seams; real C-entry/kernel waits are in wake-call.c. */
#define main saved_clock_main
#include "clock-cpu.c"
#undef main
#include "slirp/slirp.h"
#include "temu_embed.h"
#include <limits.h>

extern void probe_begin_wake(int fd);
extern void probe_end_wake(void);
extern EthernetDevice *probe_slirp_open(void);
extern void virt_machine_run(VirtMachine *m);

static int selected, requested_us, wake_in_set, reads_at_select, batches;
static int test_wake_fd;
static void after_batch(RISCVCPUState *cpu, int count)
{
    (void)cpu; assert(count == 500000); batches++;
}
int controlled_slirp_clock(clockid_t id, struct timespec *ts)
{
    return controlled_clock(id, ts);
}
int __wrap_select(int count, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    selected++; requested_us = (int)(tv->tv_sec * 1000000 + tv->tv_usec);
    reads_at_select = tick_reads;
    wake_in_set = test_wake_fd >= 0 && count > test_wake_fd && FD_ISSET(test_wake_fd, r);
    FD_ZERO(r); FD_ZERO(w); FD_ZERO(e); return 0;
}
static int can_output(EthernetDevice *net) { (void)net; return 1; }
static void output_packet(EthernetDevice *net, const uint8_t *p, int length)
{
    (void)net; (void)p; (void)length;
}
static void put16(uint8_t *p, uint16_t n) { p[0] = n >> 8; p[1] = n; }
static void put32(uint8_t *p, uint32_t n) { put16(p, n >> 16); put16(p + 2, n); }
static uint16_t checksum(const uint8_t *p, size_t size)
{
    unsigned sum = 0;
    for (size_t i = 0; i < size; i += 2) sum += (p[i] << 8) | p[i + 1];
    while (sum >> 16) sum = (sum & 65535) + (sum >> 16);
    return ~sum;
}
static void poll_at(Slirp *s, uint64_t ticks_now)
{
    fd_set r, w, e; FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e);
    set_ticks(&ticks_now, 1); slirp_select_poll(s, &r, &w, &e, 1);
}
static void fill_now(Slirp *s)
{
    fd_set r, w, e; FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e); int fd = -1;
    slirp_select_fill(s, &fd, &r, &w, &e);
}
static void add_fragment(EthernetDevice *net)
{
    uint8_t frame[50] = {0}, *ip = frame + 14, *udp = ip + 20;
    frame[6] = 0x52; frame[7] = 0x54; frame[11] = 0x56;
    put16(frame + 12, 0x0800); ip[0] = 0x45; put16(ip + 2, 36);
    put16(ip + 4, 91); put16(ip + 6, 0x2000); ip[8] = 64; ip[9] = IPPROTO_UDP;
    put32(ip + 12, 0x0a00020f); put32(ip + 16, 0x0a000202); put16(ip + 10, checksum(ip, 20));
    put16(udp, 30004); put16(udp + 2, 49000); put16(udp + 4, 24);
    memcpy(udp + 8, "fragment", 8); net->write_packet(net, frame, sizeof(frame));
}

int main(int argc, char **argv)
{
    assert(argc == 2); const char *name = argv[1];
    RISCVMachine *m = machine(64);
    uint64_t now = 100, compare = UINT64_MAX;
    int expected = (INT_MAX / 1000) * 1000, waiting = 1, pending = 0, legacy = 0, network = 0;
    if (!strcmp(name, "submicro")) { compare = now + 9; expected = 0; }
    else if (!strcmp(name, "micro-floor")) { compare = now + 19; expected = 1; }
    else if (!strcmp(name, "due")) { compare = now; expected = 0; }
    else if (!strcmp(name, "non-wfi")) { waiting = 0; expected = 0; }
    else if (!strcmp(name, "masked-mtip")) { pending = 1; compare = now; }
    else if (!strcmp(name, "legacy")) { legacy = 1; expected = 10000; }
    else if (!strcmp(name, "fragment-common-sample")) { network = 1; now = 9985000; compare = now + 10000; expected = 500; }
    else if (!strcmp(name, "permanent-udp")) { network = 2; now = 10000000; }
    else assert(!strcmp(name, "distant-future"));
    m->timecmp = compare;
    const uint32_t wfi[] = {0x10500073};
    if (waiting) assert(execute(m, wfi, 1));
    if (pending) riscv_cpu_set_mip(m->cpu_state, MIP_MTIP);
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    test_wake_fd = legacy ? -1 : pair[0]; probe_begin_wake(test_wake_fd);
    if (network) {
        EthernetDevice *net = probe_slirp_open(); assert(net);
        net->device_can_write_packet = can_output; net->device_write_packet = output_packet;
        m->common.net = net; Slirp *slirp = net->opaque;
        poll_at(slirp, 5000000);
        if (network == 1) {
            add_fragment(net);
            assert(slirp->ipq.ip_link.next != &slirp->ipq.ip_link);
            assert(slirp->tcb.so_next == &slirp->tcb && slirp->udb.so_next == &slirp->udb);
            fill_now(slirp); poll_at(slirp, 5000000);
        } else {
            struct in_addr host = {.s_addr = htonl(INADDR_LOOPBACK)}, guest = {.s_addr = htonl(0x0a00020f)};
            assert(slirp_add_hostfwd(slirp, 1, host, 0, guest, 20000) == 0);
            assert(slirp->udb.so_next != &slirp->udb && !so_has_expiry(slirp->udb.so_next));
        }
    }
    set_ticks(&now, 1);
    RISCVCPUCommonState *cpu = (RISCVCPUCommonState *)m->cpu_state;
    const RISCVCPUClass *original = cpu->class_ptr;
    RISCVCPUClass observed = *original; observed.riscv_cpu_interp = after_batch; cpu->class_ptr = &observed;
    virt_machine_run((VirtMachine *)m);
    cpu->class_ptr = original;
    int passed = selected == 1 && requested_us == expected && batches == 1 && !dsh_temu_wait_error
        && reads_at_select == 1 && wake_in_set == !legacy;
    if (!strcmp(name, "due")) passed &= !!(riscv_cpu_get_mip(m->cpu_state) & MIP_MTIP);
    printf("{\"case\":\"%s\",\"requestedUs\":%d,\"expectedUs\":%d,\"commonClockReadsBeforeSelect\":%d,\"totalClockReads\":%u,\"wakeFdInSet\":%s,\"batches\":%d,\"passed\":%s}\n",
        name, requested_us, expected, reads_at_select, tick_reads, wake_in_set ? "true" : "false", batches, passed ? "true" : "false");
    probe_end_wake();
    close(pair[0]); close(pair[1]); riscv_machine_end((VirtMachine *)m);
    return !passed;
}
