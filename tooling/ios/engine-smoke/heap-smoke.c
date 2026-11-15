// Standalone Simulator near-heap-limit probe. Uses the prepared product framework.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int (*StartFn)(int, char**);

static void* deadline(void* ignored) {
  (void)ignored;
  sleep(120);
  fprintf(stderr, "HEAP_SMOKE_DEADLINE\n");
  _exit(124);
}

static int probe(int argc, char** argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: heap-smoke <host library> <unified preload> <main script>\n");
    return 64;
  }
  // The product runner requires the real adjacent worker-preload.cjs resource.
  // The JS driver supplies this same native-directory contract as the app host.
  const char* native = getenv("DSH_GO_OHOS_NATIVE_LIBRARY_DIR");
  if (native == NULL || native[0] != '/') {
    fprintf(stderr, "HEAP_SMOKE_NATIVE_DIRECTORY_REQUIRED\n");
    return 64;
  }
  unsetenv("NODE_OPTIONS");
  unsetenv("DSH_IOS_SMOKE_PATCH");
  unsetenv("DSH_IOS_SMOKE_IMPORT");
  pthread_t watchdog;
  if (pthread_create(&watchdog, NULL, deadline, NULL) != 0) return 70;
  pthread_detach(watchdog);
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
  if (library == NULL) {
    fprintf(stderr, "HEAP_SMOKE_DLOPEN_FAILED: %s\n", dlerror());
    return 70;
  }
  StartFn start = (StartFn)dlsym(library, "dsh_node_start");
  if (start == NULL) {
    fprintf(stderr, "HEAP_SMOKE_START_MISSING\n");
    return 70;
  }
  int passed = 1;
  for (int round = 1; round <= 2; ++round) {
    if (setenv("DSH_IOS_HEAP_SMOKE_ROUND", round == 1 ? "1" : "2", 1) != 0) return 70;
    char* arguments[] = {"heap-probe", "--jitless", "--import", argv[2], argv[3], NULL};
    const int code = start(5, arguments);
    const int expected = round == 1 ? 70 : 0;
    const int good = code == expected;
    printf("{\"kind\":\"native-result\",\"round\":%d,\"pid\":%ld,\"engineCode\":%d,\"expectedCode\":%d,\"pass\":%s}\n",
           round, (long)getpid(), code, expected, good ? "true" : "false");
    fflush(stdout);
    passed = passed && good;
  }
  return passed ? 0 : 1;
}

#ifdef DSH_HEAP_SMOKE_LINUX_PRELOAD
// Reference only: official Linux Node exports the embedding API before its main.
// This builds the same probe, not a replacement Node or NodeMobile binary.
typedef int (*MainFn)(int, char**, char**);
typedef int (*LibcStartFn)(MainFn, int, char**, void (*)(void), void (*)(void), void (*)(void), void*);
static int linux_main(int argc, char** argv, char** env) {
  (void)env;
  int result = probe(argc, argv);
  fflush(NULL);
  _exit(result);
}
__attribute__((visibility("default")))
int __libc_start_main(MainFn ignored, int argc, char** argv, void (*init)(void), void (*fini)(void), void (*rtld)(void), void* stack) {
  (void)ignored;
  LibcStartFn original = (LibcStartFn)dlsym(RTLD_NEXT, "__libc_start_main");
  if (original == NULL) abort();
  return original(linux_main, argc, argv, init, fini, rtld, stack);
}
#else
int main(int argc, char** argv) {
  int result = probe(argc, argv);
  fflush(NULL);
  // Node's process-global platform intentionally outlives both Environments.
  // Report their real return codes before ending this standalone observer.
  _exit(result);
}
#endif
