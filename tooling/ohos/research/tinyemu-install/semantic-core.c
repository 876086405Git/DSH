/* Controlled CPU/device observer for research candidates, not production code. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "riscv_cpu.h"

typedef struct {
    char kind;
    uint32_t offset, value, ram;
} Event;
typedef struct {
    uint32_t *ram;
    Event events[8];
    unsigned count;
} Observer;

static uint32_t read_observer(void *opaque, uint32_t offset, int width)
{
    Observer *o = opaque;
    if (o->count < 8)
        o->events[o->count++] = (Event){'R', offset, 51, o->ram[0]};
    return 51;
}
static void write_observer(void *opaque, uint32_t offset, uint32_t value, int width)
{
    Observer *o = opaque;
    if (o->count < 8)
        o->events[o->count++] = (Event){'W', offset, value, o->ram[0]};
}
static uint32_t addi(unsigned rd, unsigned rs, int n)
{ return ((uint32_t)n & 4095) << 20 | rs << 15 | rd << 7 | 0x13; }
static uint32_t sw(unsigned rs, unsigned base, unsigned offset)
{ return (offset >> 5) << 25 | rs << 20 | base << 15 | 2 << 12 | (offset & 31) << 7 | 0x23; }
static uint32_t lw(unsigned rd, unsigned base, unsigned offset)
{ return offset << 20 | base << 15 | 2 << 12 | rd << 7 | 3; }
static uint32_t csr(unsigned rd, unsigned num, unsigned rs, unsigned funct)
{ return num << 20 | rs << 15 | funct << 12 | rd << 7 | 0x73; }

static void run(const char *name, uint32_t *code, size_t count, unsigned expected_events,
                unsigned expected_first, unsigned expected_second, unsigned expected_third,
                unsigned expected_ram, unsigned *failures)
{
    PhysMemoryMap *map = phys_mem_map_init();
    PhysMemoryRange *range = cpu_register_ram(map, 0x1000, 0x2000, 0);
    memcpy(range->phys_mem, code, count * sizeof(*code));
    Observer o = {.ram = (uint32_t *)(range->phys_mem + 0x1000)};
    cpu_register_device(map, 0x3000, 0x1000, &o, read_observer, write_observer, DEVIO_SIZE32);
    RISCVCPUState *cpu = riscv_cpu_init(map, 64);
    riscv_cpu_interp(cpu, 128);
    unsigned complete = riscv_cpu_get_power_down(cpu);
    unsigned passed = complete && o.count == expected_events && o.events[0].value == expected_first
        && o.events[1].value == expected_second && o.events[2].value == expected_third
        && o.ram[1] == expected_ram;
    if (!passed) (*failures)++;
    printf("{\"case\":\"%s\",\"passed\":%s,\"wfiObserved\":%s,\"ramAfter\":[%u,%u],\"events\":[",
           name, passed ? "true" : "false", complete ? "true" : "false", o.ram[0], o.ram[1]);
    for (unsigned i = 0; i < o.count; ++i) {
        Event *e = &o.events[i];
        printf("%s{\"kind\":\"%c\",\"offset\":%u,\"value\":%u,\"ramAtEvent\":%u}",
               i ? "," : "", e->kind, e->offset, e->value, e->ram);
    }
    puts("]}");
    riscv_cpu_end(cpu);
    phys_mem_map_end(map);
}

int main(void)
{
    unsigned failures = 0;
    uint32_t memory[] = {
        0x000020b7, 0x00003137, /* x1=data RAM; x2=observer MMIO */
        addi(3, 0, 17), sw(3, 1, 0), lw(4, 1, 0), sw(4, 2, 0),
        0x0330000f,
        addi(3, 0, 34), sw(3, 1, 0), sw(3, 2, 4), lw(5, 2, 8), sw(5, 1, 4),
        0x10500073 /* wfi: finite completion point */
    };
    run("normal-fence-memory-device-order", memory, sizeof(memory)/4, 3, 17, 34, 51, 51, &failures);
    memory[6] = 0x8330000f;
    run("tso-memory-device-order", memory, sizeof(memory)/4, 3, 17, 34, 51, 51, &failures);
    uint32_t permissions[] = {
        0x00003137, addi(3, 0, -1),
        csr(0, 0x106, 3, 1), csr(4, 0x106, 0, 2), sw(4, 2, 0),
        csr(0, 0x306, 3, 1), csr(4, 0x306, 0, 2), sw(4, 2, 4),
        addi(3, 0, 5), csr(0, 0x106, 3, 1), csr(4, 0x106, 0, 2), sw(4, 2, 8),
        0x10500073
    };
    run("tm-scounteren-set-mcounteren-stays-clear-and-clear-again", permissions,
        sizeof(permissions)/4, 3, 7, 5, 5, 0, &failures);
    return failures ? 1 : 0;
}
