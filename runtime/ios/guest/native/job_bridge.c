#include "job_bridge.h"
#include "pipe_sigpipe.h"
#include "job_stdio.h"
#include "job_task.h"
#include "job_threads.h"
#include "kernel/task.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
struct reader {
  struct dsh_job_bridge *owner;
  int fd, stream;
  bool eof;
  uint64_t emitted, delivered;
};
struct dsh_job_bridge {
  pthread_mutex_t lock;
  pthread_cond_t changed;
  dsh_job_threads *threads;
  struct task *supervisor;
  uint64_t id;
  double cancelled_at;
  bool cancelled;
  double (*now_ms)(void *);
  void *clock_context;
  int root_pid, stdin_fd, status, error;
  bool exited, settled, finishing, abandoned;
  struct reader readers[2];
  dsh_job_output output;
  void *context;
};
static _Atomic(dsh_job_bridge *) active;
static uint64_t millis(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}
static double budget_now(dsh_job_bridge *b) {
  return b->now_ms ? b->now_ms(b->clock_context) : (double)millis();
}
static void exited(struct task *task, int code) {
  dsh_job_bridge *b = atomic_load(&active);
  if (!b || task->dsh_job_id != b->id || !task->group ||
      task->group->leader->pid != b->root_pid)
    return;
  pthread_mutex_lock(&b->lock);
  b->status = task->group->doing_group_exit ? task->group->group_exit_code
                                            : task->group->leader->exit_code;
  b->exited = true;
  pthread_mutex_unlock(&b->lock);
  (void)code;
}
static void *read_output(void *argument) {
  struct reader *r = argument;
  dsh_job_bridge *b = r->owner;
  char buf[16384];
  int error = 0;
  for (;;) {
    ssize_t n = read(r->fd, buf, sizeof buf);
    if (n < 0 && errno == EINTR)
      continue;
    if (n < 0) {
      error = errno;
      break;
    }
    if (!n) {
      r->eof = true;
      break;
    }
    pthread_mutex_lock(&b->lock);
    if (UINT64_MAX - r->emitted < (uint64_t)n) {
      pthread_mutex_unlock(&b->lock);
      error = EOVERFLOW;
      break;
    }
    r->emitted += (uint64_t)n;
    uint64_t end = r->emitted;
    bool abandoned = b->abandoned;
    pthread_mutex_unlock(&b->lock);
    if (abandoned) continue;
    error = b->output(b->context, r->stream, end, buf, (size_t)n);
    if (error == ECANCELED) {
      dsh_job_bridge_abandon(b);
      error = 0;
      continue; // Explicitly dropped, not added to delivered/ACK.
    }
    if (error)
      break;
  }
  close(r->fd);
  r->fd = -1;
  pthread_mutex_lock(&b->lock);
  if (error && !b->error)
    b->error = error;
  pthread_cond_broadcast(&b->changed);
  pthread_mutex_unlock(&b->lock);
  return NULL;
}
dsh_job_bridge *dsh_job_bridge_new(dsh_job_threads *m, uint64_t id, int root,
                                   struct dsh_job_stdio *io,
                                   dsh_job_output output, void *context,
                                   double (*now_ms)(void *), void *clock_context) {
  if (!m || !id || root <= 0 || !io || !output || io->host[0] < 0 ||
      io->host[1] < 0 || io->host[2] < 0) {
    errno = EINVAL;
    return NULL;
  }
  int pipe_error = dsh_writer_sigpipe_valid(io->host[0]);
  if (pipe_error) { errno = pipe_error; return NULL; }
  int input_flags = fcntl(io->host[0], F_GETFL);
  if (input_flags < 0) return NULL;
  if (!(input_flags & O_NONBLOCK)) { errno = EINVAL; return NULL; }
  if (atomic_load(&active) || (exit_hook && exit_hook != exited)) {
    errno = EBUSY;
    return NULL;
  }
  lock(&pids_lock);
  struct task *t = pid_get_task(root);
  struct task *supervisor = t ? t->parent : NULL;
  bool valid = t && t->dsh_job_id == id && supervisor && supervisor->pid == 1 &&
               supervisor->group;
  unlock(&pids_lock);
  if (!valid) {
    errno = EINVAL;
    return NULL;
  }
  dsh_job_bridge *b = calloc(1, sizeof *b);
  if (!b)
    return NULL;
  int e = pthread_mutex_init(&b->lock, NULL);
  if (e) {
    free(b);
    errno = e;
    return NULL;
  }
  pthread_condattr_t attr;
  e = pthread_condattr_init(&attr);
  if (e) {
    pthread_mutex_destroy(&b->lock);
    free(b);
    errno = e;
    return NULL;
  }
#ifndef __APPLE__
  e = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
#endif
  if (!e)
    e = pthread_cond_init(&b->changed, &attr);
  pthread_condattr_destroy(&attr);
  if (e) {
    pthread_mutex_destroy(&b->lock);
    free(b);
    errno = e;
    return NULL;
  }
  b->now_ms = now_ms; b->clock_context = clock_context;
  b->threads = m;
  b->id = id;
  b->root_pid = root;
  b->supervisor = supervisor;
  b->stdin_fd = io->host[0];
  io->host[0] = -1;
  b->output = output;
  b->context = context;
  for (int i = 0; i < 2; i++) {
    b->readers[i] =
        (struct reader){.owner = b, .fd = io->host[i + 1], .stream = i + 1};
    io->host[i + 1] = -1;
  }
  exit_hook = exited;
  atomic_store(&active, b);
  for (int i = 0; i < 2; i++) {
    pthread_t thread;
    e = dsh_job_threads_spawn(m, id, &thread, read_output, &b->readers[i]);
    if (e) {
      pthread_mutex_lock(&b->lock);
      b->error = e;
      pthread_mutex_unlock(&b->lock);
      for (int j = i; j < 2; j++) {
        close(b->readers[j].fd);
        b->readers[j].fd = -1;
      }
      break;
    }
  }
  return b;
}
int dsh_job_bridge_ack(dsh_job_bridge *b, int stream, uint64_t upto) {
  if (!b || stream < 1 || stream > 2)
    return EINVAL;
  pthread_mutex_lock(&b->lock);
  struct reader *r = &b->readers[stream - 1];
  int e = 0;
  if (b->settled || b->error)
    e = EIO;
  else if (upto < r->delivered || upto > r->emitted)
    e = EINVAL;
  else {
    r->delivered = upto;
    pthread_cond_broadcast(&b->changed);
  }
  pthread_mutex_unlock(&b->lock);
  return e;
}
int dsh_job_bridge_finish(dsh_job_bridge *b, unsigned timeout_ms, int *status) {
  if (!b || !status)
    return EINVAL;
  pthread_mutex_lock(&b->lock);
  if (b->finishing || b->settled) {
    pthread_mutex_unlock(&b->lock);
    return EBUSY;
  }
  b->finishing = true;
  pthread_mutex_unlock(&b->lock);
  // Normal work has no total runtime deadline. Only cancellation/abandonment
  // starts the bounded cleanup window. The output callback must wake on Env loss.
  int e = dsh_job_threads_seal(b->threads, b->id);
  while (!e) {
    enum dsh_thread_state state;
    size_t pending;
    dsh_job_threads_status(b->threads, &state, &pending);
    if (state == DSH_THREADS_READY) break;
    if (state != DSH_THREADS_RUNNING) { e = EIO; break; }
    pthread_mutex_lock(&b->lock);
    double cancelled_at = b->cancelled_at;
    bool cancelled = b->cancelled;
    int error = b->error;
    pthread_mutex_unlock(&b->lock);
    if (error) { e = error; break; }
    if (cancelled && budget_now(b) - cancelled_at >= timeout_ms) {
      e = ETIMEDOUT; break;
    }
    struct timespec pause = {0, 10000000};
    nanosleep(&pause, NULL);
  }
  pthread_mutex_lock(&b->lock);
  if (!e)
    e = b->error ? b->error
                 : (!b->exited || !b->readers[0].eof || !b->readers[1].eof ? EIO
                                                                           : 0);
  while (!e && !b->abandoned && (b->readers[0].delivered != b->readers[0].emitted ||
                b->readers[1].delivered != b->readers[1].emitted)) {
    if (b->cancelled && budget_now(b) - b->cancelled_at >= timeout_ms) {
      e = ETIMEDOUT;
      break;
    }
#ifdef __APPLE__
    struct timespec deadline = {0, 10000000};
    int waited = pthread_cond_timedwait_relative_np(&b->changed, &b->lock, &deadline);
#else
    uint64_t end = millis() + 10;
    struct timespec deadline = {(time_t)(end / 1000), (long)(end % 1000) * 1000000};
    int waited = pthread_cond_timedwait(&b->changed, &b->lock, &deadline);
#endif
    if (waited && waited != ETIMEDOUT) e = waited;
  }
  pthread_mutex_unlock(&b->lock);
  if (!e) {
    int guest_error = dsh_job_reap(b->supervisor, b->id);
    if (guest_error)
      e = EIO;
  }
  pthread_mutex_lock(&b->lock);
  // Once all waits have completed (or failed), stop further input without
  // treating this cleanup as successful guest EOF or cancellation.
  if (b->stdin_fd >= 0) { close(b->stdin_fd); b->stdin_fd = -1; }
  if (!e) {
    *status = b->status;
    b->settled = true;
  } else if (!b->error)
    b->error = e;
  pthread_mutex_unlock(&b->lock);
  if (e)
    dsh_job_threads_fault(b->threads, b->id);
  return e;
}
int dsh_job_bridge_destroy(dsh_job_bridge *b) {
  if (!b || !b->settled)
    return EBUSY;
  atomic_store(&active, NULL);
  pthread_cond_destroy(&b->changed);
  pthread_mutex_destroy(&b->lock);
  free(b);
  return 0;
}

int dsh_job_bridge_stdin_write(dsh_job_bridge *b, uint64_t id,
 const void *bytes, size_t size, size_t *written) {
 if (!b || !written || (!bytes && size)) return EINVAL;
 *written=0;
 pthread_mutex_lock(&b->lock);
 int e=0;
 if(id!=b->id) e=ESTALE;
 else if(b->error || b->settled) e=EIO;
 else if(b->exited || b->stdin_fd<0) e=EPIPE;
 else {
  e=dsh_writer_sigpipe_valid(b->stdin_fd);
  if(!e) { ssize_t n=dsh_pipe_write_nosignal(b->stdin_fd,bytes,size); if(n<0) e=errno; else *written=(size_t)n; }
 }
 pthread_mutex_unlock(&b->lock); return e;
}
int dsh_job_bridge_stdin_close(dsh_job_bridge *b,uint64_t id) {
 if(!b) return EINVAL;
 pthread_mutex_lock(&b->lock); int e=0;
 if(id!=b->id) e=ESTALE;
 else if(b->stdin_fd>=0) { int fd=b->stdin_fd; b->stdin_fd=-1; if(close(fd)) e=errno; }
 pthread_mutex_unlock(&b->lock); return e;
}

int dsh_job_bridge_abandon(dsh_job_bridge *b) {
  if (!b) return EINVAL;
  pthread_mutex_lock(&b->lock);
  b->abandoned = true;
  if (!b->cancelled) { b->cancelled_at = budget_now(b); b->cancelled = true; }
  if (b->stdin_fd >= 0) { close(b->stdin_fd); b->stdin_fd = -1; }
  pthread_cond_broadcast(&b->changed);
  pthread_mutex_unlock(&b->lock);
  return 0;
}
int dsh_job_bridge_abandoned(dsh_job_bridge *b) {
  pthread_mutex_lock(&b->lock);
  int result = b->abandoned;
  pthread_mutex_unlock(&b->lock);
  return result;
}

void dsh_job_bridge_cancel_requested(dsh_job_bridge *b) {
  pthread_mutex_lock(&b->lock);
  if (!b->cancelled) { b->cancelled_at = budget_now(b); b->cancelled = true; }
  pthread_cond_broadcast(&b->changed);
  pthread_mutex_unlock(&b->lock);
}
