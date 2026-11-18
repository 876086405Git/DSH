// Linux/glibc observation harness only: real Node symbols come from the pinned
// official executable. This shim and its environment controls never enter HAP.
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

extern "C" int dsh_node_start(int argc, char** argv);
extern "C" int dsh_node_stop() __attribute__((weak));

namespace {
using Main = int (*)(int, char**, char**);
using Start = int (*)(Main, int, char**, void (*)(), void (*)(), void (*)(), void*);
void HostSignal(int) {}

int Observe(int argc, char** argv, char**) {
  struct sigaction action{};
  action.sa_handler = HostSignal;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, nullptr);
  int code = -1;
  const auto host_thread = std::this_thread::get_id();
  std::thread engine([&] {
    if (std::this_thread::get_id() == host_thread) std::abort();
    code = dsh_node_start(argc, argv);
    std::fprintf(stderr, "P1_RUNNER_RETURNED=%d\n", code);
  });
  if (std::getenv("P1_TEST_EARLY_STOP")) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    int accepted = 0;
    while (!accepted && std::chrono::steady_clock::now() < deadline) {
      accepted = dsh_node_stop ? dsh_node_stop() : 0;
      std::this_thread::yield();
    }
    if (!accepted) std::_Exit(91);
    std::fprintf(stderr, "P1_STOP_REQUEST=%d\n", accepted);
  }
  if (const char* ready = std::getenv("P1_TEST_STOP_MARKER")) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (access(ready, F_OK) != 0 && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (access(ready, F_OK) != 0 || !dsh_node_stop) std::_Exit(90);
    std::fprintf(stderr, "P1_STOP_REQUEST=%d\n", dsh_node_stop());
  }
  engine.join();
  struct sigaction observed{};
  sigaction(SIGTERM, nullptr, &observed);
  std::fprintf(stderr, "P1_SIGNAL_PRESERVED=%d\n", observed.sa_handler == HostSignal);
  if (std::getenv("P1_TEST_REPEAT")) {
    std::fprintf(stderr, "P1_REPEAT=%d\n", dsh_node_start(argc, argv));
    std::fprintf(stderr, "P1_STOP_AFTER=%d\n", dsh_node_stop());
  }
  std::fputs("P1_HOST_ALIVE_AFTER\n", stderr);
  return 0;
}
}  // namespace

extern "C" __attribute__((visibility("default")))
int __libc_start_main(Main, int argc, char** argv, void (*init)(),
                      void (*fini)(), void (*rtld_fini)(), void* stack_end) {
  auto start = reinterpret_cast<Start>(dlsym(RTLD_NEXT, "__libc_start_main"));
  if (!start) std::abort();
  return start(Observe, argc, argv, init, fini, rtld_fini, stack_end);
}
