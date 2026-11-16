/* 1247 actual slirp deadline component. Explicit frames/clock/output capacity.
 * Original branch has no new helper; its existing TCP poll red stays separate. */
#define main saved_tcp_wire_main
#define slirp_output saved_tcp_wire_output
#define slirp_can_output saved_tcp_wire_can_output
#include "tcp-wire.c"
#undef slirp_output
#undef slirp_can_output
#undef main
#include <stddef.h>

static unsigned udp_packets;
static int output_ready = 1;
int slirp_can_output(void *opaque)
{
    (void)opaque; return output_ready; /* Explicit VirtIO capacity boundary. */
}
void slirp_output(void *opaque, const uint8_t *bytes, int length)
{
    saved_tcp_wire_output(opaque, bytes, length);
    if (length >= 42 && bytes[12] == 8 && bytes[13] == 0 && bytes[23] == IPPROTO_UDP)
        udp_packets++;
}

/* Inclusion exposes private stamps to this study without a production API. */
#include SLIRP_STUDY_SOURCE

/* Candidate arithmetic only: same monotonic epoch, duration in ms, fresh us.
 * No absolute deadline addition; positive fixed durations bound multiplication.
 * For original 32-bit stamps this is intentionally NOT sufficient at high uptime. */
static unsigned study_remaining_us(uint64_t now_us, uint64_t started_ms,
                                   uint32_t duration_ms, unsigned cap_us)
{
    uint64_t elapsed_ms = now_us / 1000 - started_ms;
    if (elapsed_ms >= duration_ms) return 0;
    uint64_t remaining_us = ((uint64_t)duration_ms - elapsed_ms) * 1000 - now_us % 1000;
    return remaining_us < cap_us ? (unsigned)remaining_us : cap_us;
}

static unsigned study_wait_us(Slirp *s, uint64_t fresh_us, unsigned cap_us)
{
#ifdef PRODUCT_DEADLINE
    struct timespec now = {.tv_sec = fresh_us / 1000000, .tv_nsec = (fresh_us % 1000000) * 1000};
    return slirp_get_sleep_duration_us(s, cap_us, &now);
#else
    unsigned value = cap_us;
    if (fasttimo_pending) value = study_remaining_us(fresh_us, time_fasttimo, 2, value);
    if (do_slowtimo) value = study_remaining_us(fresh_us, last_slowtimo, 499, value);
    for (struct socket *so = s->udb.so_next; so != &s->udb; so = so->so_next)
        if (so_has_expiry(so)) value = study_remaining_us(fresh_us, so->so_expire_started_ms, so->so_expire_duration_ms, value);
    if (s->if_queued && slirp_can_output(s->opaque)) return 0;
    return value;
#endif
}

typedef struct {
    Slirp *s;
    struct socket *so;
    struct tcpcb *tp;
    int listener, peer;
    uint16_t port;
} Connected;

static Connected connect_tcp(uint64_t base)
{
    fixture_ms = base >= 499 ? base - 499 : base;
    Slirp *s = new_slirp(); clock_at(s, fixture_ms);
    int listener = socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr = {htonl(INADDR_LOOPBACK)}};
    assert(bind(listener, (void *)&address, sizeof(address)) == 0);
    assert(listen(listener, 1) == 0);
    socklen_t size = sizeof(address);
    assert(getsockname(listener, (void *)&address, &size) == 0);
    assert(fcntl(listener, F_SETFL, O_NONBLOCK) == 0);
    uint16_t port = ntohs(address.sin_port);
    packet(s, port, 1000, 0, TH_SYN, 65535, NULL, 0);
    for (unsigned i = 0; !got_syn && i < 20; i++) turn(s);
    assert(got_syn);
    int peer = accept(listener, NULL, NULL); assert(peer >= 0);
    packet(s, port, 1001, syn_seq + 1, TH_ACK, 65535, NULL, 0);
    struct socket *so = s->tcb.so_next;
    assert(so != &s->tcb && so->so_next == &s->tcb);
    struct tcpcb *tp = so->so_tcpcb;
    assert(tp->t_state == TCPS_ESTABLISHED && !(tp->t_flags & TF_DELACK));
    fill(s); clock_at(s, base);
    return (Connected){s, so, tp, listener, peer, port};
}

static void arm_real_data(Connected *c)
{
    unsigned before = tcp_packets;
    packet(c->s, c->port, 1001, syn_seq + 1, TH_ACK, 60000, "data", 4);
    assert((c->tp->t_flags & TF_DELACK) && tcp_packets == before);
    char bytes[4]; struct pollfd fd = {.fd = c->peer, .events = POLLIN};
    assert(poll(&fd, 1, 1000) == 1);
    assert(recv(c->peer, bytes, sizeof(bytes), MSG_WAITALL) == 4);
    assert(!memcmp(bytes, "data", 4));
    fill(c->s);
    assert(fasttimo_pending);
}

static void finish_tcp(Connected *c)
{
    tcp_close(c->tp); close(c->peer); close(c->listener); slirp_cleanup(c->s);
}

static int tcp_case(uint64_t base, uint64_t gap)
{
    Connected c = connect_tcp(base); arm_real_data(&c);
    unsigned packets = tcp_packets;
    uint32_t ticks = c.s->tcp_now;
    uint64_t fast_start = time_fasttimo, slow_start = last_slowtimo;
    unsigned stale_wait = study_wait_us(c.s, udp_curtime_ms * 1000, 10000);
    unsigned fresh_wait = study_wait_us(c.s, (base + gap) * 1000, 10000);
    clock_at(c.s, base + gap);
    unsigned fast_ran = !(c.tp->t_flags & TF_DELACK) && tcp_packets == packets + 1 && last_ack == 1005;
    unsigned slow_ticks = c.s->tcp_now - ticks;
    int passed = fast_ran == (gap >= 2) && slow_ticks == (gap >= 499);
    printf("{\"case\":\"tcp-gap\",\"baseMs\":%llu,\"gapMs\":%llu,\"fastStamp\":%llu,\"slowStamp\":%llu,\"lastPollMs\":%llu,\"fastRan\":%u,\"slowTicks\":%u,\"staleHelperUs\":%u,\"freshHelperUs\":%u,\"realTcpData\":true,\"passed\":%s}\n",
           (unsigned long long)base, (unsigned long long)gap,
           (unsigned long long)fast_start, (unsigned long long)slow_start,
           (unsigned long long)udp_curtime_ms, fast_ran, slow_ticks,
           stale_wait, fresh_wait, passed ? "true" : "false");
    finish_tcp(&c); return !passed;
}

static Slirp *udp_pair(uint64_t base, int *peer, struct socket **socket_out,
                      struct sockaddr_in *actual_source)
{
    Slirp *s = new_slirp(); clock_at(s, base);
    *peer = socket(AF_INET, SOCK_DGRAM, 0); assert(*peer >= 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr = {htonl(INADDR_LOOPBACK)}};
    assert(bind(*peer, (void *)&address, sizeof(address)) == 0);
    socklen_t size = sizeof(address);
    assert(getsockname(*peer, (void *)&address, &size) == 0);
    uint8_t frame[46] = {0}, *ip = frame + 14, *udp = ip + 20;
    memcpy(frame + 6, guest_mac, 6); put16(frame + 12, 0x0800);
    ip[0] = 0x45; put16(ip + 2, 32); ip[8] = 64; ip[9] = IPPROTO_UDP;
    put32(ip + 12, 0x0a00020f); put32(ip + 16, 0x0a000202);
    put16(ip + 10, checksum(ip, 20));
    put16(udp, 30002); put16(udp + 2, ntohs(address.sin_port)); put16(udp + 4, 12);
    memcpy(udp + 8, "ping", 4); slirp_input(s, frame, sizeof(frame));
    *socket_out = s->udb.so_next;
    assert(*socket_out != &s->udb && (*socket_out)->so_next == &s->udb);
    assert((*socket_out)->so_expire_started_ms == base && (*socket_out)->so_expire_duration_ms == SO_EXPIRE);
    char bytes[8]; size = sizeof(*actual_source);
    assert(recvfrom(*peer, bytes, sizeof(bytes), MSG_DONTWAIT, (void *)actual_source, &size) == 4);
    assert(!memcmp(bytes, "ping", 4));
    fill(s); clock_at(s, base); /* Existing UDP-only do_slowtimo is retained. */
    return s;
}

static int udp_expiry_case(void)
{
    const uint64_t base = UINT64_C(0x200000000) + 1000;
    int peer; struct socket *so; struct sockaddr_in actual_source;
    Slirp *s = udp_pair(base, &peer, &so, &actual_source);
    int descriptor = so->s;
    clock_at(s, base + SO_EXPIRE - 1); fill(s);
    assert(s->udb.so_next == so && fcntl(descriptor, F_GETFD) >= 0);
    unsigned stale = study_wait_us(s, udp_curtime_ms * 1000, 10000);
    unsigned fresh = study_wait_us(s, (base + SO_EXPIRE) * 1000, 10000);
    /* A fresh read does not mutate curtime / UDP arming history. */
    assert(udp_curtime_ms == base + SO_EXPIRE - 1);
    fill(s); int stale_retained = s->udb.so_next == so;
    clock_at(s, base + SO_EXPIRE); fill(s);
    errno = 0;
    int retired = s->udb.so_next == &s->udb && fcntl(descriptor, F_GETFD) == -1 && errno == EBADF;
    int passed = stale_retained && fresh == 0 && retired;
    printf("{\"case\":\"udp-fresh-expiry\",\"baseMs\":%llu,\"staleHelperUs\":%u,\"freshHelperUs\":%u,\"staleFillRetained\":%s,\"retiredAfterActualPollFill\":%s,\"passed\":%s}\n",
           (unsigned long long)base, stale, fresh, stale_retained ? "true" : "false",
           retired ? "true" : "false", passed ? "true" : "false");
    close(peer); slirp_cleanup(s); return !passed;
}

static int ready_case(void)
{
    int peer; struct socket *so; struct sockaddr_in actual_source;
    Slirp *s = udp_pair(1000, &peer, &so, &actual_source);
    assert(sendto(peer, "pong", 4, 0, (void *)&actual_source, sizeof(actual_source)) == 4);
    fd_set r, w, e; FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e); int highest = -1;
    slirp_select_fill(s, &highest, &r, &w, &e);
    assert(FD_ISSET(so->s, &r));
    unsigned wait_us = study_wait_us(s, 1000000, 10000);
    struct timeval tv = {.tv_sec = 0, .tv_usec = wait_us};
    int n = select(highest + 1, &r, &w, &e, &tv);
    int ready = n > 0 && FD_ISSET(so->s, &r);
    slirp_select_poll(s, &r, &w, &e, n <= 0);
    int passed = ready && udp_packets == 1;
    printf("{\"case\":\"actual-udp-ready\",\"requestedWaitUs\":%u,\"selectReturned\":%d,\"actualUdpFdReady\":%s,\"outputUdpPackets\":%u,\"passed\":%s}\n",
           wait_us, n, ready ? "true" : "false", udp_packets, passed ? "true" : "false");
    udp_detach(so); close(peer); slirp_cleanup(s); return !passed;
}

static int queued_case(void)
{
    int peer; struct socket *so; struct sockaddr_in actual_source;
    Slirp *s = udp_pair(1000, &peer, &so, &actual_source);
    assert(sendto(peer, "pong", 4, 0, (void *)&actual_source, sizeof(actual_source)) == 4);
    fd_set r, w, e; FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e); int highest = -1;
    slirp_select_fill(s, &highest, &r, &w, &e);
    struct timeval tv = {.tv_sec = 0, .tv_usec = 10000};
    int n = select(highest + 1, &r, &w, &e, &tv);
    assert(n > 0 && FD_ISSET(so->s, &r));
    output_ready = 0;
    slirp_select_poll(s, &r, &w, &e, 0);
    assert(udp_packets == 0 && s->if_queued == 1 && so->so_queued == 1);
    FD_ZERO(&r); FD_ZERO(&w); FD_ZERO(&e); highest = -1;
    slirp_select_fill(s, &highest, &r, &w, &e);
    tv = (struct timeval){0};
    int ready_after_drain = select(highest + 1, &r, &w, &e, &tv);
    assert(ready_after_drain == 0);
    unsigned blocked_wait = study_wait_us(s, 1000000, 10000);
    output_ready = 1; /* Explicit equivalent of guest publishing RX capacity. */
    unsigned ready_wait = study_wait_us(s, 1000000, 10000);
    slirp_select_poll(s, &r, &w, &e, 1);
    int passed = blocked_wait == 10000 && ready_wait == 0 && udp_packets == 1
        && s->if_queued == 0 && so->so_queued == 0;
    printf("{\"case\":\"queued-output-now-writable\",\"socketReadyAfterDrain\":%d,\"queueBefore\":1,\"blockedWaitUs\":%u,\"writableWaitUs\":%u,\"actualOutputPackets\":%u,\"passed\":%s}\n",
           ready_after_drain, blocked_wait, ready_wait, udp_packets, passed ? "true" : "false");
    udp_detach(so); close(peer); slirp_cleanup(s); return !passed;
}

static int fragment_case(void)
{
    const uint64_t base = 1000;
    Slirp *s = new_slirp(); clock_at(s, base);
    uint8_t frame[50] = {0}, *ip = frame + 14, *udp = ip + 20;
    memcpy(frame + 6, guest_mac, 6); put16(frame + 12, 0x0800);
    ip[0] = 0x45; put16(ip + 2, 36); put16(ip + 4, 77); put16(ip + 6, 0x2000);
    ip[8] = 64; ip[9] = IPPROTO_UDP;
    put32(ip + 12, 0x0a00020f); put32(ip + 16, 0x0a000202); put16(ip + 10, checksum(ip, 20));
    put16(udp, 30003); put16(udp + 2, 49100); put16(udp + 4, 24);
    memcpy(udp + 8, "fragment", 8); slirp_input(s, frame, sizeof(frame));
    assert(s->ipq.ip_link.next != &s->ipq.ip_link);
    assert(s->tcb.so_next == &s->tcb && s->udb.so_next == &s->udb);
    fill(s); assert(do_slowtimo); clock_at(s, base);
    struct ipq *q = (struct ipq *)((uint8_t *)s->ipq.ip_link.next - offsetof(struct ipq, ip_link));
    unsigned ttl = q->ipq_ttl, ticks = s->tcp_now;
    unsigned before = study_wait_us(s, (base + 498) * 1000, 10000);
    unsigned due = study_wait_us(s, (base + 499) * 1000, 10000);
    clock_at(s, base + 498); assert(q->ipq_ttl == ttl);
    clock_at(s, base + 499);
    int passed = before == 1000 && due == 0 && q->ipq_ttl + 1 == ttl && s->tcp_now == ticks + 1;
    printf("{\"case\":\"fragment-only-slowtimer\",\"beforeUs\":%u,\"dueUs\":%u,\"ttlBefore\":%u,\"ttlAfter\":%u,\"tcpSockets\":0,\"udpSockets\":0,\"passed\":%s}\n",
           before, due, ttl, q->ipq_ttl, passed ? "true" : "false");
    slirp_cleanup(s); return !passed;
}

static int empty_case(void)
{
    Slirp *s = new_slirp(); clock_at(s, UINT64_C(0x200000000)); fill(s);
    unsigned wait = study_wait_us(s, udp_curtime_ms * 1000, 10000);
    int passed = !do_slowtimo && !fasttimo_pending && wait == 10000;
    /* Fresh-us helper honours a fractional millisecond; no forced ceil. */
    unsigned fractional = study_remaining_us(1000500, 1000, 2, 10000);
    assert(fractional == 1500);
    printf("{\"case\":\"no-active-timer\",\"waitUs\":%u,\"fractionalRemainingUs\":%u,\"passed\":%s}\n", wait, fractional, passed ? "true" : "false");
    slirp_cleanup(s); return !passed;
}

int main(int argc, char **argv)
{
    assert(argc >= 2);
    if (!strcmp(argv[1], "tcp")) {
        assert(argc == 4); return tcp_case(strtoull(argv[2], NULL, 0), strtoull(argv[3], NULL, 0));
    }
    assert(argc == 2);
    if (!strcmp(argv[1], "udp-expiry")) return udp_expiry_case();
    if (!strcmp(argv[1], "ready")) return ready_case();
    if (!strcmp(argv[1], "queued")) return queued_case();
    if (!strcmp(argv[1], "fragment")) return fragment_case();
    assert(!strcmp(argv[1], "empty")); return empty_case();
}
