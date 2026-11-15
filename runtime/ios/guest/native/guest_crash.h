#ifndef DSH_GUEST_CRASH_H
#define DSH_GUEST_CRASH_H

// Private POSIX helper. The backend gate serializes every call. A live record
// is owned by its open inode and generation, never by a reusable process ID.
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#define DSH_GUEST_CRASH_RECORD "active-task"
struct dsh_crash_guard { int directory, record; uint64_t generation; };
#define DSH_CRASH_GUARD_INIT { -1, -1, 0 }

static int dsh_crash_open_directory(const char *path) {
  if (!path || path[0] != '/' || !path[1]) { errno = EINVAL; return -1; }
  return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}
static int dsh_crash_sync(int fd) {
  int result;
  do { result = fsync(fd); } while (result && errno == EINTR);
  return result ? errno : 0;
}
static int dsh_crash_same_file(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
static void dsh_crash_release(struct dsh_crash_guard *guard) {
  if (guard->record >= 0) close(guard->record);
  if (guard->directory >= 0) close(guard->directory);
  *guard = (struct dsh_crash_guard)DSH_CRASH_GUARD_INIT;
}

// Presence is enough: an empty/truncated record is also an interrupted write.
// NULL live means no in-process task is entitled to claim the record as active.
static int dsh_crash_check(const char *path,
    const struct dsh_crash_guard *live, int *suspended) {
  if (!suspended) return EINVAL;
  *suspended = 0;
  int directory = dsh_crash_open_directory(path);
  if (directory < 0) return errno == ENOENT ? 0 : errno;
  struct stat record;
  int e = 0;
  if (fstatat(directory, DSH_GUEST_CRASH_RECORD, &record, AT_SYMLINK_NOFOLLOW))
    e = errno == ENOENT ? 0 : errno;
  else {
    *suspended = 1;
    if (live && live->record >= 0) {
      struct stat here, owner_directory, owner_record;
      if (fstat(directory, &here) || fstat(live->directory, &owner_directory) ||
          fstat(live->record, &owner_record)) e = errno;
      else if (dsh_crash_same_file(&here, &owner_directory) &&
               dsh_crash_same_file(&record, &owner_record)) *suspended = 0;
    }
  }
  close(directory);
  return e;
}

// The caller must not enter any kernel code unless this succeeds. On a partial
// write/fsync failure, leave the record for an explicit user resume; never run
// unprotected or silently overwrite an earlier interrupted task.
static int dsh_crash_begin(struct dsh_crash_guard *guard, const char *path,
                           uint64_t generation, int initializing) {
  if (!generation) return EINVAL;
  if (guard->record >= 0) return EBUSY;
  int directory = dsh_crash_open_directory(path);
  if (directory < 0) return errno;
  int record = openat(directory, DSH_GUEST_CRASH_RECORD,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (record < 0) {
    int e = errno == EEXIST ? EOWNERDEAD : errno;
    close(directory);
    return e;
  }
  char bytes[96];
  int length = snprintf(bytes, sizeof bytes,
      "dsh-guest-task 1\ngeneration %" PRIu64 "\nstage %s\n", generation,
      initializing ? "initialize" : "task");
  int e = length < 0 || (size_t)length >= sizeof bytes ? EOVERFLOW : 0;
  size_t at = 0;
  while (!e && at < (size_t)length) {
    ssize_t n = write(record, bytes + at, (size_t)length - at);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) e = n ? errno : EIO;
    else at += (size_t)n;
  }
  if (!e) e = dsh_crash_sync(record);
  if (!e) e = dsh_crash_sync(directory);
  if (e) {
    close(record); close(directory);
    // This call has already created a pause record. Decide that outcome while
    // the backend gate is held: an explicit resume may remove it before N-API
    // dispatch, but cannot turn this old engine's failed entry into a retry.
    // The original I/O errno is deliberately not carried through this ABI.
    return EOWNERDEAD;
  }
  *guard = (struct dsh_crash_guard){directory, record, generation};
  return 0;
}

// Only a genuinely settled owner may clear its exact record. Failed starts
// after kernel mutation and cleanup timeouts retain it until process restart.
static int dsh_crash_settle(struct dsh_crash_guard *guard, uint64_t generation) {
  if (!generation || guard->record < 0 || guard->generation != generation)
    return ESTALE;
  struct stat actual, owned;
  int e = 0;
  if (fstat(guard->record, &owned) || fstatat(guard->directory,
      DSH_GUEST_CRASH_RECORD, &actual, AT_SYMLINK_NOFOLLOW)) e = errno;
  else if (!dsh_crash_same_file(&actual, &owned)) e = ESTALE;
  else if (unlinkat(guard->directory, DSH_GUEST_CRASH_RECORD, 0)) e = errno;
  else e = dsh_crash_sync(guard->directory);
  dsh_crash_release(guard);
  return e;
}

static int dsh_crash_resume(const char *path,
                          const struct dsh_crash_guard *live) {
  if (live && live->record >= 0) return EBUSY;
  int directory = dsh_crash_open_directory(path);
  if (directory < 0) return errno == ENOENT ? 0 : errno;
  int e = 0;
  if (unlinkat(directory, DSH_GUEST_CRASH_RECORD, 0) && errno != ENOENT) e = errno;
  if (!e) e = dsh_crash_sync(directory);
  close(directory);
  return e;
}
#endif
