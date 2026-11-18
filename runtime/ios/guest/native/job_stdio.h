#ifndef DSH_JOB_STDIO_H
#define DSH_JOB_STDIO_H
#include <sys/types.h>
struct fd;
struct dsh_job_stdio {
  struct fd *guest[3];
  int host[3];
};
// Owns three dedicated pipes; caller transfers each guest slot to its fdtable.
// No host standard descriptors are borrowed. Positive host errno on failure.
int dsh_job_stdio_new(struct dsh_job_stdio *, unsigned uid, unsigned gid);
void dsh_job_stdio_close(struct dsh_job_stdio *);
#endif
