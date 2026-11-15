// Synthetic backend for the real marker helper + N-API errno-to-code adapter.
// Simulates resume winning before N-API dispatch after a real marker fsync error.
#define _GNU_SOURCE
#include "../../../runtime/ios/guest/native/guest_backend.h"
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int sync_calls;
static int fail_record_sync(int fd);
#define fsync fail_record_sync
#include "../../../runtime/ios/guest/native/guest_crash.h"
#undef fsync
static int fail_record_sync(int fd) {
  if (++sync_calls == 1) { errno = ENOSPC; return -1; }
  return fsync(fd);
}
int dsh_guest_initialize(const struct dsh_guest_options *options) {
  char directory[PATH_MAX];
  assert(realpath(options->root, directory));
  char *slash = strrchr(directory, '/');
  assert(slash && slash != directory); *slash = '\0';
  struct dsh_crash_guard guard = DSH_CRASH_GUARD_INIT;
  sync_calls = 0;
  int error = dsh_crash_begin(&guard, directory, 1, 1);
  assert(error == EOWNERDEAD);
  int suspended = 0;
  assert(!dsh_crash_check(directory, NULL, &suspended) && suspended);
  // The user resumes here, before coordinate() can build and dispatch exit.
  assert(!dsh_crash_resume(directory, &guard));
  assert(!dsh_crash_check(directory, NULL, &suspended) && !suspended);
  (void)dsh_crash_settle; // No entry happened; this fixture has nothing to settle.
  return error;
}
int dsh_guest_start_with_clock(const struct dsh_guest_request *request,
    dsh_guest_output output, void *context, uint64_t *id,
    double (*clock)(void *), void *clock_context) {
  (void)request; (void)output; (void)context; (void)id;
  (void)clock; (void)clock_context; abort();
}
int dsh_guest_start_with_permissions(const struct dsh_guest_request *request,
    dsh_guest_output output, void *context, uint64_t *id, int root_writable,
    double (*clock)(void *), void *clock_context) {
  (void)root_writable;
  return dsh_guest_start_with_clock(request, output, context, id, clock, clock_context);
}
enum dsh_guest_state dsh_guest_status(void) { return DSH_GUEST_COLD; }
int dsh_guest_ack(uint64_t id, int stream, uint64_t end) {
  (void)id; (void)stream; (void)end; abort();
}
int dsh_guest_stdin_write(uint64_t id, const void *data, size_t size, size_t *written) {
  (void)id; (void)data; (void)size; (void)written; abort();
}
int dsh_guest_stdin_close(uint64_t id) { (void)id; abort(); }
int dsh_guest_abandon(uint64_t id) { (void)id; abort(); }
int dsh_guest_cancel(uint64_t id) { (void)id; abort(); }
int dsh_guest_kill(uint64_t id) { (void)id; abort(); }
int dsh_guest_wait(uint64_t id, unsigned timeout, struct dsh_guest_result *result) {
  (void)id; (void)timeout; (void)result; abort();
}
