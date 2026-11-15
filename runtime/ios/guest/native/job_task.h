#ifndef DSH_JOB_TASK_H
#define DSH_JOB_TASK_H
#include <stdint.h>
struct task;
struct dsh_job_stdio;
// Trusted owner calls before task_start; requires no preexisting files table.
int dsh_job_install_stdio(struct task *, struct dsh_job_stdio *);
// Trusted active generation ID; only TERM/KILL. Returns matched live task
// count.
int dsh_job_signal(uint64_t id, int signal);
// Trusted supervisor only, AFTER every job pthread is joined. Uses original
// do_wait to reap zombie groups; does not free a task still capable of running.
int dsh_job_reap(struct task *supervisor, uint64_t id);
#endif
