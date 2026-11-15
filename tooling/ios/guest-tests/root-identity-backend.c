// Synthetic kernel barrier for the production N-API Owner lifecycle test.
// No guest instructions or filesystem implementation are substituted into iSH.
#define _POSIX_C_SOURCE 200809L
#include "../../../runtime/ios/guest/native/guest_backend.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int dsh_guest_initialize(const struct dsh_guest_options *options) {
  const char *last = strrchr(options->root, '/');
  if (!last) return EINVAL;
  char entered[4096], release[4096];
  int length = (int)(last - options->root);
  if (snprintf(entered, sizeof entered, "%.*s/control/entered", length, options->root) >= (int)sizeof entered ||
      snprintf(release, sizeof release, "%.*s/control/release", length, options->root) >= (int)sizeof release) return ENAMETOOLONG;
  FILE *file = fopen(entered, "w");
  if (!file) return errno;
  fclose(file);
  const struct timespec tick = {0, 1000000};
  for (int i = 0; i < 10000; i++) {
    if (access(release, F_OK) == 0) return ECANCELED;
    nanosleep(&tick, NULL);
  }
  return ETIMEDOUT;
}
enum dsh_guest_state dsh_guest_status(void) { return DSH_GUEST_COLD; }
int dsh_guest_start_with_permissions(const struct dsh_guest_request *r, dsh_guest_output o,
    void *c, uint64_t *j, int w, double (*now)(void *), void *clock) {
  (void)r; (void)o; (void)c; (void)j; (void)w; (void)now; (void)clock;
  return ENOSYS;
}
int dsh_guest_wait(uint64_t id, unsigned ms, struct dsh_guest_result *out) {
  (void)id; (void)ms; (void)out; return ENOSYS;
}
int dsh_guest_stdin_write(uint64_t id, const void *b, size_t n, size_t *w) {
  (void)id; (void)b; (void)n; (void)w; return ENOSYS;
}
int dsh_guest_stdin_close(uint64_t id) { (void)id; return ENOSYS; }
int dsh_guest_ack(uint64_t id, int stream, uint64_t end) { (void)id; (void)stream; (void)end; return ENOSYS; }
int dsh_guest_cancel(uint64_t id) { (void)id; return ENOSYS; }
int dsh_guest_kill(uint64_t id) { (void)id; return ENOSYS; }
int dsh_guest_abandon(uint64_t id) { (void)id; return ENOSYS; }
