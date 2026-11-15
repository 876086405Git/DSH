#include "guest_backend.h"
#include "guest_crash.h"
#include "guest_dns.h"
#include "bound_admission.h"
#include "bound_ish_fs.h"
#include "job_bridge.h"
#include "job_stdio.h"
#include "job_task.h"
#include "job_threads.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/signal.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static enum dsh_guest_state state;
static dsh_job_threads *threads;
static dsh_job_bridge *bridge;
static struct task *supervisor;
static uint64_t next_id, active_id;
static char *root_path, *crash_directory;
static struct dsh_crash_guard crash_guard = DSH_CRASH_GUARD_INIT;
static struct dsh_path_span *protected;
static size_t protected_count;
static int workspace_mounted, temp_mounted, waiting, install_change;

static int host_error(int e) {
  switch (e) {
    case 0: return 0;
    case _ENOENT: return ENOENT;
    case _ENOMEM: return ENOMEM;
    case _EACCES: return EACCES;
    case _EPERM: return EPERM;
    case _ENOEXEC: return ENOEXEC;
    case _ENOTDIR: return ENOTDIR;
    case _EEXIST: return EEXIST;
    case _EBUSY: return EBUSY;
    case _EINVAL: return EINVAL;
    default: return EIO;
  }
}
static int guest_dir(const char *path) {
  int e = generic_mkdirat(AT_PWD, path, 0755);
  if (e && e != _EEXIST) return host_error(e);
  struct statbuf s;
  e = generic_statat(AT_PWD, path, &s, false);
  if (e) return host_error(e);
  return S_ISDIR(s.mode) ? 0 : ENOTDIR;
}
static int prepare_devices(void) {
  static const struct { const char *path; unsigned minor; } devices[] = {
    {"/dev/null", DEV_NULL_MINOR}, {"/dev/zero", DEV_ZERO_MINOR},
    {"/dev/random", DEV_RANDOM_MINOR}, {"/dev/urandom", DEV_URANDOM_MINOR}
  };
  for (size_t i = 0; i < sizeof devices / sizeof devices[0]; ++i) {
    int e = generic_mknodat(AT_PWD, devices[i].path, S_IFCHR | 0666,
                           dev_make(MEM_MAJOR, devices[i].minor));
    if (e && e != _EEXIST) return host_error(e);
  }
  return 0;
}
int dsh_guest_initialize(const struct dsh_guest_options *options) {
  if (!options || !options->root || !options->protected_paths ||
      !options->protected_count || options->protected_count > 128) return EINVAL;
  char root[PATH_MAX], data[PATH_MAX], directory[PATH_MAX];
  pthread_mutex_lock(&gate);
  if (install_change) { pthread_mutex_unlock(&gate); return EBUSY; }
  // The install lease also protects root lookup: never carry a canonical path
  // across a concurrent uninstall. Preflight failures have not entered iSH.
  if (!realpath(options->root, root)) {
    int e = errno;
    pthread_mutex_unlock(&gate);
    return e;
  }
  // fakefs opens root/meta.db as well as root/data. Reject before entering iSH.
  if (!strcmp(root, "/") || strlen(root) > sizeof data - sizeof "/meta.db") {
    pthread_mutex_unlock(&gate);
    return EINVAL;
  }
  size_t parent_length = (size_t)(strrchr(root, '/') - root);
  if (!parent_length) { pthread_mutex_unlock(&gate); return EINVAL; }
  memcpy(directory, root, parent_length); directory[parent_length] = '\0';
  int suspended = 0;
  int record_error = dsh_crash_check(directory,
      state == DSH_GUEST_QUARANTINED ? NULL : &crash_guard, &suspended);
  if (record_error || suspended) {
    pthread_mutex_unlock(&gate);
    return record_error ? record_error : EOWNERDEAD;
  }
  if (state != DSH_GUEST_COLD) {
    int e = state == DSH_GUEST_QUARANTINED ? EIO :
            root_path && !strcmp(root_path, root) ? 0 : EBUSY;
    if (!e && options->protected_count + 1 != protected_count) e = EPERM;
    unsigned char matched[128] = {0};
    for (size_t i = 0; !e && i < options->protected_count; ++i) {
      const char *path = options->protected_paths[i];
      size_t j = 0;
      if (!path) { e = EINVAL; break; }
      for (; j < options->protected_count; ++j) {
        if (!matched[j] && !strcmp(path, protected[j + 1].bytes)) {
          matched[j] = 1; break;
        }
      }
      if (j == options->protected_count) e = EPERM;
    }
    pthread_mutex_unlock(&gate);
    return e;
  }
  root_path = strdup(root);
  crash_directory = strdup(directory);
  protected_count = options->protected_count + 1;
  protected = calloc(protected_count, sizeof *protected);
  int e = (!root_path || !crash_directory || !protected) ? ENOMEM : 0;
  for (size_t i = 0; !e && i < protected_count; ++i) {
    const char *path = i ? options->protected_paths[i - 1] : root;
    if (!path || path[0] != '/' || !path[1] || strlen(path) >= PATH_MAX) {
      e = EINVAL; break;
    }
    char *copy = strdup(path);
    if (!copy) { e = ENOMEM; break; }
    protected[i] = (struct dsh_path_span){copy, strlen(copy)};
  }
  // initialize itself enters upstream code before the first task's start.
  // A separate generation protects that phase without claiming a running task.
  uint64_t initialization = 0;
  if (!e) {
    if (next_id == UINT64_MAX) e = EOVERFLOW;
    else {
      initialization = ++next_id;
      e = dsh_crash_begin(&crash_guard, crash_directory, initialization, 1);
    }
  }
  int recorded = !e;
  // After entering upstream initialization, failure is permanent. The upstream
  // does not provide a complete allocation-failure/whole-kernel unwind API.
  if (!e) state = DSH_GUEST_QUARANTINED;
  struct task *saved = current;
  strcpy(data, root); strcat(data, "/data");
  if (!e) e = host_error(mount_root(&fakefs, data));
  if (!e) e = host_error(become_first_process());
  if (!e) {
    supervisor = current;
    static const char *dirs[] = {"/workspace", "/tmp", "/proc", "/dev", "/dev/pts"};
    for (size_t i = 0; !e && i < sizeof dirs / sizeof dirs[0]; ++i)
      e = guest_dir(dirs[i]);
  }
  if (!e) e = prepare_devices();
  if (!e) e = host_error(do_mount(&procfs, "proc", "/proc", "", 0));
  if (!e) e = host_error(do_mount(&devptsfs, "devpts", "/dev/pts", "", 0));
  if (!e) {
    threads = dsh_job_threads_new();
    if (!threads) e = errno;
  }
  if (!e) e = dsh_job_threads_install(threads);
  current = saved;
  // Initialization has no guest/output pthreads. A returned failure is settled;
  // a fatal signal never reaches this point and leaves the durable record.
  if (recorded) {
    int cleanup = dsh_crash_settle(&crash_guard, initialization);
    if (!e) e = cleanup;
  }
  if (!e) state = DSH_GUEST_READY;
  else if (state == DSH_GUEST_COLD) {
    for (size_t i = 0; protected && i < protected_count; ++i)
      free((void *)protected[i].bytes);
    free(protected); protected = NULL; protected_count = 0;
    free(root_path); root_path = NULL;
    free(crash_directory); crash_directory = NULL;
  }
  pthread_mutex_unlock(&gate);
  return e;
}
static int cwd_valid(const char *cwd) {
  if (!cwd || (strncmp(cwd, "/workspace", 10)) ||
      (cwd[10] && cwd[10] != '/')) return 0;
  const char *part = cwd + 1;
  for (const char *p = part;; ++p) {
    if (*p != '/' && *p) continue;
    size_t n = (size_t)(p - part);
    if (!n || (n == 1 && part[0] == '.') ||
        (n == 2 && !memcmp(part, "..", 2))) return 0;
    if (!*p) return 1;
    part = p + 1;
  }
}
static char *pack(const char *const *values, size_t count, int env) {
  if ((count && !values) || count > 4096) { errno = E2BIG; return NULL; }
  size_t bytes = 1;
  for (size_t i = 0; i < count; ++i) {
    if (!values[i] || (env && (!strchr(values[i], '=') || values[i][0] == '='))) {
      errno = EINVAL; return NULL;
    }
    size_t n = strnlen(values[i], 1024 * 1024);
    if (n == 1024 * 1024 || bytes > 1024 * 1024 - n - 1) {
      errno = E2BIG; return NULL;
    }
    bytes += n + 1;
  }
  char *result = calloc(1, bytes);
  if (!result) return NULL;
  char *at = result;
  for (size_t i = 0; i < count; ++i) {
    size_t n = strlen(values[i]) + 1;
    memcpy(at, values[i], n); at += n;
  }
  return result;
}
static int unmount_job(void) {
  int e = 0;
  lock(&mounts_lock);
  if (temp_mounted) {
    e = do_umount("/tmp");
    if (!e) temp_mounted = 0;
  }
  if (!e && workspace_mounted) {
    e = do_umount("/workspace");
    if (!e) workspace_mounted = 0;
  }
  unlock(&mounts_lock);
  return host_error(e);
}
// gate held, with no running guest threads at either transition. The fakefs
// and real-fd guards enforce this flag, not merely mount metadata reporting.
static int root_readonly(int readonly) {
  struct mount *root = supervisor->fs->root->mount;
  if (!root || root->fs != &fakefs) return EIO;
  if (readonly) root->flags |= MS_READONLY_;
  else root->flags &= ~MS_READONLY_;
  return 0;
}
int dsh_guest_start_with_permissions(const struct dsh_guest_request *request,
                    dsh_guest_output output, void *context, uint64_t *job_id, int root_writable, double (*now_ms)(void *), void *clock_context) {
  if ((root_writable != 0 && root_writable != 1) || !request || !output || !job_id || !request->argc || !request->argv ||
      !request->argv[0] || request->argv[0][0] != '/' || !cwd_valid(request->cwd) ||
      !request->workspace || !request->temporary ||
      (request->workspace_readonly != 0 && request->workspace_readonly != 1)) return EINVAL;
  *job_id = 0;
  char *args = pack(request->argv, request->argc, 0);
  if (!args) return errno;
  char *env = pack(request->env, request->envc, 1);
  if (!env) { int e = errno; free(args); return e; }
  pthread_mutex_lock(&gate);
  int e = state == DSH_GUEST_RUNNING ? EBUSY :
          state != DSH_GUEST_READY ? EIO : 0;
  dsh_root *workspace = NULL, *temporary = NULL;
  struct task *saved = current, *task = NULL;
  struct dsh_job_stdio io = {{NULL, NULL, NULL}, {-1, -1, -1}};
  uint64_t generation = 0;
  int recorded = 0;
  if (!e) {
    struct dsh_path_span path = {request->workspace, strlen(request->workspace)};
    workspace = dsh_admit_workspace(path, protected, protected_count, request->workspace_readonly != 0);
    if (!workspace) e = errno;
  }
  if (!e) {
    // Temp must be a separate capability, not an alias/ancestor of workspace.
    struct dsh_path_span *deny = malloc((protected_count + 1) * sizeof *deny);
    if (!deny) e = ENOMEM;
    else {
      memcpy(deny, protected, protected_count * sizeof *deny);
      deny[protected_count] = (struct dsh_path_span){request->workspace, strlen(request->workspace)};
      struct dsh_path_span path = {request->temporary, strlen(request->temporary)};
      temporary = dsh_admit_workspace(path, deny, protected_count + 1, false);
      if (!temporary) e = errno;
      free(deny);
    }
  }
  // DNS synchronization already calls into the guest filesystem. Persist first,
  // before any iSH work; rejected/queued calls never own another task's record.
  if (!e) {
    if (next_id == UINT64_MAX) e = EOVERFLOW;
    else {
      generation = ++next_id;
      e = dsh_crash_begin(&crash_guard, crash_directory, generation, 0);
      recorded = !e;
    }
  }
  // Refresh before exposing any approved host directory to the guest namespace.
  // A DNS preparation failure starts no task, borrows no context, and remains
  // READY so the caller can retry after the network/configuration is repaired.
  if (!e) {
    current = supervisor;
    e = dsh_dns_sync();
  }
  // Trusted DNS maintenance finishes before the guest's readonly epoch.
  if (!e) e = root_readonly(!root_writable);
  int touched = 0;
  if (!e) {
    touched = 1;
    current = supervisor;
    e = host_error(dsh_bound_mount("/workspace", workspace, 0, 0));
    if (!e) { workspace = NULL; workspace_mounted = 1; }
  }
  if (!e) {
    e = host_error(dsh_bound_mount("/tmp", temporary, 0, 0));
    if (!e) { temporary = NULL; temp_mounted = 1; }
  }
  if (!e) e = host_error(become_new_init_child());
  if (!e) {
    task = current;
    active_id = generation;
    task->dsh_job_id = active_id;
    e = dsh_job_threads_begin(threads, active_id);
  }
  if (!e) {
    struct fd *cwd = generic_open(request->cwd, O_RDONLY_ | O_DIRECTORY_, 0);
    if (IS_ERR(cwd)) e = host_error(PTR_ERR(cwd));
    else fs_chdir(task->fs, cwd);
  }
  if (!e) e = host_error(do_execve(request->argv[0], request->argc, args, env));
  if (!e) {
    fdtable_release(task->files); task->files = NULL;
    e = dsh_job_stdio_new(&io, 0, 0);
  }
  if (!e) e = host_error(dsh_job_install_stdio(task, &io));
  if (!e) {
    bridge = dsh_job_bridge_new(threads, active_id, task->pid, &io, output, context, now_ms, clock_context);
    if (!bridge) e = errno;
  }
  if (!e) {
    *job_id = active_id; // Publish before first guest/output callback.
    state = DSH_GUEST_RUNNING;
    e = host_error(task_start(task));
  }
  if (e && touched) {
    // No guest pthread has started on this path. Retire its pipes so partially
    // constructed readers see EOF; none can call output without guest bytes.
    if (task && task->files) { fdtable_release(task->files); task->files = NULL; }
    state = DSH_GUEST_QUARANTINED;
    *job_id = 0;
  }
  // DNS/preflight failure started no task. Once mount/task construction was
  // touched, the backend cannot prove full settlement: retain the record.
  if (e && recorded && !touched) {
    int cleanup = dsh_crash_settle(&crash_guard, generation);
    if (cleanup) state = DSH_GUEST_QUARANTINED;
  }
  current = saved;
  dsh_job_stdio_close(&io);
  if (workspace) dsh_root_free(workspace);
  if (temporary) dsh_root_free(temporary);
  pthread_mutex_unlock(&gate);
  free(args); free(env);
  return e;
}
int dsh_guest_start_with_clock(const struct dsh_guest_request *request,
    dsh_guest_output output, void *context, uint64_t *job_id,
    double (*now_ms)(void *), void *clock_context) {
  return dsh_guest_start_with_permissions(request, output, context, job_id,
      0, now_ms, clock_context);
}
int dsh_guest_start(const struct dsh_guest_request *request,
    dsh_guest_output output, void *context, uint64_t *job_id) {
  return dsh_guest_start_with_clock(request, output, context, job_id, NULL, NULL);
}
static int active(uint64_t id) {
  return !id || id != active_id || !bridge ? ESTALE :
         state != DSH_GUEST_RUNNING ? EIO : 0;
}
int dsh_guest_stdin_write(uint64_t id, const void *bytes, size_t count, size_t *written) {
  pthread_mutex_lock(&gate);
  int e = active(id);
  if (!e) e = dsh_job_bridge_stdin_write(bridge, id, bytes, count, written);
  pthread_mutex_unlock(&gate);
  return e;
}
int dsh_guest_stdin_close(uint64_t id) {
  pthread_mutex_lock(&gate);
  int e = active(id);
  if (!e) e = dsh_job_bridge_stdin_close(bridge, id);
  pthread_mutex_unlock(&gate);
  return e;
}
int dsh_guest_ack(uint64_t id, int stream, uint64_t end) {
  pthread_mutex_lock(&gate);
  int e = active(id);
  if (!e) e = dsh_job_bridge_ack(bridge, stream, end);
  pthread_mutex_unlock(&gate);
  return e;
}
static void *escalate(void *argument) {
  uint64_t id = *(uint64_t *)argument; free(argument);
  struct timespec delay = {0, 200000000};
  while (nanosleep(&delay, &delay) && errno == EINTR) {}
  pthread_mutex_lock(&gate);
  if (id == active_id && bridge) dsh_job_signal(id, SIGKILL_);
  pthread_mutex_unlock(&gate);
  return NULL;
}
static int cancel_locked(uint64_t id) {
  int e = active(id);
  if (e) return e;
  dsh_job_bridge_cancel_requested(bridge);
  dsh_job_signal(id, SIGTERM_);
  uint64_t *copy = malloc(sizeof *copy);
  if (!copy) { dsh_job_signal(id, SIGKILL_); return 0; }
  *copy = id;
  pthread_t thread;
  e = pthread_create(&thread, NULL, escalate, copy);
  if (e) { free(copy); dsh_job_signal(id, SIGKILL_); return 0; }
  pthread_detach(thread);
  return 0;
}
int dsh_guest_cancel(uint64_t id) {
  pthread_mutex_lock(&gate);
  int e = cancel_locked(id);
  pthread_mutex_unlock(&gate);
  return e;
}
int dsh_guest_abandon(uint64_t id) {
  pthread_mutex_lock(&gate);
  int e = active(id);
  if (!e) { dsh_job_bridge_abandon(bridge); e = cancel_locked(id); }
  pthread_mutex_unlock(&gate);
  return e;
}
int dsh_guest_wait(uint64_t id, unsigned timeout_ms, struct dsh_guest_result *result) {
  if (!result || timeout_ms < 200) return EINVAL;
  memset(result, 0, sizeof *result);
  pthread_mutex_lock(&gate);
  int e = active(id);
  if (!e && waiting) e = EBUSY;
  if (e) { pthread_mutex_unlock(&gate); return e; }
  waiting = 1;
  dsh_job_bridge *job = bridge;
  pthread_mutex_unlock(&gate);
  int status = 0;
  e = dsh_job_bridge_finish(job, timeout_ms, &status);
  pthread_mutex_lock(&gate);
  result->abandoned = dsh_job_bridge_abandoned(job);
  if (!e) e = dsh_job_bridge_destroy(job);
  if (!e) { bridge = NULL; e = unmount_job(); }
  // Only a fully reaped/settled job may restore maintenance/write admission.
  // Any quarantine retains its last policy; no new job can enter that kernel.
  if (!e) e = root_readonly(0);
  if (e) { dsh_job_signal(id, SIGKILL_); state = DSH_GUEST_QUARANTINED; }
  else {
    result->exit_code = (status & 0x7f) ? 128 + (status & 0x7f) : (status >> 8) & 255;
    result->resources_settled = 1;
    active_id = 0;
    e = dsh_crash_settle(&crash_guard, id);
    state = e ? DSH_GUEST_QUARANTINED : DSH_GUEST_READY;
  }
  waiting = 0;
  pthread_mutex_unlock(&gate);
  return e;
}
enum dsh_guest_state dsh_guest_status(void) {
  pthread_mutex_lock(&gate);
  enum dsh_guest_state result = state;
  pthread_mutex_unlock(&gate);
  return result;
}

int dsh_guest_crash_status(const char *directory, int *suspended) {
  pthread_mutex_lock(&gate);
  int e = dsh_crash_check(directory,
      state == DSH_GUEST_QUARANTINED ? NULL : &crash_guard, suspended);
  pthread_mutex_unlock(&gate);
  return e;
}
int dsh_guest_crash_resume(const char *directory) {
  pthread_mutex_lock(&gate);
  int e = state == DSH_GUEST_RUNNING || state == DSH_GUEST_QUARANTINED ||
          install_change ? EBUSY : dsh_crash_resume(directory, &crash_guard);
  pthread_mutex_unlock(&gate);
  return e;
}

int dsh_guest_begin_install_change(void) {
  pthread_mutex_lock(&gate);
  int e = state != DSH_GUEST_COLD || install_change ? EBUSY : 0;
  if (!e) install_change = 1;
  pthread_mutex_unlock(&gate);
  return e;
}
void dsh_guest_end_install_change(void) {
  pthread_mutex_lock(&gate);
  install_change = 0;
  pthread_mutex_unlock(&gate);
}

int dsh_guest_kill(uint64_t id) {
  pthread_mutex_lock(&gate);
  int e = active(id);
  if (!e) { dsh_job_bridge_cancel_requested(bridge); dsh_job_signal(id, SIGKILL_); }
  pthread_mutex_unlock(&gate);
  return e;
}
