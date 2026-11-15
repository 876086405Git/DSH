// POSIX execution fixture for the production marker helper, without an iSH VM.
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int sync_calls, fail_sync_call, write_mode, write_calls;
static int test_fsync(int fd);
static ssize_t test_write(int fd, const void *bytes, size_t count);
#define fsync test_fsync
#define write test_write
#include "../../../runtime/ios/guest/native/guest_crash.h"
#undef fsync
#undef write
static int test_fsync(int fd) {
  if (++sync_calls == fail_sync_call) { errno = ENOSPC; return -1; }
  return fsync(fd);
}
static ssize_t test_write(int fd, const void *bytes, size_t count) {
  ++write_calls;
  if (write_mode == 1) { errno = ENOSPC; return -1; }
  if (write_mode == 2 && write_calls == 1) { errno = EINTR; return -1; }
  if (write_mode == 2 && count > 3) count = 3;
  return write(fd, bytes, count);
}
static int exists(const char *directory) {
  int suspended = -1;
  assert(dsh_crash_check(directory, NULL, &suspended) == 0);
  return suspended;
}
int main(int argc, char **argv) {
  assert(argc == 3);
  const char *mode = argv[1], *directory = argv[2];
  struct dsh_crash_guard guard = DSH_CRASH_GUARD_INIT;
  int suspended = -1;
  if (!strcmp(mode, "status")) {
    printf("%d\n", exists(directory));
  } else if (!strcmp(mode, "resume")) {
    assert(dsh_crash_resume(directory, &guard) == 0);
    assert(exists(directory) == 0);
  } else if (!strcmp(mode, "hold")) {
    assert(dsh_crash_begin(&guard, directory, 41, 0) == 0);
    assert(sync_calls == 2);
    puts("durable"); fflush(stdout);
    for (;;) pause();
  } else if (!strcmp(mode, "rejected")) {
    assert(dsh_crash_begin(&guard, directory, 42, 0) == EOWNERDEAD);
    assert(guard.record == -1 && guard.directory == -1 && sync_calls == 0);
  } else if (!strcmp(mode, "roundtrip")) {
    for (uint64_t id = 1; id <= 128; ++id) {
      assert(dsh_crash_begin(&guard, directory, id, id == 1) == 0);
      int record_fd = guard.record, directory_fd = guard.directory;
      struct stat st;
      assert(fstat(record_fd, &st) == 0 && (st.st_mode & 0777) == 0600);
      assert(dsh_crash_check(directory, &guard, &suspended) == 0 && !suspended);
      assert(exists(directory) == 1);
      // A later queue entry/Worker cannot replace, clear or resume this owner.
      assert(dsh_crash_begin(&guard, directory, id + 1, 0) == EBUSY);
      assert(dsh_crash_settle(&guard, id + 1) == ESTALE);
      assert(dsh_crash_resume(directory, &guard) == EBUSY);
      assert(exists(directory) == 1);
      assert(dsh_crash_settle(&guard, id) == 0);
      assert(exists(directory) == 0);
      errno = 0; assert(fcntl(record_fd, F_GETFD) == -1 && errno == EBADF);
      errno = 0; assert(fcntl(directory_fd, F_GETFD) == -1 && errno == EBADF);
    }
  } else if (!strcmp(mode, "short-write")) {
    write_mode = 2;
    assert(dsh_crash_begin(&guard, directory, UINT64_MAX, 1) == 0);
    assert(write_calls > 2);
    assert(dsh_crash_settle(&guard, UINT64_MAX) == 0);
  } else if (!strcmp(mode, "file-fsync") || !strcmp(mode, "dir-fsync") ||
             !strcmp(mode, "write-failure")) {
    if (!strcmp(mode, "write-failure")) write_mode = 1;
    else fail_sync_call = !strcmp(mode, "file-fsync") ? 1 : 2;
    int entered = 0;
    int error = dsh_crash_begin(&guard, directory, 43, 0);
    if (!error) ++entered;
    assert(error == EOWNERDEAD && !entered && guard.record == -1);
    assert(exists(directory) == 1);
    fail_sync_call = 0;
    assert(dsh_crash_resume(directory, &guard) == 0);
    assert(exists(directory) == 0);
    // The pause classification is an operation result, not a late file probe.
    assert(error == EOWNERDEAD);
  } else if (!strcmp(mode, "replaced")) {
    assert(dsh_crash_begin(&guard, directory, 45, 0) == 0);
    assert(unlinkat(guard.directory, DSH_GUEST_CRASH_RECORD, 0) == 0);
    int other = openat(guard.directory, DSH_GUEST_CRASH_RECORD,
        O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(other >= 0); close(other);
    assert(dsh_crash_settle(&guard, 45) == ESTALE);
    assert(exists(directory) == 1);
    assert(dsh_crash_resume(directory, &guard) == 0);
  } else if (!strcmp(mode, "unsettled")) {
    assert(dsh_crash_begin(&guard, directory, 46, 0) == 0);
    // Quarantine passes no live owner to status, while keeping the actual
    // guard open: status is suspended, and resume cannot clear active state.
    assert(exists(directory) == 1);
    assert(dsh_crash_resume(directory, &guard) == EBUSY);
    // Simulate process exit (no settle): release closes only descriptors.
    dsh_crash_release(&guard);
    assert(exists(directory) == 1);
  } else abort();
  return 0;
}
