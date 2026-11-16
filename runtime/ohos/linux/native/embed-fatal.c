#include "embed-fatal.h"
#include <stdlib.h>
_Thread_local jmp_buf dsh_temu_fatal_jump;
_Thread_local int dsh_temu_fatal_active;
_Thread_local int dsh_temu_fatal_reason;
static _Noreturn void fail(int reason) {
    dsh_temu_fatal_reason = reason;
    if (dsh_temu_fatal_active) longjmp(dsh_temu_fatal_jump, 1);
    /* No process-global signal/exit hook. Unsupported legacy entry stays fatal. */
    _Exit(127);
}
_Noreturn void __wrap_exit(int status) { (void)status; fail(1); }
_Noreturn void __wrap_abort(void) { fail(2); }
_Noreturn void __wrap___assert_fail(const char *expr, const char *file, unsigned line, const char *fn) {
    (void)expr; (void)file; (void)line; (void)fn; fail(3);
}
