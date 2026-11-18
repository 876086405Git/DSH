#include <node.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <mutex>
#include <string>
#include <vector>

#include "publication_binding.h"

namespace {
std::atomic<bool> started{false};
std::mutex environment_mutex;
node::Environment* active_environment = nullptr;
bool active = false;
bool stop_requested = false;

int RejectStartup(const char* code) {
  // Never echo NODE_OPTIONS, paths, DSH arguments or other environment values.
  std::fprintf(stderr, "%s: invalid dedicated OHOS Node startup contract\n", code);
  return 64;
}

bool IsUnifiedPreload(const char* value) {
  constexpr const char* suffix = "/runtime/ohos/preload.mjs";
  if (value == nullptr || value[0] != '/') return false;
  const size_t length = std::strlen(value);
  const size_t suffix_length = std::strlen(suffix);
  return length >= suffix_length &&
      std::strcmp(value + length - suffix_length, suffix) == 0;
}

int RunEnvironment(node::MultiIsolatePlatform* platform,
                   const std::vector<std::string>& args,
                   const std::vector<std::string>& exec_args) {
  std::vector<std::string> errors;
  const auto flags = static_cast<node::EnvironmentFlags::Flags>(
      node::EnvironmentFlags::kTrackUnmanagedFds |
      node::EnvironmentFlags::kNoGlobalSearchPaths |
      node::EnvironmentFlags::kNoCreateInspector |
      node::EnvironmentFlags::kNoStartDebugSignalHandler);
  auto setup = node::CommonEnvironmentSetup::Create(platform, &errors, args, exec_args, flags);
  if (!setup) return RejectStartup("ERR_OHOS_HOST_ENVIRONMENT");
  auto* isolate = setup->isolate();
  auto* env = setup->env();
  int explicit_exit = 0;
  bool has_explicit_exit = false;
  int result = 1;
  {
    v8::Locker locker(isolate);
    v8::Isolate::Scope isolate_scope(isolate);
    v8::HandleScope handle_scope(isolate);
    v8::Context::Scope context_scope(setup->context());
    node::SetProcessExitHandler(env, [&](node::Environment* exiting, int code) {
      explicit_exit = code;
      has_explicit_exit = true;
      node::Stop(exiting);
    });
    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      active_environment = env;
      if (stop_requested) node::Stop(env);
    }
    // An empty callback selects Node's normal CLI entry and its --import chain.
    // Do not replace this with a handwritten require()/import() bootstrap.
    if (!node::LoadEnvironment(env, node::StartExecutionCallback{}).IsEmpty()) {
      result = node::SpinEventLoop(env).FromMaybe(1);
    }
    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      active_environment = nullptr;
      if (stop_requested && !has_explicit_exit) result = 0;
    }
    node::Stop(env);
  }
  return has_explicit_exit ? explicit_exit : result;
}
}  // namespace

// A dedicated OHOS host entry, not a general Node CLI option parser.
// The Ark-side host owns the one-start-per-application guard and keeps this
// library resident. All validation precedes registration and V8 initialization.
extern "C" __attribute__((visibility("default")))
int dsh_node_start(int argc, char** argv) {
  const char* node_options = std::getenv("NODE_OPTIONS");
  if (node_options != nullptr && node_options[0] != '\0') {
    return RejectStartup("ERR_OHOS_HOST_NODE_OPTIONS");
  }
  if (argc < 4 || argv == nullptr || argv[0] == nullptr || argv[1] == nullptr ||
      argv[2] == nullptr || std::strcmp(argv[1], "--jitless") != 0) {
    return RejectStartup("ERR_OHOS_HOST_ARGV");
  }
  const char* preload = nullptr;
  int main_index;
  if (std::strcmp(argv[2], "--import") == 0) {
    if (argc < 5) return RejectStartup("ERR_OHOS_HOST_ARGV");
    preload = argv[3];
    main_index = 4;
  } else if (std::strncmp(argv[2], "--import=", 9) == 0) {
    preload = argv[2] + 9;
    main_index = 3;
  } else {
    return RejectStartup("ERR_OHOS_HOST_ARGV");
  }
  if (!IsUnifiedPreload(preload) || argv[main_index] == nullptr ||
      argv[main_index][0] != '/') {
    return RejectStartup("ERR_OHOS_HOST_ARGV");
  }
  // Arguments after the absolute DSH entry belong to DSH, not to Node.
  if (started.exchange(true)) return RejectStartup("ERR_OHOS_HOST_ALREADY_STARTED");
  {
    std::lock_guard<std::mutex> lock(environment_mutex);
    active = true;
  }
  RegisterPublicationBinding();
  auto initialization = node::InitializeOncePerProcess(
      std::vector<std::string>(argv, argv + argc), {
        node::ProcessInitializationFlags::kNoStdioInitialization,
        node::ProcessInitializationFlags::kNoDefaultSignalHandling,
        node::ProcessInitializationFlags::kNoInitializeV8,
        node::ProcessInitializationFlags::kNoInitializeNodeV8Platform,
        node::ProcessInitializationFlags::kDisableNodeOptionsEnv,
        node::ProcessInitializationFlags::kNoParseGlobalDebugVariables,
        node::ProcessInitializationFlags::kNoAdjustResourceLimits,
        node::ProcessInitializationFlags::kNoUseLargePages,
      });
  int result = initialization->exit_code();
  if (initialization->early_return()) {
    std::lock_guard<std::mutex> lock(environment_mutex);
    active = false;
    return result;
  }
  {
    auto platform = node::MultiIsolatePlatform::Create(4);
    v8::V8::InitializePlatform(platform.get());
    v8::V8::Initialize();
    result = RunEnvironment(platform.get(), initialization->args(), initialization->exec_args());
    v8::V8::Dispose();
    v8::V8::DisposePlatform();
  }
  node::TearDownOncePerProcess();
  {
    std::lock_guard<std::mutex> lock(environment_mutex);
    active = false;
  }
  return result;
}

// node::Stop is the public embedder cancellation API, not a process signal.
// The lock prevents the Environment from being destroyed during this call.
extern "C" __attribute__((visibility("default")))
int dsh_node_stop() {
  std::lock_guard<std::mutex> lock(environment_mutex);
  if (!active) return 0;
  stop_requested = true;
  if (active_environment) node::Stop(active_environment);
  return 1;
}
