/* Link-time test observer only. Never compiled into production/HAP. */
#include <node_api.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "cutils.h"
#include "riscv_cpu_priv.h"

#ifndef FAULT_MODE
#define FAULT_MODE 0
#endif
static void *ram;
static size_t bytes, page, eligible;
static uintptr_t begin;
static PhysMemoryMap *map;
static RISCVCPUState *cpu;
static atomic_int advice_calls, join_calls, joined, installed;
static int advice_errno;
static size_t resident_before;
static int mincore_before;
void *__real_mallocz(size_t);
void *__wrap_mallocz(size_t size) {
    void *ptr = __real_mallocz(size);
    if (size == 16 * 1024 * 1024 && ptr) {
        ram = ptr; bytes = size; page = (size_t)sysconf(_SC_PAGESIZE);
        begin = ((uintptr_t)ptr + page - 1) & ~(uintptr_t)(page - 1);
        uintptr_t end = ((uintptr_t)ptr + size) & ~(uintptr_t)(page - 1);
        eligible = end - begin;
        /* Artificial host-side touch, not a Linux guest workload or PSS claim. */
        for (uintptr_t p = begin; p < end; p += page) *(volatile uint8_t *)p = 0x5a;
        ((uint8_t *)ram)[1024] = 0x31;
        ((uint8_t *)ram)[bytes - 1] = 0x79;
        unsigned char *vec = malloc(eligible / page);
        mincore_before = mincore((void *)begin, eligible, vec);
        if (!mincore_before) for (size_t i = 0; i < eligible / page; ++i) resident_before += !!(vec[i] & 1);
        free(vec);
    }
    return ptr;
}
PhysMemoryMap *__real_phys_mem_map_init(void);
PhysMemoryMap *__wrap_phys_mem_map_init(void) { map = __real_phys_mem_map_init(); return map; }
RISCVCPUState *__real_riscv_cpu_init(PhysMemoryMap *, int);
RISCVCPUState *__wrap_riscv_cpu_init(PhysMemoryMap *memory, int xlen) {
    cpu = __real_riscv_cpu_init(memory, xlen); return cpu;
}
int __real_pthread_join(pthread_t, void **);
int __wrap_pthread_join(pthread_t thread, void **result) {
    atomic_fetch_add(&join_calls, 1);
    if (FAULT_MODE == 2) return ESRCH;
    int code = __real_pthread_join(thread, result);
    if (!code) atomic_store(&joined, 1);
    return code;
}
int __real_madvise(void *, size_t, int);
int __wrap_madvise(void *start, size_t length, int advice) {
    atomic_fetch_add(&advice_calls, 1);
    if (!atomic_load(&joined) || start != (void *)begin || length != eligible || advice != MADV_DONTNEED) {
        /* Turn an unsafe range/order into an observable failure, never execute it. */
        advice_errno = errno = EINVAL; return -1;
    }
    if (FAULT_MODE == 1) { advice_errno = errno = EIO; return -1; }
    int code = __real_madvise(start, length, advice);
    advice_errno = code ? errno : 0;
    return code;
}
int __real_fclose(FILE *);
int __wrap_fclose(FILE *file) {
    char name[64], target[4096];
    int fail = 0;
    if (FAULT_MODE == 4) {
        snprintf(name, sizeof(name), "/proc/self/fd/%d", fileno(file));
        ssize_t length = readlink(name, target, sizeof(target) - 1);
        if (length >= 9) fail = memcmp(target + length - 9, "/disk.raw", 9) == 0;
    }
    int result = __real_fclose(file);
    if (fail && result == 0) { errno = EIO; return EOF; }
    return result;
}
static napi_async_complete_callback complete_original;
static void no_execute(napi_env env, void *data) { (void)env; (void)data; }
static void cancelled(napi_env env, napi_status status, void *data) {
    (void)status; complete_original(env, napi_cancelled, data);
}
napi_status __real_napi_create_async_work(napi_env, napi_value, napi_value, napi_async_execute_callback,
                                         napi_async_complete_callback, void *, napi_async_work *);
napi_status __wrap_napi_create_async_work(napi_env env, napi_value resource, napi_value name,
        napi_async_execute_callback execute, napi_async_complete_callback complete, void *data, napi_async_work *work) {
    if (FAULT_MODE == 3) { complete_original = complete; execute = no_execute; complete = cancelled; }
    return __real_napi_create_async_work(env, resource, name, execute, complete, data, work);
}
static void number(napi_env env, napi_value result, const char *name, double value) {
    napi_value n; napi_create_double(env, value, &n); napi_set_named_property(env, result, name, n);
}
static void boolean(napi_env env, napi_value result, const char *name, int value) {
    napi_value n; napi_get_boolean(env, value, &n); napi_set_named_property(env, result, name, n);
}
static napi_value stats(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result, unknown; napi_create_object(env, &result); napi_get_null(env, &unknown);
    number(env, result, "adviceCalls", atomic_load(&advice_calls));
    number(env, result, "joinCalls", atomic_load(&join_calls));
    boolean(env, result, "joined", atomic_load(&joined));
    if (!atomic_load(&joined)) {
        napi_set_named_property(env, result, "residentPages", unknown);
        return result; /* Never inspect machine-owned fields without actual join. */
    }
    number(env, result, "trackedBytes", bytes);
    number(env, result, "eligibleBytes", eligible);
    number(env, result, "pageBytes", page);
    number(env, result, "adviceErrno", advice_errno);
    number(env, result, "mincoreBeforeResult", mincore_before);
    number(env, result, "residentBeforePages", resident_before);
    size_t resident = 0;
    if (ram) {
        unsigned char *vec = malloc(eligible / page);
        int code = mincore((void *)begin, eligible, vec);
        number(env, result, "mincoreResult", code);
        if (!code) for (size_t i = 0; i < eligible / page; ++i) resident += !!(vec[i] & 1);
        free(vec);
        PhysMemoryRange *range = get_phys_mem_range(map, UINT64_C(0x80000000));
        boolean(env, result, "mappingRetained", range && range->phys_mem == ram && range->size == bytes && cpu->mem_map == map);
        boolean(env, result, "boundaryBytesPreserved", ((uint8_t *)ram)[1024] == 0x31 && ((uint8_t *)ram)[bytes - 1] == 0x79);
    }
    number(env, result, "residentPages", resident);
    return result;
}
napi_status __real_napi_set_named_property(napi_env, napi_value, const char *, napi_value);
napi_status __wrap_napi_set_named_property(napi_env env, napi_value object, const char *name, napi_value value) {
    napi_status code = __real_napi_set_named_property(env, object, name, value);
    if (code == napi_ok && !strcmp(name, "create") && !atomic_exchange(&installed, 1)) {
        napi_value fn;
        if (napi_create_function(env, "__retentionStats", NAPI_AUTO_LENGTH, stats, NULL, &fn) != napi_ok)
            return napi_generic_failure;
        return __real_napi_set_named_property(env, object, "__retentionStats", fn);
    }
    return code;
}
