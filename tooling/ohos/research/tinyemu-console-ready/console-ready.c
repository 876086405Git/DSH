/* Actual product temu translation unit, slirp adapters and initialized VirtIO
 * devices. Only CPU packet generation, the guest console ring and IRQ delivery
 * are declared fixtures. Socket readiness and console reads are real syscalls.
 * Diagnostic auto-variable pattern/UBSan are not production build flags. */
#include "temu.c"
#include "slirp/slirp.h"

static int peer_fd, udp_fd = -1, console_pair[2];
static uint16_t peer_port;
static unsigned batches, select_calls, ready_calls, udp_ready_calls, console_reads;
static Slirp *network;
static struct sockaddr_in reply_address;
static socklen_t reply_address_size;

int __real_select(int, fd_set *, fd_set *, fd_set *, struct timeval *);
int __wrap_select(int count, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    assert(tv && tv->tv_sec == 0 && tv->tv_usec == 0);
    int result = __real_select(count, r, w, e, tv);
    select_calls++;
    assert(result >= 0);
    if (result > 0) ready_calls++;
    if (result > 0 && udp_fd >= 0 && FD_ISSET(udp_fd, r)) udp_ready_calls++;
    return result;
}

static void put16be(uint8_t *p, uint16_t value)
{
    p[0] = value >> 8; p[1] = value;
}

static void cpu_batch(VirtMachine *machine, int count)
{
    assert(count == MAX_EXEC_CYCLE && ++batches <= 2);
    if (batches != 1) return;
    assert(select_calls == 1 && ready_calls == 0);
    uint8_t packet[14 + 20 + 8 + 4] = {0};
    uint8_t *ip = packet + 14, *udp = ip + 20;
    packet[0] = 0x52; packet[1] = 0x55;
    packet[6] = 0x02; packet[11] = 0x01;
    put16be(packet + 12, 0x0800);
    ip[0] = 0x45; put16be(ip + 2, 32); ip[8] = 64; ip[9] = IPPROTO_UDP;
    ip[12] = 10; ip[14] = 2; ip[15] = 15;
    ip[16] = 10; ip[18] = 2; ip[19] = 2;
    unsigned sum = 0;
    for (unsigned i = 0; i < 20; i += 2) sum += (ip[i] << 8) | ip[i + 1];
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    put16be(ip + 10, (uint16_t)~sum);
    put16be(udp, 30002); put16be(udp + 2, peer_port); put16be(udp + 4, 12);
    memcpy(udp + 8, "ping", 4);
    machine->net->write_packet(machine->net, packet, sizeof(packet));
    assert(network->udb.so_next != &network->udb);
    struct socket *so = network->udb.so_next;
    assert(so->so_lport == htons(30002) && so->so_fport == htons(peer_port));
    udp_fd = so->s;
    char payload[8];
    reply_address_size = sizeof(reply_address);
    assert(recvfrom(peer_fd, payload, sizeof(payload), MSG_DONTWAIT,
                    (void *)&reply_address, &reply_address_size) == 4);
    assert(!memcmp(payload, "ping", 4));
}

static int no_sleep(VirtMachine *machine, int maximum)
{
    (void)machine; assert(maximum == MAX_SLEEP_TIME); return 0;
}

static void irq_boundary(void *opaque, int number, int level)
{
    (void)opaque; assert((number == 1 || number == 2) && (level == 0 || level == 1));
}

ssize_t __real_recv(int, void *, size_t, int);
ssize_t __wrap_recv(int fd, void *buffer, size_t length, int flags)
{
    if (fd == console_pair[0]) console_reads++;
    return __real_recv(fd, buffer, length, flags);
}

static void mmio_write(PhysMemoryRange *range, uint32_t offset, uint32_t value)
{
    range->write_func(range->opaque, offset, value, 2);
}

static uint8_t *prepare_console_ring(PhysMemoryMap *map, uint64_t device, int available)
{
    const uint64_t address = UINT64_C(0x80000000);
    PhysMemoryRange *ram = cpu_register_ram(map, address, 4096, 0);
    assert(ram && ram->phys_mem);
    uint8_t *data = ram->phys_mem;
    memset(data, 0, 4096);
    put_le64(data, address + 0x300);
    put_le32(data + 8, 4);
    put_le16(data + 12, 2); /* VIRTQ_DESC_F_WRITE. */
    put_le16(data + 0x102, available ? 1 : 0);
    put_le16(data + 0x104, 0);
    PhysMemoryRange *range = get_phys_mem_range(map, device);
    assert(range && !range->is_ram);
    mmio_write(range, 0x070, 1);  /* ACKNOWLEDGE */
    mmio_write(range, 0x070, 3);  /* DRIVER */
    mmio_write(range, 0x030, 0);  /* RX queue */
    mmio_write(range, 0x038, 8);
    mmio_write(range, 0x080, (uint32_t)address);
    mmio_write(range, 0x084, 0);
    mmio_write(range, 0x090, (uint32_t)(address + 0x100));
    mmio_write(range, 0x094, 0);
    mmio_write(range, 0x0a0, (uint32_t)(address + 0x200));
    mmio_write(range, 0x0a4, 0);
    mmio_write(range, 0x044, 1);
    mmio_write(range, 0x070, 15); /* DRIVER_OK and FEATURES_OK. */
    return data;
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    const char *name = argv[1];
    int empty = !strcmp(name, "queue-empty");
    int no_ready = !strcmp(name, "no-ready");
    int no_console = !strcmp(name, "no-console");
    int console_only = !strcmp(name, "console-ready");
    int both = !strcmp(name, "both-ready");
    int eof = !strcmp(name, "console-eof");
    assert(!strcmp(name, "queue-unready") || empty || no_ready || no_console || console_only || both || eof);
    int rx_descriptor = console_only || both || eof;
    int send_reply = !no_ready && !console_only && !eof;

    embed_controlled = 1; /* Exercise the real raw controlled-console path. */
    EthernetDevice *net = slirp_open(); assert(net);
    network = net->opaque;
    PhysMemoryMap *map = phys_mem_map_init(); assert(map);
    IRQSignal network_irq, console_irq;
    irq_init(&network_irq, irq_boundary, NULL, 1);
    irq_init(&console_irq, irq_boundary, NULL, 2);
    VIRTIOBusDef bus = {.mem_map = map, .addr = UINT64_C(0x10000000), .irq = &network_irq};
    VIRTIODevice *net_device = virtio_net_init(&bus, net); assert(net_device);
    assert(!net->device_can_write_packet(net));
    assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, console_pair) == 0);
    STDIODevice transport = {.stdin_fd = console_pair[0]};
    CharacterDevice character = {.opaque = &transport, .read_data = console_read,
                                  .write_data = console_write};
    bus.addr += 0x1000; bus.irq = &console_irq;
    VIRTIODevice *console = virtio_console_init(&bus, &character); assert(console);
    assert(!virtio_console_can_write_data(console) && virtio_console_get_write_len(console) == 0);
    uint8_t *ring = NULL;
    if (rx_descriptor || empty) ring = prepare_console_ring(map, bus.addr, rx_descriptor);
    assert(virtio_console_can_write_data(console) == rx_descriptor);
    assert(virtio_console_get_write_len(console) == (rx_descriptor ? 4 : 0));

    peer_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0); assert(peer_fd >= 0);
    struct sockaddr_in peer = {.sin_family = AF_INET, .sin_addr = {htonl(INADDR_LOOPBACK)}};
    assert(bind(peer_fd, (void *)&peer, sizeof(peer)) == 0);
    socklen_t size = sizeof(peer); assert(getsockname(peer_fd, (void *)&peer, &size) == 0);
    peer_port = ntohs(peer.sin_port);
    const VirtMachineClass klass = {.machine_names = "explicit-two-packet-batches",
        .virt_machine_get_sleep_duration = no_sleep, .virt_machine_interp = cpu_batch};
    VirtMachine machine = {.vmc = &klass, .net = net, .console = &character,
                           .console_dev = no_console ? NULL : console};
    virt_machine_run(&machine);
    assert(batches == 1 && select_calls == 1 && console_reads == 0);
    if (send_reply) {
        assert(sendto(peer_fd, "pong", 4, 0, (void *)&reply_address, reply_address_size) == 4);
        char peek[8]; assert(recv(udp_fd, peek, sizeof(peek), MSG_PEEK | MSG_DONTWAIT) == 4);
        assert(!memcmp(peek, "pong", 4));
    }
    if (console_only || both) assert(write(console_pair[1], "cns!", 4) == 4);
    if (eof) assert(shutdown(console_pair[1], SHUT_WR) == 0);
    fprintf(stderr, "before second loop: case=%s actual-udp-ready=%d console-rx=%d\n",
            name, send_reply, rx_descriptor);
    virt_machine_run(&machine);
    assert(batches == 2 && select_calls == 2);
    assert(udp_ready_calls == (unsigned)send_reply);
    assert(ready_calls == (unsigned)(send_reply || rx_descriptor));
    assert(console_reads == (unsigned)rx_descriptor);
    struct socket *so = network->udb.so_next;
    assert(so != &network->udb && so->s == udp_fd);
    assert(so->so_queued == send_reply && network->if_queued == send_reply);
    char peek[8]; errno = 0;
    assert(recv(udp_fd, peek, sizeof(peek), MSG_PEEK | MSG_DONTWAIT) == -1 && errno == EAGAIN);
    if (console_only || both) {
        assert(!memcmp(ring + 0x300, "cns!", 4));
        assert(get_le16(ring + 0x202) == 1);
        assert(get_le32(ring + 0x208) == 4);
        assert(!virtio_console_can_write_data(console));
    }
    if (eof) assert(get_le16(ring + 0x202) == 0 && virtio_console_can_write_data(console));
    assert(embed_input_failed == eof);
    printf("{\"case\":\"%s\",\"passed\":true,\"selectCalls\":%u,\"actualReadyCalls\":%u,\"actualUdpReadyCalls\":%u,\"cpuBatches\":%u,\"consoleReads\":%u,\"queuedReplyPackets\":%d,\"guestInstructions\":false}\n",
           name, select_calls, ready_calls, udp_ready_calls, batches, console_reads, so->so_queued);
    /* Each case is a separate process. No polling or final product shutdown is
       inferred from the process-local network queue retained at this boundary. */
    close(peer_fd); close(console_pair[0]); close(console_pair[1]); close(udp_fd);
    return 0;
}
