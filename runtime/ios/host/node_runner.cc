// The Node embedded in the iOS app. V8 and Node's per-process state last as long as
// the process; every engine run gets its own Environment, so stopping the engine
// doesn't need the relaunch iOS can't do on its own.
#include <node.h>
#include <pthread.h>
#include <signal.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "publication_binding.h"
#include "image_binding.h"
#include "phone_binding.h"
#include "activity_clock_binding.h"
#include "guest_config_binding.h"

namespace {
// Secondary threads get 512 KiB by default here, less than V8's stack limit assumes.
constexpr size_t kEngineStackBytes = 16 * 1024 * 1024;

// runtime/ohos gates everything on process.platform and on WebAssembly being absent:
// it is the same in-process, no-child-process runtime, and this is what selects it.
// Workers inherit it with the rest of execArgv.
//
// A synchronous --require bootstrap disables fd tracking for every public Worker,
// including eval Workers and Workers with an explicit execArgv array. It is shipped
// beside DshNodeHost; the platform --import alone does not run in classic eval Workers.
// NodeMobile 24.22.1-0's inconsistent fd-set hash makes tracking unsafe. Raw fds left
// open intentionally remain open until App exit instead of being closed on Stop.
constexpr const char* kPlatformImport =
    "--import=data:text/javascript;base64,"
    "aW1wb3J0e3N5bmNCdWlsdGluRVNNRXhwb3J0cyBhcyBzfWZyb20nbm9kZTptb2R1bGUnO09iamVjdC5kZWZpbmVQcm9wZXJ0eShwcm9jZXNz"
    "LCdwbGF0Zm9ybScse3ZhbHVlOidvcGVuaGFybW9ueSd9KTtSZWZsZWN0LmRlbGV0ZVByb3BlcnR5KGdsb2JhbFRoaXMsJ1dlYkFzc2VtYmx5"
    "Jyk7cygpOw==";

std::mutex environment_mutex;
node::Environment* active_environment = nullptr;
bool active = false;
bool stop_requested = false;

std::shared_ptr<node::InitializationResult> initialization;
std::unique_ptr<node::MultiIsolatePlatform> platform;

// Node raises this only when it owns the process, and kNoAdjustResourceLimits says it
// doesn't. An iOS app starts at 256, shared with everything else in the app.
void RaiseFileLimit() {
  rlimit limit{};
  if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return;
  // Darwin refuses more than OPEN_MAX, even with the hard limit at infinity.
  const rlim_t wanted = std::min<rlim_t>(limit.rlim_max, 10240);
  if (limit.rlim_cur >= wanted) return;
  limit.rlim_cur = wanted;
  setrlimit(RLIMIT_NOFILE, &limit);
}

int RejectStartup(const char* code) {
  // Never echo paths, DSH arguments or environment values.
  std::fprintf(stderr, "%s: invalid embedded Node startup contract\n", code);
  return 64;
}

bool IsUnifiedPreload(const char* value) {
  constexpr const char* suffix = "/runtime/ohos/preload.mjs";
  if (value == nullptr || value[0] != '/') return false;
  const size_t length = std::strlen(value);
  const size_t suffix_length = std::strlen(suffix);
  return length >= suffix_length && std::strcmp(value + length - suffix_length, suffix) == 0;
}

struct HeapLimitState {
  node::Environment* environment;
  bool reached = false;
};

size_t StopAtHeapLimit(void* data, size_t current, size_t) {
  auto* state = static_cast<HeapLimitState*>(data);
  if (state->reached) return current;
  state->reached = true;
  node::Stop(state->environment);
  // Match Node's Worker::NearHeapLimit allowance for completing the current GC.
  return current + 16 * 1024 * 1024;
}

// The callback is copied by Node into child Workers. Capture the immutable path
// by value, never Run or Environment state. The default run has no callback.
node::EmbedderPreloadCallback GuestPreload(const std::string& selector) {
  if (selector.empty()) return nullptr;
  return [selector](node::Environment*, v8::Local<v8::Value>, v8::Local<v8::Value> require) {
    auto* isolate = v8::Isolate::GetCurrent();
    auto context = isolate->GetCurrentContext();
    auto text = [&](const std::string& value) {
      return v8::String::NewFromUtf8(isolate, value.c_str()).ToLocalChecked();
    };
    v8::Local<v8::Value> module_id = text("module");
    v8::Local<v8::Value> module, create, disk_require, ignored;
    if (!require.As<v8::Function>()->Call(context, v8::Undefined(isolate), 1, &module_id).ToLocal(&module)) return;
    if (!module.As<v8::Object>()->Get(context, text("createRequire")).ToLocal(&create)) return;
    v8::Local<v8::Value> filename = text(selector);
    if (!create.As<v8::Function>()->Call(context, module, 1, &filename).ToLocal(&disk_require)) return;
    // Leave any exception pending: startup must fail, never silently use the
    // default routing after an installed preload failed.
    if (!disk_require.As<v8::Function>()->Call(context, v8::Undefined(isolate), 1, &filename).ToLocal(&ignored)) return;
  };
}

int RunEnvironment(const std::vector<std::string>& args, const std::vector<std::string>& exec_args, const std::string& guest_selector) {
  std::vector<std::string> errors;
  const auto flags = static_cast<node::EnvironmentFlags::Flags>(
      node::EnvironmentFlags::kNoGlobalSearchPaths |
      node::EnvironmentFlags::kNoCreateInspector |
      node::EnvironmentFlags::kNoStartDebugSignalHandler);
  auto setup = node::CommonEnvironmentSetup::Create(platform.get(), &errors, args, exec_args, flags);
  if (!setup) {
    for (const auto& error : errors) std::fprintf(stderr, "%s\n", error.c_str());
    return RejectStartup("ERR_IOS_HOST_ENVIRONMENT");
  }
  auto* isolate = setup->isolate();
  auto* env = setup->env();
  int explicit_exit = 0;
  bool has_explicit_exit = false;
  int result = 1;
  HeapLimitState heap_limit{env};
  {
    v8::Locker locker(isolate);
    v8::Isolate::Scope isolate_scope(isolate);
    v8::HandleScope handle_scope(isolate);
    v8::Context::Scope context_scope(setup->context());
    // HostCore sets TZ outside process.env; refresh the caches for this run.
    tzset();
    isolate->DateTimeConfigurationChangeNotification(v8::Isolate::TimeZoneDetection::kRedetect);
    isolate->AddNearHeapLimitCallback(StopAtHeapLimit, &heap_limit);
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
    if (!node::LoadEnvironment(env, node::StartExecutionCallback{}, GuestPreload(guest_selector)).IsEmpty()) {
      result = node::SpinEventLoop(env).FromMaybe(1);
    }
    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      active_environment = nullptr;
      if (stop_requested && !has_explicit_exit) result = 0;
    }
    isolate->RemoveNearHeapLimitCallback(StopAtHeapLimit, 0);
    node::Stop(env);
  }
  if (heap_limit.reached) {
    std::fprintf(stderr, "ERR_IOS_HOST_HEAP_LIMIT: engine stopped at heap limit\n");
    return 70;
  }
  return has_explicit_exit ? explicit_exit : result;
}

struct Run {
  dsh_ios::RunActivityClock activity;
  std::mutex finished_mutex;
  std::condition_variable finished_changed;
  bool finished = false;
  std::vector<std::string> arguments;
  std::string guest_selector;
  int result = 1;
};

void* RunOnEngineThread(void* raw) {
  auto* run = static_cast<Run*>(raw);
  struct Finished {
    Run* run;
    ~Finished() {
      { std::lock_guard<std::mutex> lock(run->finished_mutex); run->finished = true; }
      run->finished_changed.notify_one();
    }
  } finished{run};
  if (!initialization) {
    dsh_ios::RegisterActivityClockBinding();
    dsh_ios::guest_config::Register();
    RegisterPhoneBinding();
    RegisterImageBinding();
    // Process options stay fixed, including the original default --import.
    // Installed selection happens in the per-Environment preload callback.
    RegisterPublicationBinding();
    initialization = node::InitializeOncePerProcess(run->arguments, {
        node::ProcessInitializationFlags::kNoStdioInitialization,
        node::ProcessInitializationFlags::kNoDefaultSignalHandling,
        node::ProcessInitializationFlags::kNoInitializeV8,
        node::ProcessInitializationFlags::kNoInitializeNodeV8Platform,
        node::ProcessInitializationFlags::kDisableNodeOptionsEnv,
        node::ProcessInitializationFlags::kNoParseGlobalDebugVariables,
        node::ProcessInitializationFlags::kNoAdjustResourceLimits,
        node::ProcessInitializationFlags::kNoUseLargePages,
    });
    for (const auto& error : initialization->errors()) std::fprintf(stderr, "%s\n", error.c_str());
    if (initialization->early_return()) {
      run->result = initialization->exit_code();
      return nullptr;
    }
    platform = node::MultiIsolatePlatform::Create(4);
    v8::V8::InitializePlatform(platform.get());
    v8::V8::Initialize();
  } else if (initialization->early_return()) {
    run->result = initialization->exit_code();
    return nullptr;
  }
  // Application arguments (including this run's patches) are not process options.
  std::vector<std::string> args{run->arguments.front()};
  args.insert(args.end(), run->arguments.begin() + 9, run->arguments.end());
  run->result = RunEnvironment(args, initialization->exec_args(), run->guest_selector);
  return nullptr;
}
}  // namespace

extern "C" __attribute__((visibility("default"))) int dsh_node_start(int argc, char** argv) {
  const char* node_options = std::getenv("NODE_OPTIONS");
  if (node_options != nullptr && node_options[0] != '\0') return RejectStartup("ERR_IOS_HOST_NODE_OPTIONS");
  if (argc < 5 || argv == nullptr || argv[0] == nullptr || argv[1] == nullptr || argv[2] == nullptr ||
      std::strcmp(argv[1], "--jitless") != 0 || std::strcmp(argv[2], "--import") != 0 ||
      !IsUnifiedPreload(argv[3]) || argv[4] == nullptr || argv[4][0] != '/') {
    return RejectStartup("ERR_IOS_HOST_ARGV");
  }
  // The shared host sets this from NativeEngine's framework directory before
  // entering Node. Direct runner probes must stage the same required resource.
  const char* native_dir = std::getenv("DSH_GO_OHOS_NATIVE_LIBRARY_DIR");
  if (native_dir == nullptr || native_dir[0] != '/') return RejectStartup("ERR_IOS_HOST_WORKER_PRELOAD");
  const std::string worker_preload = std::string(native_dir) + "/DshNodeHost.framework/worker-preload.cjs";
  if (access(worker_preload.c_str(), R_OK) != 0) return RejectStartup("ERR_IOS_HOST_WORKER_PRELOAD");
  {
    std::lock_guard<std::mutex> lock(environment_mutex);
    if (active) return RejectStartup("ERR_IOS_HOST_ALREADY_STARTED");
    active = true;
    stop_requested = false;
  }
  // A dying write to a closed socket would otherwise take the whole app: Node's own
  // signal setup is off, since the process isn't Node's.
  signal(SIGPIPE, SIG_IGN);
  RaiseFileLimit();

  Run run;
  if (dsh_ios::guest_config::Enabled()) {
    const std::string root = std::string(argv[3]).substr(0, std::strlen(argv[3]) - std::strlen("runtime/ohos/preload.mjs"));
    run.guest_selector = root + "runtime/ios/guest/preload-selector.cjs";
    if (access(run.guest_selector.c_str(), R_OK) != 0 ||
        access((root + "runtime/ohos/preload-guest.mjs").c_str(), R_OK) != 0) {
      std::lock_guard<std::mutex> lock(environment_mutex); active = false;
      return RejectStartup("ERR_IOS_GUEST_PRELOAD");
    }
  }
  // Node's defaults assume a server's memory: left alone, the heap grows until iOS ends
  // the app. These held a five-tool round with a large JSON worker; not yet set on a device.
  run.arguments = {argv[0], argv[1], "--max-old-space-size=256", "--max-semi-space-size=4", "--require", worker_preload, kPlatformImport, argv[2], argv[3]};
  run.arguments.insert(run.arguments.end(), argv + 4, argv + argc);
  // The shared host fixes its own profile. What iOS adds (the phone tools) sits next to
  // it, written by the app for this run, and the CLI only takes --patch here.
  const auto host_patch = std::find(run.arguments.begin(), run.arguments.end(), "--patch");
  if (host_patch != run.arguments.end() && host_patch + 1 != run.arguments.end()) {
    const std::string profile = *(host_patch + 1);
    const std::string ios_patch = profile.substr(0, profile.rfind('/') + 1) + "ios-host.patch.json";
    if (access(ios_patch.c_str(), R_OK) == 0) run.arguments.insert(host_patch + 2, {"--patch", ios_patch});
  }
#ifdef DSH_IOS_ENGINE_SMOKE
  // Test builds only: the smoke test's fake model has to reach the fixed command line,
  // next to the host's own --patch because the CLI takes it nowhere later.
  if (const char* patch = std::getenv("DSH_IOS_SMOKE_PATCH")) {
    const auto own = std::find(run.arguments.begin(), run.arguments.end(), "--patch");
    run.arguments.insert(own + 2, {"--patch", patch});
  }
#endif

  pthread_attr_t attributes;
  pthread_t thread;
  pthread_attr_init(&attributes);
  pthread_attr_setstacksize(&attributes, kEngineStackBytes);
  const int created = pthread_create(&thread, &attributes, RunOnEngineThread, &run);
  pthread_attr_destroy(&attributes);
  if (created == 0) {
    // This existing native parent thread remains independent of Node's JS loop.
    // It used to wait only in pthread_join; no extra heartbeat thread is added.
    std::unique_lock<std::mutex> lock(run.finished_mutex);
    run.activity.clock->Tick();
    while (!run.finished_changed.wait_for(lock, dsh_ios::ActivityClock::kPeriod, [&] { return run.finished; })) {
      run.activity.clock->Tick();
    }
    lock.unlock();
    pthread_join(thread, nullptr);
  }
  else run.result = RejectStartup("ERR_IOS_HOST_THREAD");
  {
    std::lock_guard<std::mutex> lock(environment_mutex);
    active = false;
  }
  return run.result;
}

// node::Stop is the public embedder cancellation API, not a process signal. The lock
// keeps the Environment from being destroyed during this call.
extern "C" __attribute__((visibility("default"))) int dsh_node_stop() {
  std::lock_guard<std::mutex> lock(environment_mutex);
  if (!active) return 0;
  stop_requested = true;
  if (active_environment) node::Stop(active_environment);
  return 1;
}
