#ifndef DSH_PIPE_SIGPIPE_H
#define DSH_PIPE_SIGPIPE_H
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
// Only call while owning a newly-created, unpublished pipe writer. Darwin's
// flag belongs to fileglob and is shared by duplicated references, not per fd.
static inline int dsh_private_writer_nosigpipe(int fd) {
#if defined(__APPLE__)
#if defined(F_SETNOSIGPIPE) && defined(F_GETNOSIGPIPE)
  if (fcntl(fd, F_SETNOSIGPIPE, 1) < 0) return errno;
  int value = fcntl(fd, F_GETNOSIGPIPE);
  if (value < 0) return errno;
  return value == 1 ? 0 : EIO;
#else
  (void)fd;
  return ENOTSUP;
#endif
#else
  (void)fd;
  return 0; // Linux uses a scoped thread mask around each write below.
#endif
}
// Validation never changes the caller's OFD or global signal disposition.
static inline int dsh_writer_sigpipe_valid(int fd) {
#if defined(__APPLE__)
#if defined(F_GETNOSIGPIPE)
  int value = fcntl(fd, F_GETNOSIGPIPE);
  if (value < 0) return errno;
  return value == 1 ? 0 : ENOTSUP;
#else
  (void)fd;
  return ENOTSUP;
#endif
#else
  (void)fd;
  return 0;
#endif
}
// Never changes process-global SIGPIPE handling. Darwin uses the private OFD
// flag; Linux blocks only this thread and consumes only a newly generated signal.
static inline ssize_t dsh_pipe_write_nosignal(int fd, const void *bytes, size_t count) {
#ifdef __APPLE__
  return write(fd, bytes, count);
#else
  sigset_t block, saved, pending;
  sigemptyset(&block); sigaddset(&block, SIGPIPE);
  int e = pthread_sigmask(SIG_BLOCK, &block, &saved);
  if (e) { errno = e; return -1; }
  if (sigpending(&pending)) {
    int error = errno; pthread_sigmask(SIG_SETMASK, &saved, NULL); errno = error; return -1;
  }
  ssize_t n = write(fd, bytes, count);
  int error = errno;
  if (n < 0 && error == EPIPE && !sigismember(&pending, SIGPIPE)) {
    struct timespec zero = {0, 0};
    while (sigtimedwait(&block, NULL, &zero) < 0 && errno == EINTR) {}
  }
  e = pthread_sigmask(SIG_SETMASK, &saved, NULL);
  if (e) { errno = e; return -1; }
  errno = error;
  return n;
#endif
}
#endif
