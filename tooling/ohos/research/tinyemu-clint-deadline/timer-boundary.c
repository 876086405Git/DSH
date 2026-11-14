/* Actual CPU/CLINT source; the monotonic clock is the existing explicit fixture. */
#define main original_clock_regression_main
#include "clock-cpu.c"
#undef main
int main(int argc,char **argv) {
    if(argc>1)return original_clock_regression_main(argc,argv);
    const struct {const char*name;uint64_t now,compare;} cases[] = {
        {"UINT64_MAX-future",UINT64_C(10000000),UINT64_MAX},
        {"high-bit-future",0,UINT64_C(0x8000000000000000)},
        {"near-future",UINT64_C(10000000),UINT64_C(10500000)},
        {"at-deadline",UINT64_C(10000000),UINT64_C(10000000)},
        {"past-deadline",UINT64_C(10000001),UINT64_C(10000000)},
        {"before-low-rollover",UINT64_C(0xffffffff),UINT64_C(0x100000000)},
        {"after-low-rollover",UINT64_C(0x100000000),UINT64_C(0xffffffff)}
    };
    unsigned failed=0;
    for(unsigned xlen=32;xlen<=64;xlen+=32)for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++){
        RISCVMachine*m=machine(xlen);m->timecmp=cases[i].compare;
        const uint32_t code[]={0x08000093,0x3040a073,0x10500073}; /* enable MTIE, actual WFI */
        uint64_t now=cases[i].now;set_ticks(&now,1);
        int asleep=execute(m,code,sizeof(code)/4);
        unsigned before=riscv_cpu_get_mip(m->cpu_state)&MIP_MTIP;
        int delay=riscv_machine_get_sleep_duration((VirtMachine*)m,10);
        unsigned after=riscv_cpu_get_mip(m->cpu_state)&MIP_MTIP;
        int down=riscv_cpu_get_power_down(m->cpu_state);
        int due=cases[i].now>=cases[i].compare;
        int passed=asleep&&!before&&!!after==due&&down==!due;
        printf("{\"case\":\"%s\",\"xlen\":%u,\"passed\":%s,\"mtime\":\"%016llx\",\"mtimecmp\":\"%016llx\",\"expectedMTIP\":%s,\"actualMTIP\":%u,\"powerDownAfter\":%d,\"sleepDelayMs\":%d}\n",cases[i].name,xlen,passed?"true":"false",(unsigned long long)now,(unsigned long long)m->timecmp,due?"true":"false",after,down,delay);
        failed+=!passed;riscv_machine_end((VirtMachine*)m);
    }
    return failed?1:0;
}
