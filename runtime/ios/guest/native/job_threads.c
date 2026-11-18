#include "job_threads.h"
#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <time.h>
#include <signal.h>
struct record {
  pthread_t thread;
  void *(*entry)(void *);
  void *argument;
  struct dsh_job_threads *owner;
  struct record *next;
};
struct dsh_job_threads {
  pthread_mutex_t lock;
  pthread_cond_t changed;
  pthread_t reaper;
  enum dsh_thread_state state;
  uint64_t current, settled;
  size_t pending;
  bool sealed, stopping;
  struct record *head, *tail;
};
static _Atomic(dsh_job_threads *) installed;
static void settle(dsh_job_threads *m) {
  if (m->state == DSH_THREADS_RUNNING && m->sealed && m->pending == 0) {
    m->settled = m->current;
    m->state = DSH_THREADS_READY;
  }
  pthread_cond_broadcast(&m->changed);
}
static void *entry(void *argument) {
  struct record *r = argument;
  dsh_job_threads *m = r->owner;
  pthread_mutex_lock(&m->lock);
  void *(*fn)(void *) = r->entry;
  void *arg = r->argument;
  uint64_t id = m->current;
  pthread_mutex_unlock(&m->lock);
  // Guest-created pipes/sockets also write through upstream realfs/sock ops.
  // Block host SIGPIPE for the lifetime of our dedicated native thread; guest
  // EPIPE/signal semantics remain in the emulated kernel. No global disposition.
  sigset_t block;
  sigemptyset(&block); sigaddset(&block, SIGPIPE);
  if (pthread_sigmask(SIG_BLOCK, &block, NULL)) {
    dsh_job_threads_fault(m, id);
    return NULL;
  }
  sigemptyset(&block); sigaddset(&block, SIGUSR1);
  if (pthread_sigmask(SIG_UNBLOCK, &block, NULL)) {
    dsh_job_threads_fault(m, id);
    return NULL;
  }
  return fn(arg);
}
static void *reap(void *argument) {
  dsh_job_threads *m = argument;
  pthread_mutex_lock(&m->lock);
  for (;;) {
    while (!m->head && !m->stopping)
      pthread_cond_wait(&m->changed, &m->lock);
    if (m->stopping)
      break;
    struct record *r = m->head;
    m->head = r->next;
    if (!m->head)
      m->tail = NULL;
    pthread_mutex_unlock(&m->lock);
    // Join returns after pthread cleanup handlers AND TLS destructors, unlike
    // exit_hook.
    int result = pthread_join(r->thread, NULL);
    pthread_mutex_lock(&m->lock);
    if (result) {
      m->state = DSH_THREADS_FAULT;
    } else {
      m->pending--;
      free(r);
    }
    settle(m);
  }
  pthread_mutex_unlock(&m->lock);
  return NULL;
}
dsh_job_threads *dsh_job_threads_new(void) {
  dsh_job_threads *m = calloc(1, sizeof *m);
  if (!m)
    return NULL;
  int e = pthread_mutex_init(&m->lock, NULL);
  if (e) {
    free(m);
    errno = e;
    return NULL;
  }
  pthread_condattr_t attr;
  e = pthread_condattr_init(&attr);
  if (e) {
    pthread_mutex_destroy(&m->lock);
    free(m);
    errno = e;
    return NULL;
  }
#if !defined(__APPLE__)
  e = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
#endif
  if (!e)
    e = pthread_cond_init(&m->changed, &attr);
  pthread_condattr_destroy(&attr);
  if (e) {
    pthread_mutex_destroy(&m->lock);
    free(m);
    errno = e;
    return NULL;
  }
  m->state = DSH_THREADS_READY;
  e = pthread_create(&m->reaper, NULL, reap, m);
  if (e) {
    pthread_cond_destroy(&m->changed);
    pthread_mutex_destroy(&m->lock);
    free(m);
    errno = e;
    return NULL;
  }
  return m;
}
int dsh_job_threads_begin(dsh_job_threads *m, uint64_t id) {
  pthread_mutex_lock(&m->lock);
  int e = 0;
  if (m->state == DSH_THREADS_FAULT || m->state == DSH_THREADS_STOPPED)
    e = EIO;
  else if (m->state != DSH_THREADS_READY)
    e = EBUSY;
  else if (!id || id <= m->current)
    e = EINVAL;
  else {
    m->current = id;
    m->sealed = false;
    m->state = DSH_THREADS_RUNNING;
  }
  pthread_mutex_unlock(&m->lock);
  return e;
}
int dsh_job_threads_spawn(dsh_job_threads *m, uint64_t id, pthread_t *out,
                          void *(*fn)(void *), void *arg) {
  if (!out || !fn)
    return EINVAL;
  struct record *r = calloc(1, sizeof *r);
  if (!r)
    return ENOMEM;
  r->owner = m;
  r->entry = fn;
  r->argument = arg;
  pthread_mutex_lock(&m->lock);
  if (m->state != DSH_THREADS_RUNNING || id != m->current ||
      (m->sealed && m->pending == 0)) {
    pthread_mutex_unlock(&m->lock);
    free(r);
    return EAGAIN;
  }
  // The new thread blocks on this same lock until its identity is published.
  int e = pthread_create(&r->thread, NULL, entry, r);
  if (e) {
    pthread_mutex_unlock(&m->lock);
    free(r);
    return e;
  }
  *out = r->thread;
  m->pending++;
  if (m->tail)
    m->tail->next = r;
  else
    m->head = r;
  m->tail = r;
  pthread_cond_broadcast(&m->changed);
  pthread_mutex_unlock(&m->lock);
  return 0;
}
int dsh_job_threads_seal(dsh_job_threads *m, uint64_t id) {
  pthread_mutex_lock(&m->lock);
  int e = 0;
  if (m->state != DSH_THREADS_RUNNING || m->current != id)
    e = EINVAL;
  else {
    m->sealed = true;
    settle(m);
  }
  pthread_mutex_unlock(&m->lock);
  return e;
}
static struct timespec deadline(unsigned ms) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  t.tv_sec += ms / 1000;
  t.tv_nsec += (long)(ms % 1000) * 1000000;
  if (t.tv_nsec >= 1000000000) {
    t.tv_sec++;
    t.tv_nsec -= 1000000000;
  }
  return t;
}
int dsh_job_threads_wait(dsh_job_threads *m, uint64_t id, unsigned timeout_ms) {
  struct timespec end = deadline(timeout_ms);
  pthread_mutex_lock(&m->lock);
  int e = 0;
  if (id != m->current || !m->sealed)
    e = EINVAL;
  while (!e && m->state == DSH_THREADS_RUNNING) {
#if defined(__APPLE__)
    struct timespec now, remaining;
    clock_gettime(CLOCK_MONOTONIC, &now);
    remaining.tv_sec = end.tv_sec - now.tv_sec;
    remaining.tv_nsec = end.tv_nsec - now.tv_nsec;
    if (remaining.tv_nsec < 0) {
      remaining.tv_sec--;
      remaining.tv_nsec += 1000000000;
    }
    int wait_result = remaining.tv_sec < 0
                          ? ETIMEDOUT
                          : pthread_cond_timedwait_relative_np(
                                &m->changed, &m->lock, &remaining);
#else
    int wait_result = pthread_cond_timedwait(&m->changed, &m->lock, &end);
#endif
    if (wait_result == ETIMEDOUT && m->state == DSH_THREADS_RUNNING) {
      m->state = DSH_THREADS_FAULT;
      e = ETIMEDOUT;
      pthread_cond_broadcast(&m->changed);
    } else if (wait_result && wait_result != ETIMEDOUT) {
      m->state = DSH_THREADS_FAULT;
      e = wait_result;
    }
  }
  if (!e && m->state != DSH_THREADS_READY)
    e = EIO;
  pthread_mutex_unlock(&m->lock);
  return e;
}
void dsh_job_threads_status(dsh_job_threads *m, enum dsh_thread_state *s,
                            size_t *n) {
  pthread_mutex_lock(&m->lock);
  *s = m->state;
  *n = m->pending;
  pthread_mutex_unlock(&m->lock);
}
int dsh_job_threads_destroy(dsh_job_threads *m) {
  if (atomic_load(&installed) == m)
    return EBUSY;
  pthread_mutex_lock(&m->lock);
  if (m->pending || m->state == DSH_THREADS_RUNNING) {
    pthread_mutex_unlock(&m->lock);
    return EBUSY;
  }
  m->stopping = true;
  m->state = DSH_THREADS_STOPPED;
  pthread_cond_broadcast(&m->changed);
  pthread_mutex_unlock(&m->lock);
  int e = pthread_join(m->reaper, NULL);
  if (e)
    return e;
  pthread_cond_destroy(&m->changed);
  pthread_mutex_destroy(&m->lock);
  free(m);
  return 0;
}
int dsh_job_threads_install(dsh_job_threads *m) {
  if (!m)
    return EINVAL;
  dsh_job_threads *expected = NULL;
  return atomic_compare_exchange_strong(&installed, &expected, m) ? 0
         : expected == m                                          ? 0
                                                                  : EBUSY;
}
int dsh_guest_task_start(uint64_t id, pthread_t *t, void *(*fn)(void *),
                         void *arg) {
  dsh_job_threads *m = atomic_load(&installed);
  if (!m || !id)
    return EAGAIN;
  return dsh_job_threads_spawn(m, id, t, fn, arg);
}

int dsh_job_threads_fault(dsh_job_threads *m, uint64_t id) {
  if (!m || !id)
    return EINVAL;
  pthread_mutex_lock(&m->lock);
  int e = 0;
  if (m->current != id || m->state == DSH_THREADS_STOPPED)
    e = EINVAL;
  else {
    m->state = DSH_THREADS_FAULT;
    pthread_cond_broadcast(&m->changed);
  }
  pthread_mutex_unlock(&m->lock);
  return e;
}
