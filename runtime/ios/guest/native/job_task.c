#include "job_task.h"
#include "fs/fd.h"
#include "job_stdio.h"
#include "kernel/errno.h"
#include "kernel/signal.h"
#include "kernel/task.h"
int dsh_job_install_stdio(struct task *task, struct dsh_job_stdio *io) {
  if (!task || task->files || !io || !io->guest[0] || !io->guest[1] ||
      !io->guest[2])
    return _EINVAL;
  struct fdtable *table = fdtable_new(3);
  if (IS_ERR(table))
    return PTR_ERR(table);
  // New unpublished task/table, no concurrent guest access exists yet.
  for (int i = 0; i < 3; i++) {
    table->files[i] = io->guest[i];
    io->guest[i] = NULL;
  }
  task->files = table;
  return 0;
}
int dsh_job_signal(uint64_t id, int signal) {
  if (!id || (signal != SIGTERM_ && signal != SIGKILL_))
    return _EINVAL;
  int count = 0;
  lock(&pids_lock);
  for (dword_t pid = 1; pid <= MAX_PID; pid++) {
    struct task *task = pid_get_task(pid);
    if (!task || task->dsh_job_id != id || task->exiting)
      continue;
    send_signal(task, signal, SIGINFO_NIL);
    count++;
  }
  unlock(&pids_lock);
  return count;
}
// Upstream kernel/exit.c's host-pointer wait implementation (no guest memory).
extern int do_wait(int, pid_t_, struct siginfo_ *, struct rusage_ *, int);
int dsh_job_reap(struct task *supervisor, uint64_t id) {
  if (!supervisor || !supervisor->group || !id)
    return _EINVAL;
  struct task *saved = current;
  current = supervisor;
  int result = 0;
  for (;;) {
    pid_t_ found = 0;
    lock(&pids_lock);
    for (dword_t pid = 1; pid <= MAX_PID; pid++) {
      struct task *task = pid_get_task_zombie(pid);
      if (!task || task->dsh_job_id != id)
        continue;
      if (!task->zombie || !task->group || task->group->leader != task ||
          !task->parent || task->parent->group != supervisor->group) {
        result = _EBUSY;
        break;
      }
      found = pid;
      break;
    }
    unlock(&pids_lock);
    if (result || !found)
      break;
    struct siginfo_ info = {0};
    // P_PID=1, WNOHANG=1, WEXITED=4, defined in original exit.c.
    result = do_wait(1, found, &info, NULL, 1 | 4);
    if (result || info.child.pid != found) {
      if (!result)
        result = _EBUSY;
      break;
    }
  }
  current = saved;
  return result;
}
