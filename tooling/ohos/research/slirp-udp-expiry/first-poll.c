/* Compile the actual product translation unit so its private slirp_open and
 * network adapters participate. Only the post-poll CPU batch is a test class;
 * it emits a declared Ethernet/IPv4/UDP packet, not guest instructions. */
#include "temu.c"
#include "slirp/slirp.h"
#include <stddef.h>

static uint64_t fixture_ms;
static unsigned clock_reads, select_calls, batches;
static int peer_fd, timed_fd;
static uint16_t peer_port;
static Slirp *network;

int controlled_clock(clockid_t id, struct timespec *value)
{
    assert(id == CLOCK_MONOTONIC);
    value->tv_sec = fixture_ms / 1000;
    value->tv_nsec = (fixture_ms % 1000) * 1000000;
    clock_reads++;
    return 0;
}

int __real_select(int, fd_set *, fd_set *, fd_set *, struct timeval *);
int __wrap_select(int count, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    assert(tv->tv_sec == 0 && tv->tv_usec == 0);
    select_calls++;
    return __real_select(count, r, w, e, tv);
}

static void put16(uint8_t *p, uint16_t value)
{
    p[0] = value >> 8; p[1] = value;
}

static void first_batch(VirtMachine *machine, int count)
{
    assert(count == MAX_EXEC_CYCLE && ++batches == 1);
    assert(select_calls == 1 && clock_reads == 1);
    assert(curtime == (uint32_t)fixture_ms);
    /* IPv4 checksum is real; UDP checksum zero is permitted for IPv4. */
    uint8_t packet[14 + 20 + 8 + 4] = {0};
    uint8_t *ip = packet + 14, *udp = ip + 20;
    packet[0] = 0x52; packet[1] = 0x55;
    packet[6] = 0x02; packet[11] = 0x01;
    put16(packet + 12, 0x0800);
    ip[0] = 0x45; put16(ip + 2, 32); ip[8] = 64; ip[9] = IPPROTO_UDP;
    ip[12] = 10; ip[14] = 2; ip[15] = 15;
    ip[16] = 10; ip[18] = 2; ip[19] = 2;
    unsigned sum = 0;
    for (unsigned i = 0; i < 20; i += 2) sum += (ip[i] << 8) | ip[i + 1];
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    put16(ip + 10, (uint16_t)~sum);
    put16(udp, 30002); put16(udp + 2, peer_port); put16(udp + 4, 12);
    memcpy(udp + 8, "ping", 4);
    machine->net->write_packet(machine->net, packet, sizeof(packet));
    assert(network->udb.so_next != &network->udb);
    struct socket *so = network->udb.so_next;
    assert(so->so_lport == htons(30002) && so->so_fport == htons(peer_port));
    timed_fd = so->s;
    char payload[8];
    assert(recv(peer_fd, payload, sizeof(payload), MSG_DONTWAIT) == 4);
    assert(!memcmp(payload, "ping", 4));
}

static int no_sleep(VirtMachine *machine, int maximum)
{
    (void)machine; assert(maximum == MAX_SLEEP_TIME); return 0;
}

static int listed(int fd)
{
    for (struct socket *so = network->udb.so_next; so != &network->udb; so = so->so_next)
        if (so->s == fd) return 1;
    return 0;
}

static void update_and_fill(uint64_t now)
{
    fd_set r, w, e; FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e);
    fixture_ms = now; unsigned before = clock_reads;
    slirp_select_poll(network, &r, &w, &e, 1);
    assert(clock_reads == before + 1 && curtime == (uint32_t)now);
    int maximum = -1;
    slirp_select_fill(network, &maximum, &r, &w, &e);
}

int main(void)
{
    const uint64_t first_time = UINT64_C(0x200000000) + 12345;
    fixture_ms = first_time;
    assert(clock_reads == 0 && curtime == 0);
    EthernetDevice *net = slirp_open(); assert(net);
    network = net->opaque;
    assert(network->udb.so_next == &network->udb && clock_reads == 0);
    peer_fd = socket(AF_INET, SOCK_DGRAM, 0); assert(peer_fd >= 0);
    struct sockaddr_in peer = {.sin_family = AF_INET, .sin_addr = {htonl(INADDR_LOOPBACK)}, .sin_port = 0};
    assert(bind(peer_fd, (void *)&peer, sizeof(peer)) == 0);
    socklen_t length = sizeof(peer);
    assert(getsockname(peer_fd, (void *)&peer, &length) == 0);
    peer_port = ntohs(peer.sin_port);
    const VirtMachineClass klass = {.machine_names = "explicit-after-poll-packet",
        .virt_machine_get_sleep_duration = no_sleep, .virt_machine_interp = first_batch};
    VirtMachine machine = {.vmc = &klass, .net = net};
    virt_machine_run(&machine);
    assert(batches == 1 && listed(timed_fd) && fcntl(timed_fd, F_GETFD) >= 0);
    update_and_fill(first_time + SO_EXPIRE - 1);
    assert(listed(timed_fd) && fcntl(timed_fd, F_GETFD) >= 0);
    update_and_fill(first_time + SO_EXPIRE);
    errno = 0;
    assert(!listed(timed_fd) && fcntl(timed_fd, F_GETFD) == -1 && errno == EBADF);
    printf("{\"case\":\"first-product-poll-before-guest-packet\",\"passed\":true,\"firstMonotonicMs\":%llu,\"firstPollClockReads\":1,\"actualSelectCalls\":%u,\"actualUdpPayloadBytes\":4,\"socketBytes\":%zu,\"slirpBytes\":%zu,\"scope\":\"actual loop and slirp adapters; explicit CPU packet producer, not guest instructions\"}\n",
           (unsigned long long)first_time, select_calls, sizeof(struct socket), sizeof(Slirp));
    close(peer_fd); slirp_cleanup(network); free(net);
    return 0;
}
