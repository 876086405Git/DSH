#include "job_stdio.h"
#include "pipe_sigpipe.h"
#include "fs/fd.h"
#include "fs/real.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
extern ssize_t dsh_pipe_read(struct fd *, void *, size_t);
extern ssize_t dsh_pipe_write(struct fd *, const void *, size_t);
extern int dsh_pipe_getflags(struct fd *);
extern int dsh_pipe_setflags(struct fd *, dword_t);
static const struct fd_ops pipe_ops = {
    .read = dsh_pipe_read,
    .write = dsh_pipe_write,
    .close = realfs_close,
    .poll = realfs_poll,
    .getflags = dsh_pipe_getflags,
    .setflags = dsh_pipe_setflags,
};
void dsh_job_stdio_close(struct dsh_job_stdio *s) {
  for (int i = 0; i < 3; i++) {
    if (s->guest[i]) {
      fd_close(s->guest[i]);
      s->guest[i] = NULL;
    }
    if (s->host[i] >= 0) {
      close(s->host[i]);
      s->host[i] = -1;
    }
  }
}
int dsh_job_stdio_new(struct dsh_job_stdio *s, unsigned uid, unsigned gid) {
  for (int i = 0; i < 3; i++) {
    s->guest[i] = NULL;
    s->host[i] = -1;
  }
  for (int i = 0; i < 3; i++) {
    int ends[2];
    if (pipe(ends)) {
      int e = errno;
      dsh_job_stdio_close(s);
      return e;
    }
    // Set before publication; this embedding does not concurrently host exec.
    if (fcntl(ends[0], F_SETFD, FD_CLOEXEC) ||
        fcntl(ends[1], F_SETFD, FD_CLOEXEC)) {
      int e = errno;
      close(ends[0]);
      close(ends[1]);
      dsh_job_stdio_close(s);
      return e;
    }
    struct fd *f = adhoc_fd_create(&pipe_ops);
    if (!f) {
      close(ends[0]);
      close(ends[1]);
      dsh_job_stdio_close(s);
      return ENOMEM;
    }
    f->real_fd = ends[i == 0 ? 0 : 1];
    if (fcntl(f->real_fd, F_SETFL, O_NONBLOCK)) {
      int e=errno; fd_close(f); close(ends[i == 0 ? 1 : 0]);
      dsh_job_stdio_close(s); return e;
    }
    // The new stdin writer OFD is private and unpublished. Failure owns both
    // ends here; bridge construction never mutates a caller-owned OFD.
    if (i == 0 && fcntl(ends[1], F_SETFL, O_NONBLOCK)) {
      int e=errno; fd_close(f); close(ends[1]);
      dsh_job_stdio_close(s); return e;
    }
    int pipe_error = dsh_private_writer_nosigpipe(ends[1]);
    if (pipe_error) {
      fd_close(f); close(ends[i == 0 ? 1 : 0]);
      dsh_job_stdio_close(s); return pipe_error;
    }
    s->host[i] = ends[i == 0 ? 1 : 0];
    f->stat.mode = S_IFIFO | 0600;
    f->stat.uid = uid;
    f->stat.gid = gid;
    f->flags = i == 0 ? O_RDONLY_ : O_WRONLY_;
    s->guest[i] = f;
  }
  return 0;
}
