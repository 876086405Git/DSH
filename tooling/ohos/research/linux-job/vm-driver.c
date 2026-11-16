#define _GNU_SOURCE
#include <stdatomic.h>
#include <dlfcn.h>
#include <stddef.h>
#include "temu_embed.h"
static atomic_int stop_flag;
static int stopping(void *opaque) { (void)opaque; return atomic_load(&stop_flag); }
int dsh_test_run(const char *library, const char *config, int input, int output) {
  void *lib = dlopen(library, RTLD_NOW | RTLD_LOCAL);
  if (!lib) return -100;
  int (*run)(const char *, int, int, TemuInitialized, TemuShouldStop, void *) = dlsym(lib, "temu_embed_run_controlled");
  if (!run) return -101;
  return run(config, input, output, NULL, stopping, NULL);
}
void dsh_test_stop(void) { atomic_store(&stop_flag, 1); }
