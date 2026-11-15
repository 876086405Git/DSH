#ifndef DSH_IOS_JOB_THREADS_H
#define DSH_IOS_JOB_THREADS_H
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
typedef struct dsh_job_threads dsh_job_threads;
enum dsh_thread_state {
  DSH_THREADS_READY,
  DSH_THREADS_RUNNING,
  DSH_THREADS_FAULT,
  DSH_THREADS_STOPPED
};
// One manager/reaper per kernel. Return values are positive host errno values.
dsh_job_threads *dsh_job_threads_new(void);
int dsh_job_threads_begin(dsh_job_threads *, uint64_t id);
int dsh_job_threads_spawn(dsh_job_threads *, uint64_t id, pthread_t *,
                          void *(*entry)(void *), void *argument);
int dsh_job_threads_seal(dsh_job_threads *, uint64_t id);
// Zero means all tracked pthread_join calls completed, NOT stream EOF or
// whole-kernel cleanup.
int dsh_job_threads_wait(dsh_job_threads *, uint64_t id, unsigned timeout_ms);
void dsh_job_threads_status(dsh_job_threads *, enum dsh_thread_state *,
                            size_t *pending);
// A bridge failure after joins (EOF/delivery/reaping) permanently faults this
// same generation too. A stale generation cannot fault a newer job.
int dsh_job_threads_fault(dsh_job_threads *, uint64_t id);
// Only for quiescent manager shutdown; cannot interrupt a blocked join.
int dsh_job_threads_destroy(dsh_job_threads *);
// Trusted one-time kernel installation. Never swapped to a second kernel.
int dsh_job_threads_install(dsh_job_threads *);
int dsh_guest_task_start(uint64_t id, pthread_t *, void *(*entry)(void *),
                         void *argument);
#endif
