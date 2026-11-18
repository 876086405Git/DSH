/* Actual RISC-V CPU state and virt_machine_run select boundary.
 * Clock/select/net hooks are explicit test boundaries, not device timing. */
#define main original_clock_regression_main
#include "clock-cpu.c"
#undef main
#include <sys/select.h>
#include <limits.h>

extern void virt_machine_run(VirtMachine *m);
static int skipped_batches;
static void after_wait_batch(RISCVCPUState *cpu, int count)
{
    (void)cpu; assert(count == 500000); skipped_batches++;
}
static int selected, selected_fds, expected_fds, net_budget, net_incoming, net_polls;
static long selected_sec, selected_usec;
static uint64_t net_advance;
int __wrap_select(int count, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    (void)w; (void)e;
    selected++;
    selected_sec = tv->tv_sec; selected_usec = tv->tv_usec;
    selected_fds = count == expected_fds && (expected_fds == 0 || FD_ISSET(17, r));
    FD_ZERO(r); FD_ZERO(w); FD_ZERO(e);
    return 0;
}
static void network_fill(EthernetDevice *net, int *maximum, fd_set *r,
                         fd_set *w, fd_set *e, int *delay)
{
    (void)net; (void)w; (void)e;
    net_incoming = *delay;
    if (net_budget >= 0 && *delay > net_budget) *delay = net_budget;
    *maximum = 17; FD_SET(17, r);
    if (net_advance) ticks[0] += net_advance;
}
static void network_poll(EthernetDevice *net, fd_set *r, fd_set *w, fd_set *e, int ret)
{
    (void)net; (void)r; (void)w; (void)e;
    assert(ret == 0); net_polls++;
}
static const struct Boundary {
    const char *name;
    uint64_t now, compare;
    int waiting, pending, network, budget;
    uint64_t advance;
    int expected_us, expected_mtip, expected_clock_reads;
} boundaries[] = {
    {"future-0.1us-floor",100,101,1,0,0,-1,0,0,0,1},
    {"future-0.9us-floor",100,109,1,0,0,-1,0,0,0,1},
    {"future-1us",100,110,1,0,0,-1,0,1,0,1},
    {"future-1.9us-floor",100,119,1,0,0,-1,0,1,0,1},
    {"future-9.9us-floor",100,199,1,0,0,-1,0,9,0,1},
    {"future-888.9us-linux-witness",100,8989,1,0,0,-1,0,888,0,1},
    {"future-999.9us",100,10099,1,0,0,-1,0,999,0,1},
    {"future-exact-1ms",100,10100,1,0,0,-1,0,1000,0,1},
    {"future-1000.1us-floor",100,10101,1,0,0,-1,0,1000,0,1},
    {"future-exact-10ms",100,100100,1,0,0,-1,0,10000,0,1},
    {"future-beyond-10ms-cap",100,200100,1,0,0,-1,0,10000,0,1},
    {"unsigned-distant-future",100,UINT64_MAX,1,0,0,-1,0,10000,0,1},
    {"unsigned-high-bit-future",0,UINT64_C(0x8000000000000000),1,0,0,-1,0,10000,0,1},
    {"near-UINT64_MAX-future",UINT64_MAX-9999,UINT64_MAX,1,0,0,-1,0,999,0,1},
    {"equal-deadline",100,100,1,0,0,-1,0,0,1,1},
    {"past-deadline",101,100,1,0,0,-1,0,0,1,1},
    {"unsigned-distant-past",UINT64_MAX,0,1,0,0,-1,0,0,1,1},
    {"low32-rollover-future",UINT64_C(0xfffffffa),UINT64_C(0x100000004),1,0,0,-1,0,1,0,1},
    {"non-WFI-remains-zero",100,10100,0,0,0,-1,0,0,0,1},
    {"masked-MTIP-WFI-keeps-cap",100,100,1,1,0,-1,0,10000,1,0},
    {"masked-MTIP-with-network-budget",100,100,1,1,1,3,0,3000,1,0},
    {"network-fd-and-3ms-budget",100,100100,1,0,1,3,0,3000,0,1},
    {"network-zero-budget",100,100100,1,0,1,0,0,0,0,1},
    {"network-budget-then-cpu-microseconds",100,8989,1,0,1,3,0,888,0,1},
    {"network-cannot-extend-incoming-budget",100,1000000,1,0,1,20,0,10000,0,1},
    {"clock-read-after-network-fill",100,8989,1,0,1,10,1000,788,0,1}
};
static unsigned boundary_tests(void)
{
    unsigned failed = 0;
    for (unsigned xlen = 32; xlen <= 64; xlen += 32) {
        for (unsigned i = 0; i < sizeof(boundaries)/sizeof(boundaries[0]); i++) {
            const struct Boundary *c = &boundaries[i];
            RISCVMachine *m = machine(xlen);
            m->timecmp = c->compare;
            const uint32_t wfi[] = {0x10500073}; /* Real masked WFI; no pending interrupt may wake it. */
            if (c->waiting) assert(execute(m, wfi, 1));
            if (c->pending) riscv_cpu_set_mip(m->cpu_state, MIP_MTIP);
            set_ticks(&c->now, 1);
            EthernetDevice net = {0};
            if (c->network) { net.select_fill = network_fill; net.select_poll = network_poll; m->common.net = &net; }
            net_budget = c->budget; net_advance = c->advance; net_incoming = -1; net_polls = 0;
            selected = 0; selected_fds = 0; expected_fds = c->network ? 18 : 0;
            /* Keep all real CPU methods/state; isolate the following instruction batch. */
            RISCVCPUCommonState *cpu = (RISCVCPUCommonState *)m->cpu_state;
            const RISCVCPUClass *original = cpu->class_ptr;
            RISCVCPUClass observed = *original;
            observed.riscv_cpu_interp = after_wait_batch;
            cpu->class_ptr = &observed; skipped_batches = 0;
            virt_machine_run((VirtMachine *)m);
            cpu->class_ptr = original;
            unsigned mtip = !!(riscv_cpu_get_mip(m->cpu_state) & MIP_MTIP);
            int us = selected_sec * 1000000 + selected_usec;
            int passed = selected == 1 && selected_fds && skipped_batches == 1 &&
                selected_sec == 0 && selected_usec >= 0 && selected_usec < 1000000 &&
                us == c->expected_us && mtip == c->expected_mtip && tick_reads == c->expected_clock_reads &&
                (!c->network || (net_incoming == 10 && net_polls == 1));
            printf("{\"case\":\"%s\",\"xlen\":%u,\"passed\":%s,\"requestedUs\":%d,\"expectedUs\":%d,\"MTIP\":%u,\"clockReads\":%u,\"networkIncomingMs\":%d,\"networkPolls\":%d,\"fdSetPreserved\":%s}\n",
                c->name,xlen,passed?"true":"false",us,c->expected_us,mtip,tick_reads,net_incoming,net_polls,selected_fds?"true":"false");
            failed += !passed; m->common.net = NULL; riscv_machine_end((VirtMachine *)m);
        }
    }
    return failed;
}
static int legacy_class_delay, legacy_class_calls, legacy_class_cap, legacy_interps;
static int legacy_sleep(VirtMachine *m, int cap)
{
    (void)m; legacy_class_calls++; legacy_class_cap = cap; return legacy_class_delay;
}
static void legacy_interp(VirtMachine *m, int count)
{
    (void)m; assert(count == 500000); legacy_interps++;
}
static unsigned legacy_class_tests(void)
{
    const VirtMachineClass klass = {.machine_names="explicit-other-class", .virt_machine_get_sleep_duration=legacy_sleep,
                                   .virt_machine_interp=legacy_interp};
    const struct {int cpu_ms, net_ms, expected_us;} cases[] = {{3,-1,3000},{3,1,1000},{0,1,0}};
    unsigned failed = 0;
    for (unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
        VirtMachine m = {0}; m.vmc = &klass;
        EthernetDevice net = {0};
        if(cases[i].net_ms>=0) {net.select_fill=network_fill;net.select_poll=network_poll;m.net=&net;}
        legacy_class_delay=cases[i].cpu_ms;legacy_class_calls=legacy_class_cap=legacy_interps=0;
        net_budget=cases[i].net_ms;net_advance=0;net_incoming=-1;net_polls=0;
        selected=selected_fds=0;expected_fds=m.net?18:0;
        virt_machine_run(&m);
        int us=selected_sec*1000000+selected_usec;
        int passed=legacy_class_calls==1&&legacy_class_cap==10&&legacy_interps==1&&selected==1&&selected_fds&&
                   us==cases[i].expected_us&&(!m.net||(net_incoming==cases[i].cpu_ms&&net_polls==1));
        printf("{\"case\":\"other-class-%u\",\"passed\":%s,\"requestedUs\":%d,\"networkIncomingMs\":%d,\"classCapMs\":%d}\n",i,passed?"true":"false",us,net_incoming,legacy_class_cap);
        failed+=!passed;
    }
    return failed;
}
static unsigned legacy_ms_tests(void)
{
    const struct {const char*name;uint64_t now,compare;int cap,expected,pending;} cases[] = {
        {"ms-submillisecond-still-zero",100,8989,10,0,0},
        {"ms-exact-millisecond",100,10100,10,1,0},
        {"ms-10ms-cap",100,200100,10,10,0},
        {"ms-INT_MAX-cap-no-narrowing",0,UINT64_MAX,INT_MAX,INT_MAX,0},
        {"ms-zero-cap",100,10100,0,0,0},
        {"ms-negative-cap-preserved",100,10100,-1,-1,0},
        {"ms-masked-pending-keeps-cap",100,100,10,10,1}
    };
    unsigned failed=0;
    for(unsigned xlen=32;xlen<=64;xlen+=32)for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++){
        RISCVMachine*m=machine(xlen);m->timecmp=cases[i].compare;const uint32_t wfi[]={0x10500073};assert(execute(m,wfi,1));
        if(cases[i].pending)riscv_cpu_set_mip(m->cpu_state,MIP_MTIP);
        set_ticks(&cases[i].now,1);
        int delay=virt_machine_get_sleep_duration((VirtMachine*)m,cases[i].cap);
        int passed=delay==cases[i].expected&&tick_reads==(cases[i].pending?0:1);
        printf("{\"case\":\"%s\",\"xlen\":%u,\"passed\":%s,\"delayMs\":%d,\"clockReads\":%u}\n",cases[i].name,xlen,passed?"true":"false",delay,tick_reads);
        failed+=!passed;riscv_machine_end((VirtMachine*)m);
    }
    return failed;
}
int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "--legacy-class")) return legacy_class_tests() ? 1 : 0;
    if (argc == 2 && !strcmp(argv[1], "--legacy-ms")) return legacy_ms_tests() ? 1 : 0;
    if (argc > 1) return original_clock_regression_main(argc, argv);
    return boundary_tests() ? 1 : 0;
}
