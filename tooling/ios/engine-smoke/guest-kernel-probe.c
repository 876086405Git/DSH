// Standalone Simulator harness for the production kernel, no Node/model. Use
// only a disposable copy of a rootfs published by GuestRootfsInstaller.
// guest-kernel-probe <fakefs root> <workspace> <temporary> <shell script>
#include "guest_backend.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint64_t job;
static void *deadline(void *unused) {
  (void)unused;
  sleep(120);
  dsh_guest_cancel(job);
  return NULL;
}
static int output(void *context, int stream, uint64_t end,
                  const void *bytes, size_t length) {
  (void)context;
  FILE *target = stream == 1 ? stdout : stderr;
  if (fwrite(bytes, 1, length, target) != length) return 5;
  fflush(target);
  return dsh_guest_ack(job, stream, end);
}

int main(int argc, char **argv) {
  if (argc != 5) return 64;
  const char *blocked[] = {argv[1]};
  struct dsh_guest_options options = {argv[1], blocked, 1};
  int error = dsh_guest_initialize(&options);
  if (error) { fprintf(stderr, "initialize: %s\n", strerror(error)); return 1; }
  const char *args[] = {"/bin/sh", "-c", argv[4]};
  const char *env[] = {"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/root", "LANG=C.UTF-8"};
  struct dsh_guest_request request = {
      .argv = args, .argc = 3, .env = env, .envc = 3,
      .cwd = "/workspace", .workspace = argv[2], .temporary = argv[3],
  };
  // Explicit trusted fixture grant, never changes the app approval path.
  error = dsh_guest_start_with_permissions(&request, output, NULL, &job, 1, NULL, NULL);
  if (error) { fprintf(stderr, "start: %s\n", strerror(error)); return 1; }
  pthread_t watchdog;
  if (pthread_create(&watchdog, NULL, deadline, NULL)) return 1;
  pthread_detach(watchdog);
  dsh_guest_stdin_close(job);
  struct dsh_guest_result result;
  error = dsh_guest_wait(job, 2000, &result);
  if (error) { fprintf(stderr, "wait: %s\n", strerror(error)); return 1; }
  fprintf(stderr, "probe exit=%d settled=%d abandoned=%d\n", result.exit_code,
          result.resources_settled, result.abandoned);
  return result.resources_settled && !result.abandoned ? result.exit_code : 1;
}
