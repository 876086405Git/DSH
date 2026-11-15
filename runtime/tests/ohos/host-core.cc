// Desktop host-core harness. Fake runner only: not an OHOS or DSH engine result.
#include "host_core.h"
#include <unistd.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace {
std::atomic<bool> entered{false}, active{false}, stopped{false};
std::atomic<int> stop_calls{0};
std::string scenario;
std::thread::id main_thread;
dsh::HostOptions options;

void Write(int fd, const std::string& text) {
  size_t offset = 0;
  while (offset < text.size()) {
    auto count = write(fd, text.data() + offset, text.size() - offset);
    assert(count > 0); offset += static_cast<size_t>(count);
  }
}

int Stop() { ++stop_calls; if (!active) return 0; stopped = true; return 1; }
int Run(int argc, char** argv) {
  assert(std::this_thread::get_id() != main_thread);
  assert(argc == 13 && argv[13] == nullptr);
  assert(std::string(argv[1]) == "--jitless" && std::string(argv[2]) == "--import");
  assert(std::string(argv[5]) == "web" && std::string(argv[6]) == "--patch");
  assert(std::string(argv[8]) == "--host" && std::string(argv[9]) == "127.0.0.1");
  assert(std::string(argv[10]) == "--port" && std::string(argv[11]) == "0" && std::string(argv[12]) == "--no-open");
  assert(std::string(std::getenv("DSH_HOME")) == options.dsh_home);
  assert(std::string(std::getenv("HOME")) == options.guest_root + "/root");
  assert(std::string(std::getenv("DSH_AGENTS_HOME")) == options.guest_root + "/root/.agents");
  assert(std::string(std::getenv("NODE_COMPILE_CACHE")) == options.cache_dir + "/node-compile-cache");
  assert(std::string(std::getenv("DSH_GO_OHOS_NATIVE_LIBRARY_DIR")) == options.native_library_dir);
  entered = true;
  if (scenario == "stop-race") while (!stop_calls) std::this_thread::yield();
  active = true;
  Write(1, "\x1b[32mdsh web: http://127.0.0.1:3080/?tok");
  Write(1, "en=fixture_LAUNCH\x1b[0m\n");
  Write(2, "DEEPSEEK_API_KEY=fixture_SECRET\n");
  if (scenario == "multiline-secret") Write(2, "password=fixture_FIRST\r\nfixture_SECOND\n");
  Write(1, "http://127.0.0.1:3080/?token=another_SECRET\n");
  if (scenario == "large") {
    Write(1, "fixture_SECRET" + std::string(40000, 'x') + "\n");
    for (int i = 0; i != 800; ++i) Write(1, "line " + std::to_string(i) + "\n");
  }
  if (scenario == "stop-race" || scenario == "stop-running") {
    while (!stopped) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  Write(1, "中文尾部"); Write(2, "stderr tail");
  active = false;
  return scenario.compare(0, 4, "stop") == 0 ? 0 : 7;
}
}  // namespace

int main(int argc, char** argv) {
  assert(argc == 3);
  scenario = argv[1]; main_thread = std::this_thread::get_id();
  const std::filesystem::path base = argv[2];
  options.runtime_root = (base / "runtime").string();
  options.guest_root = (base / "中文 guest\"root/runtime/rootfs").string();
  options.dsh_home = options.guest_root + "/root/.dsh"; options.cache_dir = (base / "cache").string();
  options.native_library_dir = (base / "libs").string();
  options.workspace_roots = {options.guest_root + "/root/workspace"};
  options.env = {{"DEEPSEEK_API_KEY", "fixture_SECRET"}};
  if (scenario == "multiline-secret") options.env["TEST_PASSWORD"] = "fixture_FIRST\r\nfixture_SECOND";
  for (const auto& path : {options.runtime_root, options.dsh_home, options.cache_dir,
                           options.native_library_dir, options.workspace_roots[0], options.guest_root + "/root/.agents"}) {
    std::filesystem::create_directories(path);
  }
#if defined(DSH_IOS_HOST)
  const std::filesystem::path libraries[] = {"DshFlock.framework/DshFlock", "DshRequireBuiltin.framework/DshRequireBuiltin"};
#else
  const std::filesystem::path libraries[] = {"libdsh_flock.so", "libdsh_require_builtin.so"};
#endif
  for (const auto& name : libraries) {
    const auto file = std::filesystem::path(options.native_library_dir) / name;
    std::filesystem::create_directories(file.parent_path());
    std::ofstream(file) << "path fixture, not a native library\n";
  }
  const auto flock = base / "libs" / libraries[0];
  for (const char* name : {"runtime/ohos/preload.mjs", "node_modules/@deepseek-ai/dsh/lib/bin.js",
                         "runtime/ohos/process/index.mjs", "runtime/ohos/process/sandbox.mjs",
                         "runtime/ohos/lifecycle/index.mjs", "runtime/ohos/capabilities/index.mjs",
                         "runtime/bridge/dsh-go-bridge/lib/index.js", "runtime/ohos/process/child-process.mjs"}) {
    auto path = std::filesystem::path(options.runtime_root) / name;
    std::filesystem::create_directories(path.parent_path()); std::ofstream(path) << "// fixture only\n";
  }
  const std::string previous_home = std::getenv("DSH_HOME") ? std::getenv("DSH_HOME") : "";
  setenv("HOME", "/inherited-user-home", 1);
  setenv("DSH_AGENTS_HOME", "/inherited-agents-home", 1);
  setenv("DSH_GO_OHOS_NATIVE_LIBRARY_DIR", "/inherited-value-must-be-restored", 1);
  if (scenario == "native-relative") options.native_library_dir = "libs";
  if (scenario == "native-root") options.native_library_dir = "/";
  if (scenario == "native-missing-dir") options.native_library_dir += "/missing";
  if (scenario == "native-nul") options.native_library_dir += std::string("\0tail", 5);
  if (scenario == "native-missing-file") std::filesystem::remove(flock);
  if (scenario == "native-not-regular") {
    std::filesystem::remove(flock);
    std::filesystem::create_directory(flock);
  }
  if (scenario == "native-file-symlink") {
    std::filesystem::remove(flock);
    std::ofstream(base / "outside.so") << "outside fixture";
    std::filesystem::create_symlink(base / "outside.so", flock);
  }
  if (scenario == "native-env-override") options.env["DSH_GO_OHOS_NATIVE_LIBRARY_DIR"] = "/untrusted";
  if (scenario == "layout-no-guest") options.guest_root.clear();
  if (scenario == "layout-relative-guest") options.guest_root = "runtime/rootfs";
  if (scenario == "layout-root-guest") options.guest_root = "/";
  if (scenario == "layout-missing-guest") options.guest_root += "/missing";
  if (scenario == "layout-wrong-home") {
    options.dsh_home = (base / "other-home").string(); std::filesystem::create_directory(options.dsh_home);
  }
  if (scenario == "layout-wrong-workspace") {
    options.workspace_roots = {(base / "other-workspace").string()}; std::filesystem::create_directory(options.workspace_roots[0]);
  }
  if (scenario == "layout-many-roots") options.workspace_roots.push_back(options.workspace_roots[0]);
  if (scenario == "layout-missing-agents") std::filesystem::remove(options.guest_root + "/root/.agents");
  if (scenario == "layout-agents-link" || scenario == "layout-workspace-link") {
    const auto path = options.guest_root + (scenario == "layout-agents-link" ? "/root/.agents" : "/root/workspace");
    const auto other = (base / "other-directory").string(); std::filesystem::create_directory(other);
    std::filesystem::remove(path); std::filesystem::create_directory_symlink(other, path);
  }
  if (scenario == "layout-env-agents") options.env["DSH_AGENTS_HOME"] = "/untrusted";
  if (scenario == "no-roots") options.workspace_roots.clear();
  if (scenario == "filesystem-root") options.workspace_roots[0] = "/";
  if (scenario == "missing-home") options.dsh_home += "/missing";
  if (scenario == "protected-env") options.env["NODE_OPTIONS"] = "--import /bad";
  if (scenario == "inherited-node-options") setenv("NODE_OPTIONS", " ", 1);
  if (scenario == "runtime-symlink") {
    auto path = std::filesystem::path(options.runtime_root) / "runtime/ohos/preload.mjs";
    std::filesystem::remove(path); std::ofstream(base / "outside.mjs") << "// outside\n";
    std::filesystem::create_symlink(base / "outside.mjs", path);
  }
  std::mutex output_mutex;
  std::string forwarded;
  dsh::Host host([&](const std::string&, const std::string& line) {
    std::lock_guard<std::mutex> lock(output_mutex); forwarded += line + '\n';
  });
  const bool invalid = scenario == "no-roots" || scenario == "filesystem-root" || scenario == "missing-home" ||
      scenario == "protected-env" || scenario == "inherited-node-options" || scenario == "runtime-symlink" ||
      scenario.compare(0, 7, "native-") == 0 || scenario.compare(0, 7, "layout-") == 0;
  try {
    host.Start(options, Run, Stop);
    assert(!invalid);
  } catch (const dsh::HostError& error) {
    assert(invalid && !entered && !host.State().consumed);
    if (scenario.compare(0, 7, "native-") == 0)
      assert(error.code == (scenario == "native-env-override" ? "ERR_OHOS_HOST_ENV" : "ERR_OHOS_NATIVE_LIBRARY_PATH"));
    if (scenario.compare(0, 7, "layout-") == 0)
      assert(error.code == (scenario == "layout-env-agents" ? "ERR_OHOS_HOST_ENV" :
          scenario == "layout-many-roots" ? "ERR_OHOS_HOST_WORKSPACES" : "ERR_OHOS_HOST_LAYOUT"));
    std::cout << "PASS " << scenario << '\n'; return 0;
  }
  if (scenario == "stop-race" || scenario == "stop-running") {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while ((scenario == "stop-race" ? !entered : host.State().phase != "running") &&
           std::chrono::steady_clock::now() < deadline) std::this_thread::yield();
    assert(entered); host.Stop();
  }
  host.Wait();
  const auto state = host.State(); const auto events = host.Drain();
  assert(state.consumed && state.phase == "exited" && state.exit_code == (scenario.compare(0, 4, "stop") == 0 ? 0 : 7));
  assert(state.base_url.empty() && state.token.empty());
  assert(!events.empty() && events.back().kind == "exit");
  assert(events.size() <= 514);
  bool ready = false, tail = false, dropped = false;
  for (const auto& event : events) {
    if (event.kind == "ready") { assert(event.token == "fixture_LAUNCH" && event.base_url == "http://127.0.0.1:3080"); ready = true; }
    if (event.line == "中文尾部") tail = true;
    if (event.line.find("old log lines dropped") != std::string::npos) dropped = true;
    assert(event.line.find("fixture_SECRET") == std::string::npos && event.line.find("fixture_LAUNCH") == std::string::npos);
    assert(event.line.find("another_SECRET") == std::string::npos);
    assert(event.line.find("fixture_FIRST") == std::string::npos && event.line.find("fixture_SECOND") == std::string::npos);
  }
  assert(tail && (ready || scenario == "stop-race"));
  assert(forwarded.find("fixture_SECRET") == std::string::npos && forwarded.find("fixture_LAUNCH") == std::string::npos);
  assert(forwarded.find("another_SECRET") == std::string::npos);
  assert(forwarded.find("fixture_FIRST") == std::string::npos && forwarded.find("fixture_SECOND") == std::string::npos);
  if (scenario == "large") assert(dropped && forwarded.find("oversized log line discarded") != std::string::npos);
  assert((std::getenv("DSH_HOME") ? std::getenv("DSH_HOME") : "") == previous_home);
  assert(std::string(std::getenv("HOME")) == "/inherited-user-home");
  assert(std::string(std::getenv("DSH_AGENTS_HOME")) == "/inherited-agents-home");
  assert(std::string(std::getenv("DSH_GO_OHOS_NATIVE_LIBRARY_DIR")) == "/inherited-value-must-be-restored");
  try { host.Start(options, Run, Stop); assert(false); }
  catch (const dsh::HostError& error) { assert(error.code == "ERR_OHOS_HOST_ALREADY_STARTED"); }
  host.Stop();
  std::cout << "PASS " << scenario << '\n';
}
