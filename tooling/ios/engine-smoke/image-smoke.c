// Runs one script on the prepared framework, in the Simulator: nothing but the engine and its
// linked bindings, which is what the image check needs.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int (*StartFn)(int, char**);

static void* deadline(void* ignored) {
  (void)ignored;
  sleep(240);
  fprintf(stderr, "IMAGE_SMOKE_DEADLINE\n");
  _exit(124);
}

int main(int argc, char** argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: image-smoke <host library> <unified preload> <main script>\n");
    return 64;
  }
  unsetenv("NODE_OPTIONS");
  pthread_t watchdog;
  if (pthread_create(&watchdog, NULL, deadline, NULL) != 0) return 70;
  pthread_detach(watchdog);
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
  if (library == NULL) {
    fprintf(stderr, "IMAGE_SMOKE_DLOPEN_FAILED: %s\n", dlerror());
    return 70;
  }
  StartFn start = (StartFn)dlsym(library, "dsh_node_start");
  if (start == NULL) {
    fprintf(stderr, "IMAGE_SMOKE_START_MISSING\n");
    return 70;
  }
  char* arguments[] = {"image-probe", "--jitless", "--import", argv[2], argv[3], NULL};
  const int code = start(5, arguments);
  fflush(NULL);
  // Node's process-global platform outlives the Environment; don't wait for it.
  _exit(code);
}
