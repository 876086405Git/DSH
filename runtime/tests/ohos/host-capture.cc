// Actual Host threads and descriptors; only the embedded Node runner is fake.
// Link-time poll observation measures wakeups without a product test hook.
#include "host_core.h"
#include <poll.h>
#include <unistd.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

namespace {
using Clock = std::chrono::steady_clock;
std::string scenario;
std::atomic<int> in_poll{0}, idle_timeouts{0}, idle_returns{0}, run_calls{0};
std::atomic<int> stop_inactive{0}, stop_active{0};
std::atomic<bool> measuring{false}, entered{false}, release_runner{false};
std::atomic<bool> active{false}, stopped{false}, gated_pipe{false}, release_pipe{false};
std::atomic<int> lines{0};
std::mutex runner_mutex;
std::condition_variable runner_cv;
int held_writers[2]{-1, -1};

template <typename Predicate> void Until(Predicate done) {
  const auto deadline = Clock::now() + std::chrono::seconds(3);
  while (!done()) {
    if (Clock::now() >= deadline) throw std::runtime_error("fixture synchronization deadline");
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

void Write(int fd, const std::string& text) {
  assert(write(fd, text.data(), text.size()) == static_cast<ssize_t>(text.size()));
}

int Stop() {
  if (!active) { ++stop_inactive; return 0; }
  ++stop_active;
  {
    std::lock_guard<std::mutex> lock(runner_mutex);
    stopped = true;
  }
  runner_cv.notify_all();
  return 1;
}

int Run(int, char**) {
  ++run_calls;
  entered = true;
  if (scenario == "stop-race") {
    Until([] { return release_runner.load(); });
    active = true;
    std::unique_lock<std::mutex> lock(runner_mutex);
    if (!runner_cv.wait_for(lock, std::chrono::seconds(2), [] { return stopped.load(); }))
      throw std::runtime_error("stop before active was lost");
  } else {
    active = true;
    Write(1, "dsh web: http://127.0.0.1:3081/?token=capture_fixture\n");
    Write(2, "before-idle\n");
    if (scenario == "idle-dup" || scenario == "throw-dup") {
      held_writers[0] = dup(1); held_writers[1] = dup(2);
      assert(held_writers[0] >= 0 && held_writers[1] >= 0);
    }
    std::unique_lock<std::mutex> lock(runner_mutex);
    if (!runner_cv.wait_for(lock, std::chrono::seconds(3), [] { return release_runner.load(); }))
      throw std::runtime_error("fixture runner release deadline");
  }
  Write(1, "stdout 中文尾部");
  Write(2, "stderr 中文尾部");
  active = false;
  if (scenario == "throw-dup") throw std::runtime_error("explicit fixture runner exception");
  return 37;
}

dsh::HostOptions Options(const std::filesystem::path& base) {
  dsh::HostOptions options;
  options.runtime_root = (base / "runtime").string();
  options.guest_root = (base / "guest").string();
  options.dsh_home = (base / "guest/root/.dsh").string();
  options.cache_dir = (base / "cache").string();
  options.native_library_dir = (base / "libs").string();
  options.linux_directory = (base / "linux-tools").string();
  options.workspace_roots = {(base / "guest/root/workspace").string()};
  for (const auto& path : {options.runtime_root, options.dsh_home, options.cache_dir,
       options.native_library_dir, options.linux_directory, options.workspace_roots[0],
       (base / "guest/root/.agents").string()}) std::filesystem::create_directories(path);
  for (const char* name : {"libdsh_flock.so", "libdsh_require_builtin.so"})
    std::ofstream(base / "libs" / name) << "path fixture, not ELF\n";
  for (const char* relative : {"runtime/ohos/preload.mjs", "node_modules/@deepseek-ai/dsh/lib/bin.js",
       "runtime/ohos/process/index.mjs", "runtime/ohos/process/sandbox.mjs",
       "runtime/ohos/lifecycle/index.mjs", "runtime/ohos/phone/index.mjs",
       "runtime/ohos/capabilities/index.mjs", "runtime/bridge/dsh-go-bridge/lib/index.js",
       "runtime/ohos/process/child-process.mjs"}) {
    const auto path = std::filesystem::path(options.runtime_root) / relative;
    std::filesystem::create_directories(path.parent_path());
    std::ofstream(path) << "// explicit fixture\n";
  }
  return options;
}
}  // namespace

extern "C" int __real_poll(pollfd*, nfds_t, int);
extern "C" int __wrap_poll(pollfd* fds, nfds_t count, int timeout) {
  ++in_poll;
  const int result = __real_poll(fds, count, timeout);
  --in_poll;
  if (measuring) {
    ++idle_returns;
    if (result == 0) ++idle_timeouts;
  }
  return result;
}

extern "C" int __real_pipe(int*);
extern "C" int __wrap_pipe(int* fds) {
  // Stop deterministically before Capture has installed any reader/control fd.
  if (scenario == "stop-before-capture" && !gated_pipe.exchange(true))
    Until([] { return release_pipe.load(); });
  return __real_pipe(fds);
}

int main(int argc, char** argv) {
  assert(argc == 3);
  scenario = argv[1];
  const bool idle = scenario == "idle" || scenario == "idle-dup";
  assert(idle || scenario == "stop-race" || scenario == "stop-before-capture" || scenario == "throw-dup");
  dsh::Host host([](const std::string&, const std::string&) { ++lines; });
  host.Start(Options(std::filesystem::absolute(argv[2])), Run, Stop);
  if (scenario == "stop-before-capture") {
    Until([] { return gated_pipe.load(); });
    host.Stop();
    release_pipe = true;
  } else if (scenario == "stop-race") {
    Until([] { return entered.load(); });
    host.Stop();
    // No output and no new Stop call when the runner later becomes active.
    std::this_thread::sleep_for(std::chrono::milliseconds(140));
    release_runner = true;
  } else {
    Until([] { return lines.load() >= 2 && in_poll.load() == 2; });
    if (idle) {
      measuring = true;
      std::this_thread::sleep_for(std::chrono::milliseconds(500));
      measuring = false;
    }
    {
      std::lock_guard<std::mutex> lock(runner_mutex);
      release_runner = true;
    }
    runner_cv.notify_all();
  }
  const auto closing = Clock::now();
  host.Wait();  // Must finish even while both duplicated writers remain open.
  const auto close_ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - closing).count();
  for (const int fd : held_writers) if (fd >= 0) close(fd);
  const auto state = host.State();
  const auto events = host.Drain();
  assert(!events.empty());
  if (scenario == "throw-dup") {
    assert(state.phase == "error" && events.back().kind == "error");
  } else {
    assert(state.phase == "exited" && events.back().kind == "exit");
    assert(state.exit_code == (scenario == "stop-before-capture" ? 0 : 37));
  }
  if (scenario == "stop-before-capture") {
    assert(run_calls == 0 && stop_inactive >= 1);
  } else {
    bool out_tail = false, err_tail = false;
    for (const auto& event : events) {
      if (event.kind == "log" && event.stream == "stdout" && event.line == "stdout 中文尾部") out_tail = true;
      if (event.kind == "log" && event.stream == "stderr" && event.line == "stderr 中文尾部") err_tail = true;
    }
    assert(out_tail && err_tail);
  }
  if (scenario == "stop-race") assert(stop_inactive >= 1 && stop_active >= 1);
  host.Stop();  // No stale control fd survives Capture, including exception exit.
  const bool pass = !idle || (idle_timeouts == 0 && idle_returns == 0);
  std::cout << "{\"case\":\"" << scenario << "\",\"status\":\"" << (pass ? "PASS" : "FAIL")
      << "\",\"idleWindowMs\":" << (idle ? 500 : 0) << ",\"idlePollTimeouts\":" << idle_timeouts
      << ",\"idlePollReturns\":" << idle_returns << ",\"stopInactive\":" << stop_inactive
      << ",\"stopActive\":" << stop_active << ",\"joinMs\":" << close_ms << "}\n";
  return pass ? 0 : 1;
}
