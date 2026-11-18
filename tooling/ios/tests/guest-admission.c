#include "bound_admission.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct dsh_path_span span(const char *path) {
  return (struct dsh_path_span){path, strlen(path)};
}

#ifdef TEST_DARWIN
// Exercise the production Darwin branch on Linux without emulating a filesystem.
// Opening any ancestor is forbidden, as on the affected iOS device.
#ifndef __APPLE__
#define __APPLE__ 1
#endif
#ifndef F_GETPATH
#define F_GETPATH 0x7ffffffe
#endif
static const char *workspace = "/private/var/mobile/Containers/Data/Application/test/workspace";
static int opens, closes, path_queries, root_calls;
static int open_error, path_error, root_error;
static bool path_changed, root_readonly;
static int root_sentinel;
static int admission_open(const char *path, int flags, ...) {
  opens++;
  assert(!strcmp(path, workspace));
  assert(flags == (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (open_error) {
    errno = open_error;
    return -1;
  }
  return 17;
}
static int admission_close(int fd) {
  assert(fd == 17);
  closes++;
  errno = EBADF; // Cleanup must not mask the original admission failure.
  return 0;
}
static int admission_fcntl(int fd, int command, ...) {
  assert(fd == 17 && command == F_GETPATH);
  path_queries++;
  if (path_error) {
    errno = path_error;
    return -1;
  }
  va_list args;
  va_start(args, command);
  strcpy(va_arg(args, char *), path_changed ? "/outside/swapped" : workspace);
  va_end(args);
  return 0;
}
static char *admission_realpath(const char *path, char *resolved) {
  assert(resolved);
  strcpy(resolved, path);
  return resolved;
}
dsh_root *dsh_root_new_workspace(int fd, bool readonly) {
  assert(fd == 17);
  root_calls++;
  root_readonly = readonly;
  if (root_error) {
    errno = root_error;
    return NULL;
  }
  return (dsh_root *)&root_sentinel;
}
#define open admission_open
#define close admission_close
#define fcntl admission_fcntl
#define realpath admission_realpath
#include "bound_admission.c"
#undef open
#undef close
#undef fcntl
#undef realpath

static void reset(void) {
  opens = closes = path_queries = root_calls = 0;
  open_error = path_error = root_error = 0;
  path_changed = root_readonly = false;
}
static dsh_root *admit(bool readonly) {
  struct dsh_path_span protected = span("/private/var/mobile/Containers/Data/Application/test/state");
  return dsh_admit_workspace(span(workspace), &protected, 1, readonly);
}
int main(void) {
  reset();
  assert(admit(true) == (dsh_root *)&root_sentinel);
  assert(opens == 1 && path_queries == 1 && closes == 1 && root_calls == 1);
  assert(root_readonly);

  reset();
  assert(admit(false) == (dsh_root *)&root_sentinel && !root_readonly);
  assert(closes == 1);

  reset();
  open_error = ELOOP; // The final directory was swapped for a symlink.
  assert(!admit(false) && errno == ELOOP);
  assert(opens == 1 && !path_queries && !closes && !root_calls);

  reset();
  path_error = EIO;
  assert(!admit(false) && errno == EIO);
  assert(closes == 1 && !root_calls);

  reset();
  path_changed = true; // An ancestor redirect/rename changed the opened path.
  assert(!admit(false) && errno == EPERM);
  assert(closes == 1 && !root_calls);

  reset();
  root_error = EMFILE;
  assert(!admit(false) && errno == EMFILE);
  assert(closes == 1 && root_calls == 1);

  reset();
  struct dsh_path_span protected = span(workspace);
  assert(!dsh_admit_workspace(span(workspace), &protected, 1, false));
  assert(errno == EPERM && !opens);
  assert(!dsh_admit_workspace(span(workspace), NULL, 0, false));
  assert(errno == EINVAL && !opens);
  return 0;
}
#else
static void path_join(char *out, const char *base, const char *leaf) {
  int n = snprintf(out, PATH_MAX, "%s/%s", base, leaf);
  assert(n > 0 && n < PATH_MAX);
}
int main(int argc, char **argv) {
  assert(argc == 2);
  char base[PATH_MAX], workspace[PATH_MAX], protected[PATH_MAX], child[PATH_MAX];
  assert(realpath(argv[1], base));
  path_join(workspace, base, "workspace");
  path_join(protected, base, "state");
  assert(!mkdir(workspace, 0700) && !mkdir(protected, 0700));
  struct dsh_path_span blocked = span(protected);
  for (int readonly = 0; readonly <= 1; readonly++) {
    dsh_root *root = dsh_admit_workspace(span(workspace), &blocked, 1, readonly);
    assert(root && dsh_root_readonly(root) == (bool)readonly);
    dsh_root_free(root);
  }
  assert(!dsh_admit_workspace(span(protected), &blocked, 1, false) && errno == EPERM);
  assert(!dsh_admit_workspace(span(base), &blocked, 1, false) && errno == EPERM);
  assert(!dsh_admit_workspace(span("/"), &blocked, 1, false));
  assert(!dsh_admit_workspace(span(workspace), NULL, 0, false) && errno == EINVAL);
  path_join(child, workspace, "../workspace");
  assert(!dsh_admit_workspace(span(child), &blocked, 1, false) && errno == EINVAL);

  // Recursive copy adjusts directory modes. Its descriptor must retain the
  // readonly policy and must never follow a host symlink to another root.
  dsh_root *writable = dsh_admit_workspace(span(workspace), &blocked, 1, false);
  dsh_root *readonly = dsh_admit_workspace(span(workspace), &blocked, 1, true);
  assert(writable && readonly);
  assert(!dsh_directory_make(writable, "copy", 4, 0755));
  dsh_directory *rw = dsh_directory_open(writable, "copy", 4);
  dsh_directory *ro = dsh_directory_open(readonly, "copy", 4);
  assert(rw && ro && !dsh_directory_chmod(rw, 0700));
  assert(dsh_directory_chmod(ro, 0755) < 0 && errno == EROFS);
  assert(dsh_directory_chmod(rw, 01777) < 0 && errno == EPERM);
  struct stat copied;
  assert(!dsh_directory_stat(rw, &copied) && (copied.st_mode & 07777) == 0700);
  struct timespec times[2] = {{1000, 0}, {2000, 0}};
  assert(!dsh_directory_times(rw, times));
  times[1].tv_sec = 3000;
  assert(dsh_directory_times(ro, times) < 0 && errno == EROFS);
  assert(!dsh_directory_stat(rw, &copied) && copied.st_mtime == 2000);
  path_join(child, workspace, "outside-directory");
  assert(!symlink(protected, child));
  assert(!dsh_directory_open(writable, "outside-directory", 17));
  dsh_directory_close(rw);
  dsh_directory_close(ro);
  dsh_root_free(writable);
  dsh_root_free(readonly);

  path_join(child, protected, "missing");
  blocked = span(child);
  assert(!dsh_admit_workspace(span(protected), &blocked, 1, false) && errno == EPERM);
  path_join(child, base, "dangling");
  assert(!symlink("missing-target", child));
  blocked = span(child);
  assert(!dsh_admit_workspace(span(workspace), &blocked, 1, false) && errno == ELOOP);
  return 0;
}
#endif
