// Linux/glibc test fixture only. Never link this interception shim into the HAP.
// The real product node_runner.cpp and publication_binding.cc are compiled in;
// there is no test constructor that registers the binding for the runner.
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#if !defined(__linux__) || !defined(__GLIBC__)
#error Linux glibc fixture only
#endif
extern "C" int dsh_node_start(int argc, char** argv);
using Main = int (*)(int, char**, char**);
using Start = int (*)(Main, int, char**, void (*)(), void (*)(), void (*)(), void*);
int TestMain(int argc, char** argv, char**) {
  std::fputs("M6_TEST_ENTER_DSH_NODE_START\n", stderr);
  return dsh_node_start(argc, argv);
}
extern "C" __attribute__((visibility("default"))) int __libc_start_main(Main, int argc, char** argv, void (*init)(),
                                  void (*fini)(), void (*rtld_fini)(), void* stack_end) {
  auto start = reinterpret_cast<Start>(dlsym(RTLD_NEXT, "__libc_start_main"));
  if (!start) std::abort();
  return start(TestMain, argc, argv, init, fini, rtld_fini, stack_end);
}
