#include "fs/fd.h"
#include "pipe_sigpipe.h"
#include "kernel/task.h"
#include "kernel/errno.h"
#include <errno.h>
#include <signal.h>
#include <sys/select.h>
#include <unistd.h>
int dsh_pipe_getflags(struct fd *fd) {
  lock(&fd->lock); int flags=fd->flags; unlock(&fd->lock); return flags;
}
int dsh_pipe_setflags(struct fd *fd, dword_t flags) {
  lock(&fd->lock);
  fd->flags=(fd->flags & ~(O_APPEND_|O_NONBLOCK_)) | (flags & (O_APPEND_|O_NONBLOCK_));
  unlock(&fd->lock);
  return 0;
}
static ssize_t transfer(struct fd *fd, void *buf, size_t size, int writing) {
  if (!size) return 0;
  if (!current || !current->sighand || should_unwind) return _EINVAL;
  if (fd->real_fd < 0 || fd->real_fd >= FD_SETSIZE) return _EINVAL;
  sigset_t block, saved;
  sigemptyset(&block); sigaddset(&block, SIGUSR1);
  int e=pthread_sigmask(SIG_BLOCK,&block,&saved);
  if(e) { errno=e; return errno_map(); }
  ssize_t result=_EINVAL;
  if(sigismember(&saved,SIGUSR1)) goto done;
  for(;;) {
    lock(&current->sighand->lock);
    int pending=!!(current->pending & ~current->blocked);
    unlock(&current->sighand->lock);
    if(pending) { result=_EINTR; break; }
    result=writing ? dsh_pipe_write_nosignal(fd->real_fd,buf,size) : read(fd->real_fd,buf,size);
    if(result>=0) break;
    if(errno==EINTR) continue;
    if(errno!=EAGAIN && errno!=EWOULDBLOCK) { result=errno_map(); break; }
    if(dsh_pipe_getflags(fd) & O_NONBLOCK_) { result=_EAGAIN; break; }
    fd_set set; FD_ZERO(&set); FD_SET(fd->real_fd,&set);
    int rc=pselect(fd->real_fd+1,writing?NULL:&set,writing?&set:NULL,NULL,NULL,&saved);
    if(rc<0 && errno!=EINTR) { result=errno_map(); break; }
  }
done:
  e=pthread_sigmask(SIG_SETMASK,&saved,NULL);
  if(e) { errno=e; return errno_map(); }
  return result;
}
ssize_t dsh_pipe_read(struct fd *fd,void *buf,size_t size) { return transfer(fd,buf,size,0); }
ssize_t dsh_pipe_write(struct fd *fd,const void *buf,size_t size) { return transfer(fd,(void *)buf,size,1); }
