#ifndef DSH_TEMU_FATAL_H
#define DSH_TEMU_FATAL_H
#include <setjmp.h>
extern _Thread_local jmp_buf dsh_temu_fatal_jump;
extern _Thread_local int dsh_temu_fatal_active;
extern _Thread_local int dsh_temu_fatal_reason;
#endif
