/* Real slirp TCP/loopback; guest Ethernet packets and monotonic time are explicit fixtures. */
#include "slirp/slirp.h"
#include <assert.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>

static uint64_t fixture_ms;
static unsigned clock_reads, tcp_packets;
static int select_failure;
static uint32_t syn_seq, last_ack;
static int got_syn;
static const uint8_t guest_mac[6] = {0x52,0x54,0,0x12,0x34,0x56};

int controlled_clock(clockid_t id, struct timespec *ts)
{
    assert(id == CLOCK_MONOTONIC);
    ts->tv_sec = fixture_ms / 1000;
    ts->tv_nsec = (fixture_ms % 1000) * 1000000;
    clock_reads++;
    return 0;
}
static void put16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
static void put32(uint8_t *p, uint32_t v) { put16(p, v >> 16); put16(p + 2, v); }
static uint32_t get32(const uint8_t *p)
{ return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t checksum(const uint8_t *p, size_t n)
{
    uint32_t sum = 0;
    for (; n >= 2; p += 2, n -= 2) sum += (uint16_t)p[0] << 8 | p[1];
    if (n) sum += (uint16_t)p[0] << 8;
    while (sum >> 16) sum = (sum & 65535) + (sum >> 16);
    return ~sum;
}
int slirp_can_output(void *opaque) { (void)opaque; return 1; }
void slirp_output(void *opaque, const uint8_t *packet, int len)
{
    (void)opaque;
    assert(packet && len >= 14);
    if (packet[12] != 8 || packet[13] != 0 || packet[23] != IPPROTO_TCP) return;
    unsigned off = 14 + (packet[14] & 15) * 4;
    assert(len >= (int)off + 20);
    const uint8_t *tcp = packet + off;
    tcp_packets++;
    last_ack = get32(tcp + 8);
    if ((tcp[13] & (TH_SYN | TH_ACK)) == (TH_SYN | TH_ACK)) {
        syn_seq = get32(tcp + 4);
        got_syn = 1;
    }
}
static Slirp *new_slirp(void)
{
    struct in_addr network={htonl(0x0a000200)}, mask={htonl(0xffffff00)},
        host={htonl(0x0a000202)}, guest={htonl(0x0a00020f)}, dns={htonl(0x0a000203)};
    Slirp *s = slirp_init(0, network, mask, host, NULL, NULL, NULL, guest, dns, NULL);
    assert(s);
    uint8_t arp[42] = {0};
    memset(arp, 255, 6); memcpy(arp + 6, guest_mac, 6); put16(arp + 12, 0x0806);
    put16(arp + 14, 1); put16(arp + 16, 0x0800); arp[18] = 6; arp[19] = 4;
    put16(arp + 20, 1); memcpy(arp + 22, guest_mac, 6); put32(arp + 28, 0x0a00020f);
    put32(arp + 38, 0x0a000202); slirp_input(s, arp, sizeof(arp));
    assert(memcmp(s->client_ethaddr, guest_mac, 6) == 0);
    return s;
}
static void packet(Slirp *s, uint16_t port, uint32_t seq, uint32_t ack,
                   unsigned flags, uint16_t window, const char *data, size_t size)
{
    uint8_t frame[1600] = {0}, pseudo[1600] = {0};
    assert(size < 1400);
    memcpy(frame + 6, guest_mac, 6); put16(frame + 12, 0x0800);
    uint8_t *ip = frame + 14, *tcp = ip + 20;
    ip[0] = 0x45; put16(ip + 2, 40 + size); put16(ip + 4, 1); ip[8] = 64;
    ip[9] = IPPROTO_TCP; put32(ip + 12, 0x0a00020f); put32(ip + 16, 0x0a000202);
    put16(ip + 10, checksum(ip, 20));
    put16(tcp, 30001); put16(tcp + 2, port); put32(tcp + 4, seq); put32(tcp + 8, ack);
    tcp[12] = 5 << 4; tcp[13] = flags; put16(tcp + 14, window);
    if (size) memcpy(tcp + 20, data, size);
    memcpy(pseudo, ip + 12, 8); pseudo[9] = IPPROTO_TCP; put16(pseudo + 10, 20 + size);
    memcpy(pseudo + 12, tcp, 20 + size); put16(tcp + 16, checksum(pseudo, 32 + size));
    slirp_input(s, frame, 54 + size);
}
static void clock_at(Slirp *s, uint64_t now)
{
    fixture_ms = now; clock_reads = 0;
    fd_set r,w,e; FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e);
    slirp_select_poll(s, &r, &w, &e, select_failure);
    assert(clock_reads == 1 && curtime == (uint32_t)now);
}
static void fill(Slirp *s)
{
    fd_set r,w,e; FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e); int highest = -1;
    slirp_select_fill(s, &highest, &r, &w, &e);
}
static void turn(Slirp *s)
{
    fd_set r,w,e; FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e); int highest = -1;
    slirp_select_fill(s, &highest, &r, &w, &e);
    struct timeval wait = {.tv_sec=0,.tv_usec=10000};
    int n = select(highest + 1, &r, &w, &e, &wait); assert(n >= 0);
    slirp_select_poll(s, &r, &w, &e, 0);
}
int main(int argc, char **argv)
{
    assert(argc == 5);
    uint64_t start = strtoull(argv[1], NULL, 0); assert(start >= 20);
    unsigned step = (unsigned)strtoul(argv[2], NULL, 0); assert(step == 1 || step == 10);
    const char *mode = argv[3];
    assert(!strcmp(mode, "normal") || !strcmp(mode, "closed") || !strcmp(mode, "repeat") || !strcmp(mode, "second"));
    select_failure = atoi(argv[4]); assert(select_failure == 0 || select_failure == 1);
    assert(strcmp(mode, "second") || step == 1);
    fixture_ms = start - 20;
    Slirp *s = new_slirp(); clock_at(s, fixture_ms);
    int listener = socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
    struct sockaddr_in address = {.sin_family=AF_INET,.sin_addr={htonl(INADDR_LOOPBACK)}};
    assert(bind(listener, (void *)&address, sizeof(address)) == 0); assert(listen(listener, 1) == 0);
    socklen_t length = sizeof(address); assert(getsockname(listener, (void *)&address, &length) == 0);
    assert(fcntl(listener, F_SETFL, O_NONBLOCK) == 0);
    uint16_t port = ntohs(address.sin_port);
    packet(s, port, 1000, 0, TH_SYN, 65535, NULL, 0);
    for (unsigned i = 0; !got_syn && i < 20; i++) turn(s);
    assert(got_syn);
    int peer = accept(listener, NULL, NULL); assert(peer >= 0);
    packet(s, port, 1001, syn_seq + 1, TH_ACK, 65535, NULL, 0);
    struct socket *so = s->tcb.so_next; assert(so != &s->tcb && so->so_next == &s->tcb);
    struct tcpcb *tp = so->so_tcpcb; assert(tp->t_state == TCPS_ESTABLISHED);
    assert(!(tp->t_flags & TF_DELACK));
    unsigned idle_before = tcp_packets;
    fill(s); clock_at(s, start);
    assert(!(tp->t_flags & TF_DELACK) && tcp_packets == idle_before);
    unsigned before = tcp_packets;
    packet(s, port, 1001, syn_seq + 1, TH_ACK, 60000, "data", 4);
    unsigned armed = !!(tp->t_flags & TF_DELACK), after_input = tcp_packets;
    char bytes[4]; struct pollfd fd = {.fd=peer,.events=POLLIN}; assert(poll(&fd,1,1000)==1);
    assert(recv(peer, bytes, sizeof(bytes), MSG_WAITALL) == 4 && !memcmp(bytes, "data", 4));
    fill(s);
    if (!strcmp(mode, "closed")) {
        assert(armed && after_input == before);
        tcp_close(tp);
        clock_at(s, start + 3);
        int passed = s->tcb.so_next == &s->tcb && tcp_packets == before;
        printf("{\"startMs\":%llu,\"stepMs\":%u,\"mode\":\"closed\",\"selectError\":%d,\"realTcpData\":true,\"noStaleTcpOutput\":%s,\"passed\":%s}\n", (unsigned long long)start, step, select_failure, passed?"true":"false", passed?"true":"false");
        close(peer); close(listener); slirp_cleanup(s); return !passed;
    }
    clock_at(s, start + step);
    unsigned first_pending = !!(tp->t_flags & TF_DELACK), first_count = tcp_packets;
    uint32_t expected_ack = 1005;
    if (!strcmp(mode, "second")) {
        packet(s, port, 1005, syn_seq + 1, TH_ACK, 59999, "more", 4);
        assert(tp->t_flags & TF_DELACK);
        assert(poll(&fd,1,1000)==1);
        assert(recv(peer, bytes, sizeof(bytes), MSG_WAITALL)==4 && !memcmp(bytes,"more",4));
        expected_ack = 1009;
    }
    fill(s); clock_at(s, start + 2 * step);
    unsigned second_pending = !!(tp->t_flags & TF_DELACK), second_count = tcp_packets;
    fill(s); clock_at(s, start + 3 * step);
    unsigned third_pending = !!(tp->t_flags & TF_DELACK), third_count = tcp_packets;
    int passed = armed && after_input == before && first_pending == (step < 2)
        && first_count == before + (step >= 2) && !second_pending && !third_pending
        && second_count == before + 1 && third_count == before + 1 && last_ack == expected_ack;
    unsigned repeated = 0;
    if (!strcmp(mode, "repeat")) {
        clock_at(s, start + 4 * step);
        unsigned again_before = tcp_packets;
        packet(s, port, 1005, syn_seq + 1, TH_ACK, 59999, "more", 4);
        assert(tp->t_flags & TF_DELACK);
        assert(poll(&fd,1,1000)==1);
        assert(recv(peer, bytes, sizeof(bytes), MSG_WAITALL)==4 && !memcmp(bytes,"more",4));
        fill(s); clock_at(s, start + 4 * step + 1);
        int still_pending = !!(tp->t_flags & TF_DELACK);
        fill(s); clock_at(s, start + 4 * step + 2);
        repeated = still_pending && !(tp->t_flags & TF_DELACK)
            && tcp_packets == again_before + 1 && last_ack == 1009;
        passed &= repeated;
    }
    printf("{\"startMs\":%llu,\"stepMs\":%u,\"mode\":\"%s\",\"selectError\":%d,\"armedByRealTcpInput\":%u,\"pendingFirst\":%u,\"pendingSecond\":%u,\"pendingThird\":%u,\"packetsBefore\":%u,\"packetsAfterInput\":%u,\"packetsFirst\":%u,\"packetsSecond\":%u,\"packetsThird\":%u,\"lastAck\":%u,\"repeatPassed\":%u,\"passed\":%s}\n", (unsigned long long)start, step, mode, select_failure, armed, first_pending, second_pending, third_pending, before, after_input, first_count, second_count, third_count, last_ack, repeated, passed?"true":"false");
    tcp_close(tp); close(peer); close(listener); slirp_cleanup(s);
    return !passed;
}
