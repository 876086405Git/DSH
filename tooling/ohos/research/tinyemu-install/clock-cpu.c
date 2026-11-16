/* Deterministic real CPU/CLINT test. Clock injection is test-only, never in temu. */
#include <time.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>
static uint64_t ticks[16];
static unsigned tick_count, tick_reads;
static void set_ticks(const uint64_t *values, unsigned count)
{
    assert(count > 0 && count <= 16);
    memcpy(ticks, values, count * sizeof(*values));
    tick_count = count;
    tick_reads = 0;
}
static int controlled_clock(clockid_t id, struct timespec *ts)
{
    assert(id == CLOCK_MONOTONIC && tick_count);
    uint64_t value = ticks[tick_reads < tick_count ? tick_reads : tick_count - 1];
    tick_reads++;
    ts->tv_sec = value / UINT64_C(10000000);
    ts->tv_nsec = (value % UINT64_C(10000000)) * 100;
    return 0;
}
#define clock_gettime controlled_clock
#include "riscv_machine.c"
#undef clock_gettime

static uint32_t lui(unsigned rd, uint32_t value)
{ return (value & 0xfffff000U) | rd << 7 | 0x37; }
static uint32_t addi(unsigned rd, unsigned rs, int value)
{ return ((uint32_t)value & 4095) << 20 | rs << 15 | rd << 7 | 0x13; }
static uint32_t load(unsigned rd, unsigned base, unsigned offset, unsigned width)
{ return offset << 20 | base << 15 | width << 12 | rd << 7 | 3; }
static uint32_t store(unsigned rs, unsigned base, unsigned offset, unsigned width)
{ return (offset >> 5) << 25 | rs << 20 | base << 15 | width << 12 | (offset & 31) << 7 | 0x23; }
static uint32_t bne(unsigned a, unsigned b, int displacement)
{
    uint32_t v = (uint32_t)displacement & 8191;
    return ((v >> 12) & 1) << 31 | ((v >> 5) & 63) << 25 | b << 20 | a << 15 |
        1 << 12 | ((v >> 1) & 15) << 8 | ((v >> 11) & 1) << 7 | 0x63;
}
static RISCVMachine *machine(unsigned xlen)
{
    uint64_t zero = 0;
    uint32_t boot = 0x10500073;
    set_ticks(&zero, 1);
    VirtMachineParams p = {0};
    p.vmc = &riscv_machine_class;
    p.machine_name = xlen == 64 ? "riscv64" : "riscv32";
    p.ram_size = 0x20000;
    p.rtc_real_time = TRUE;
    p.cmdline = "";
    p.files[VM_FILE_BIOS].buf = (uint8_t *)&boot;
    p.files[VM_FILE_BIOS].len = sizeof(boot);
    return (RISCVMachine *)riscv_machine_init(&p);
}
static uint8_t *data(RISCVMachine *m)
{ return get_phys_mem_range(m->mem_map, 0x2000)->phys_mem + 0x2000; }
static int execute(RISCVMachine *m, const uint32_t *code, unsigned count)
{
    memcpy(get_phys_mem_range(m->mem_map, 0x1000)->phys_mem + 0x1000,
           code, count * sizeof(*code));
    riscv_cpu_interp(m->cpu_state, 128);
    return riscv_cpu_get_power_down(m->cpu_state);
}
static unsigned failures;
static void result(const char *name, unsigned xlen, int passed, uint64_t a, uint64_t b, unsigned reads)
{
    printf("{\"case\":\"%s\",\"xlen\":%u,\"passed\":%s,\"values\":[\"%016llx\",\"%016llx\"],\"clockReads\":%u}\n",
           name, xlen, passed ? "true" : "false", (unsigned long long)a, (unsigned long long)b, reads);
    if (!passed) failures++;
}
static void rollover(const char *name, uint64_t edge)
{
    RISCVMachine *m = machine(64);
    uint32_t code[] = {lui(1, CLINT_BASE_ADDR + 0xc000), addi(1, 1, -8), lui(2, 0x2000),
        load(3, 1, 0, 3), store(3, 2, 0, 3), load(3, 1, 0, 3), store(3, 2, 8, 3), 0x10500073};
    uint64_t sequence[] = {edge, edge + 1, edge + 2, edge + 3};
    set_ticks(sequence, 4);
    int done = execute(m, code, sizeof(code)/4);
    uint64_t values[2]; memcpy(values, data(m), sizeof(values));
    result(name, 64, done && values[0] == edge && values[1] == edge + 1 && tick_reads == 2,
           values[0], values[1], tick_reads);
    riscv_machine_end((VirtMachine *)m);
}
static void independent_words(unsigned xlen, unsigned offset, const char *name)
{
    RISCVMachine *m = machine(xlen);
    uint32_t code[] = {lui(1, CLINT_BASE_ADDR + 0xc000), addi(1, 1, -8), lui(2, 0x2000),
        load(3, 1, offset, 2), store(3, 2, 0, 2), load(3, 1, offset, 2), store(3, 2, 4, 2), 0x10500073};
    uint64_t sequence[] = {UINT64_C(0xffffffff), UINT64_C(0x100000000)};
    set_ticks(sequence, 2);
    int done = execute(m, code, sizeof(code)/4);
    uint32_t values[2]; memcpy(values, data(m), sizeof(values));
    uint32_t a = offset ? 0 : 0xffffffffU, b = offset ? 1 : 0;
    result(name, xlen, done && values[0] == a && values[1] == b && tick_reads == 2,
           values[0], values[1], tick_reads);
    riscv_machine_end((VirtMachine *)m);
}
static void high_low_high(unsigned xlen)
{
    RISCVMachine *m = machine(xlen);
    uint32_t code[] = {lui(1, CLINT_BASE_ADDR + 0xc000), addi(1, 1, -8), lui(2, 0x2000),
        load(3, 1, 4, 2), load(4, 1, 0, 2), load(5, 1, 4, 2), bne(3, 5, -12),
        store(4, 2, 0, 2), store(5, 2, 4, 2), 0x10500073};
    uint64_t sequence[] = {UINT64_C(0xfffffffe), UINT64_C(0xffffffff), UINT64_C(0x100000000),
        UINT64_C(0x100000001), UINT64_C(0x100000002), UINT64_C(0x100000003)};
    set_ticks(sequence, 6);
    int done = execute(m, code, sizeof(code)/4);
    uint64_t value; memcpy(&value, data(m), sizeof(value));
    result("high-low-high-retries-across-rollover", xlen,
           done && value == UINT64_C(0x100000002) && tick_reads == 6, value, 0, tick_reads);
    riscv_machine_end((VirtMachine *)m);
}
static void timecmp(void)
{
    RISCVMachine *m = machine(64);
    uint32_t code[] = {lui(1, CLINT_BASE_ADDR + 0x4000), lui(2, 0x2000),
        load(3, 2, 16, 3), store(3, 1, 0, 3), load(4, 1, 0, 3), store(4, 2, 0, 3), 0x10500073};
    uint64_t value = UINT64_C(0x89abcdef76543210), zero = 0;
    memcpy(data(m) + 16, &value, sizeof(value));
    riscv_cpu_set_mip(m->cpu_state, MIP_MTIP);
    set_ticks(&zero, 1);
    int done = execute(m, code, sizeof(code)/4);
    uint64_t observed; memcpy(&observed, data(m), sizeof(observed));
    result("mtimecmp-64-bit-write-read-and-clear-MTIP", 64,
           done && observed == value && m->timecmp == value && !(riscv_cpu_get_mip(m->cpu_state) & MIP_MTIP) && tick_reads == 0,
           observed, m->timecmp, tick_reads);
    riscv_machine_end((VirtMachine *)m);
}
static void zero_widths(void)
{
    RISCVMachine *m = machine(64);
    uint32_t code[] = {lui(1, CLINT_BASE_ADDR + 0xc000), addi(1, 1, -8), lui(2, 0x2000),
        load(3, 1, 0, 4), store(3, 2, 0, 2), load(3, 1, 0, 5), store(3, 2, 4, 2),
        lui(1, CLINT_BASE_ADDR + 0x5000), load(3, 1, 0, 3), store(3, 2, 8, 3), 0x10500073};
    uint64_t value = UINT64_C(0xffffffff); set_ticks(&value, 1);
    int done = execute(m, code, sizeof(code)/4);
    uint64_t values[2]; memcpy(values, data(m), sizeof(values));
    result("unsupported-widths-and-unimplemented-aligned-register", 64,
           done && !values[0] && !values[1] && tick_reads == 0, values[0], values[1], tick_reads);
    riscv_machine_end((VirtMachine *)m);
}
static unsigned reads, writes, bad_access;
static uint32_t generic_read(void *opaque, uint32_t offset, int width)
{
    (void)opaque;
    if (width != 2 || offset != 4 * reads) bad_access++;
    reads++;
    return offset ? 0x55667788U : 0x11223344U;
}
static void generic_write(void *opaque, uint32_t offset, uint32_t value, int width)
{
    (void)opaque;
    if (width != 2 || offset != 4 * writes || value != (offset ? 0x55667788U : 0x11223344U)) bad_access++;
    writes++;
}
static void other_device(void)
{
    RISCVMachine *m = machine(64);
    cpu_register_device(m->mem_map, 0x50000000, 0x1000, NULL, generic_read, generic_write, DEVIO_SIZE32);
    uint32_t code[] = {lui(1, 0x50000000), lui(2, 0x2000), load(3, 1, 0, 3),
        store(3, 2, 0, 3), store(3, 1, 0, 3), 0x10500073};
    uint64_t zero = 0; set_ticks(&zero, 1); reads = writes = bad_access = 0;
    int done = execute(m, code, sizeof(code)/4);
    uint64_t value; memcpy(&value, data(m), sizeof(value));
    result("other-device-keeps-two-32-bit-read-write-callbacks", 64,
           done && reads == 2 && writes == 2 && !bad_access && value == UINT64_C(0x5566778811223344) && tick_reads == 0,
           value, ((uint64_t)reads << 32) | writes, tick_reads);
    riscv_machine_end((VirtMachine *)m);
}
static void interrupt_boundary(void)
{
    RISCVMachine *m = machine(64);
    m->timecmp = UINT64_C(0x100000001);
    uint64_t before = UINT64_C(0x100000000); set_ticks(&before, 1);
    riscv_machine_get_sleep_duration((VirtMachine *)m, 10);
    unsigned a = riscv_cpu_get_mip(m->cpu_state) & MIP_MTIP;
    uint64_t at = UINT64_C(0x100000001); set_ticks(&at, 1);
    riscv_machine_get_sleep_duration((VirtMachine *)m, 10);
    unsigned b = riscv_cpu_get_mip(m->cpu_state) & MIP_MTIP;
    result("timer-MTIP-before-and-at-deadline-across-low-rollover", 64, a == 0 && b == MIP_MTIP, a, b, tick_reads);
    riscv_machine_end((VirtMachine *)m);
}
static int observe_write(void)
{
    RISCVMachine *m = machine(32);
    m->timecmp = UINT64_C(0x1234567800000000);
    clint_write(m, 0x4000, 7, 2);
    result("separate-observation-low-word-write-preserves-high-word", 32,
           m->timecmp == UINT64_C(0x1234567800000007), m->timecmp, UINT64_C(0x1234567800000007), tick_reads);
    riscv_machine_end((VirtMachine *)m);
    return failures ? 1 : 0;
}
int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "--observe-write")) return observe_write();
    rollover("rv64-LD-low32-rollover", UINT64_C(0xffffffff));
    rollover("rv64-LD-next-low32-rollover", UINT64_C(0x1ffffffff));
    rollover("rv64-LD-high-word-not-fixed", UINT64_C(0x12345678ffffffff));
    for (unsigned xlen = 32; xlen <= 64; xlen += 32) {
        independent_words(xlen, 0, "low32-independent-reads");
        independent_words(xlen, 4, "high32-independent-reads");
        high_low_high(xlen);
    }
    timecmp();
    zero_widths();
    other_device();
    interrupt_boundary();
    return failures ? 1 : 0;
}
