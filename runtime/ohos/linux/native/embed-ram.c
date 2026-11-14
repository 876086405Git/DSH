#include "embed-ram.h"
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

static void *guest_ram;
static size_t guest_bytes;
static int capture_conflict, normal_stop, inspected;
static DshTemuRamRetirement result;

void dsh_temu_ram_capture(void *ram, size_t bytes) {
    if (guest_ram || !ram || !bytes) { capture_conflict = 1; return; }
    guest_ram = ram; guest_bytes = bytes;
}
void dsh_temu_ram_allow_retirement(void) { normal_stop = 1; }

DshTemuRamRetirement dsh_temu_ram_retire_joined(void) {
    if (inspected) return result;
    inspected = 1;
    result.tracked_bytes = guest_bytes;
    if (capture_conflict) { result.error_code = EINVAL; return result; }
    if (!normal_stop || !guest_ram) return result;
    result.eligible = 1;
    long page_result = sysconf(_SC_PAGESIZE);
    if (page_result <= 0) { result.error_code = EINVAL; return result; }
    uintptr_t page = (uintptr_t)page_result, first = (uintptr_t)guest_ram;
    if (guest_bytes > UINTPTR_MAX - first) { result.error_code = EOVERFLOW; return result; }
    uintptr_t end = first + guest_bytes;
    uintptr_t remainder = first % page;
    uintptr_t offset = remainder ? page - remainder : 0;
    if (offset > guest_bytes) return result;
    uintptr_t begin = first + offset;
    end -= end % page;
    if (end <= begin) return result;
    result.eligible_bytes = end - begin;
    result.attempted = 1;
    /* malloc metadata and any neighbouring allocation lie outside this exact
     * payload's complete pages. Leave its partial boundary pages untouched.
     * The VM is permanently stopped: discarded contents are never resumed. */
    if (madvise((void *)begin, (size_t)result.eligible_bytes, MADV_DONTNEED) == 0)
        result.advised_bytes = result.eligible_bytes;
    else
        result.error_code = errno > 0 ? errno : EIO;
    return result;
}
