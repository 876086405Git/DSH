#ifndef DSH_JOB_BRIDGE_H
#define DSH_JOB_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
struct dsh_job_stdio;
struct dsh_job_threads;
typedef struct dsh_job_bridge dsh_job_bridge;
// Data valid only during callback. Copy/enqueue is NOT delivery
// acknowledgement. end_offset is per-stream cumulative byte count, starting at
// zero for each job.
typedef int (*dsh_job_output)(void *, int, uint64_t, const void *, size_t);
dsh_job_bridge *dsh_job_bridge_new(struct dsh_job_threads *, uint64_t, int,
                                   struct dsh_job_stdio *, dsh_job_output,
                                   void *, double (*)(void *), void *);
// Receiver confirms bytes actually delivered. Thread-safe, monotonic; caller
// retains owner until finish succeeds. Never call after destroy.
int dsh_job_bridge_ack(dsh_job_bridge *, int, uint64_t);
// All guest/output joins + original task reaping + EOF + real ACK, or explicit
// abandoned output. Normal runtime has no deadline; timeout bounds cancellation
// cleanup only in the captured clock domain. Any failure is sticky; never start another kernel/job.
int dsh_job_bridge_finish(dsh_job_bridge *, unsigned, int *);
int dsh_job_bridge_destroy(dsh_job_bridge *);
int dsh_job_bridge_abandon(dsh_job_bridge *);
int dsh_job_bridge_abandoned(dsh_job_bridge *);
void dsh_job_bridge_cancel_requested(dsh_job_bridge *);
int dsh_job_bridge_stdin_write(dsh_job_bridge *, uint64_t, const void *, size_t, size_t *);
int dsh_job_bridge_stdin_close(dsh_job_bridge *, uint64_t);
#endif
