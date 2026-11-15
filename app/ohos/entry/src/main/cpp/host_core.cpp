#include "host_core.h"

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>

namespace dsh {
namespace {
constexpr size_t kMaximumLine = 16384;
constexpr size_t kMaximumEvents = 512;

void Require(bool value, const char* code, const char* message) {
  if (!value) throw HostError(code, message);
}

std::string Directory(const std::string& path, const char* code = "ERR_OHOS_HOST_PATH") {
  Require(!path.empty() && path[0] == '/' && path.find('\0') == std::string::npos,
          code, "Host paths must be absolute directories");
  std::error_code error;
  auto real = std::filesystem::canonical(path, error);
  Require(!error && real != real.root_path() && std::filesystem::is_directory(real, error),
          code, "Host directories must exist and cannot grant the filesystem root");
  return real.string();
}

std::string NativeDirectory(const std::string& path) {
  const auto root = Directory(path, "ERR_OHOS_NATIVE_LIBRARY_PATH");
#if defined(DSH_IOS_HOST)
  for (const char* name : {"DshFlock.framework/DshFlock", "DshRequireBuiltin.framework/DshRequireBuiltin"}) {
#else
  for (const char* name : {"libdsh_flock.so", "libdsh_require_builtin.so"}) {
#endif
    const auto expected = root + "/" + name;
    std::error_code error;
    const auto real = std::filesystem::canonical(expected, error);
    Require(!error && real == expected && std::filesystem::is_regular_file(real, error),
            "ERR_OHOS_NATIVE_LIBRARY_PATH", "Required HAP native libraries must be regular files in the trusted directory");
  }
  return root;
}

std::string File(const std::string& root, const char* relative) {
  std::error_code error;
  auto path = std::filesystem::canonical(root + "/" + relative, error);
  const std::string prefix = root + "/";
  Require(!error && path.string().compare(0, prefix.size(), prefix) == 0 &&
              std::filesystem::is_regular_file(path, error),
          "ERR_OHOS_HOST_RUNTIME_FILE", "A required runtime file is missing or outside the installed runtime");
  return path.string();
}

std::string Json(const std::string& text) {
  std::string result = "\"";
  const char hex[] = "0123456789abcdef";
  for (unsigned char c : text) {
    if (c == '"' || c == '\\') { result += '\\'; result += c; }
    else if (c < 0x20) { result += "\\u00"; result += hex[c >> 4]; result += hex[c & 15]; }
    else result += c;
  }
  return result + '"';
}

void WriteProfile(const std::string& path, const std::string& contents) {
  std::string temporary = path + ".XXXXXX";
  std::vector<char> name(temporary.begin(), temporary.end());
  name.push_back('\0');
  const int fd = mkstemp(name.data());
  Require(fd >= 0, "ERR_OHOS_HOST_PROFILE", "Cannot create private runtime profile");
  size_t written = 0;
  bool success = true;
  while (written < contents.size()) {
    const auto count = write(fd, contents.data() + written, contents.size() - written);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) { success = false; break; }
    written += static_cast<size_t>(count);
  }
  if (success) success = fsync(fd) == 0;
  if (close(fd) != 0) success = false;
  if (success) success = rename(name.data(), path.c_str()) == 0;
  if (!success) unlink(name.data());
  Require(success, "ERR_OHOS_HOST_PROFILE", "Cannot publish private runtime profile");
}

bool ProtectedEnv(const std::string& key) {
  return key == "DSH_HOME" || key == "DSH_AGENTS_HOME" || key == "HOME" || key == "TMPDIR" ||
      key == "OPENSSL_CONF" || key == "OPENSSL_MODULES" ||
      key.compare(0, 5, "NODE_") == 0 || key.compare(0, 3, "UV_") == 0 ||
      key.compare(0, 3, "LD_") == 0 || key.compare(0, 5, "DYLD_") == 0 ||
      key.compare(0, 7, "DSH_GO_") == 0 || key.compare(0, 5, "NARB_") == 0;
}

class Environment {
 public:
  void Set(const std::string& key, const std::string& value) {
    const char* old = std::getenv(key.c_str());
    previous_.emplace(key, old ? std::optional<std::string>(old) : std::nullopt);
    Require(setenv(key.c_str(), value.c_str(), 1) == 0,
            "ERR_OHOS_HOST_ENV", "Cannot set embedded runtime environment");
  }
  ~Environment() {
    for (const auto& [key, value] : previous_) {
      if (value) setenv(key.c_str(), value->c_str(), 1);
      else unsetenv(key.c_str());
    }
  }
 private:
  std::map<std::string, std::optional<std::string>> previous_;
};

// File descriptors 1/2 are process-wide. Capture is deliberately scoped to the
// single engine lifetime; no raw bytes are forwarded to hilog or Ark.
class Capture {
 public:
  Capture(std::function<void(const std::string&, std::string)> line, std::function<void()> check_stop)
      : line_(std::move(line)), check_stop_(std::move(check_stop)) {
    try {
      for (int i = 0; i != 2; ++i) {
        Require(pipe(pipes_[i]) == 0, "ERR_OHOS_HOST_STDIO", "Cannot open runtime output pipe");
        for (int fd : pipes_[i]) fcntl(fd, F_SETFD, FD_CLOEXEC);
        Require(fcntl(pipes_[i][0], F_SETFL, O_NONBLOCK) == 0,
                "ERR_OHOS_HOST_STDIO", "Cannot configure runtime output pipe");
        saved_[i] = dup(i + 1);
        Require(saved_[i] >= 0, "ERR_OHOS_HOST_STDIO", "Cannot preserve application output");
      }
      std::fflush(stdout);
      std::fflush(stderr);
      for (int i = 0; i != 2; ++i) {
        Require(dup2(pipes_[i][1], i + 1) >= 0, "ERR_OHOS_HOST_STDIO", "Cannot route runtime output");
        close(pipes_[i][1]); pipes_[i][1] = -1;
        readers_[i] = std::thread([this, i] { Read(i); });
      }
    } catch (...) { Close(); throw; }
  }
  ~Capture() { Close(); }
 private:
  void Close() {
    std::fflush(stdout);
    std::fflush(stderr);
    for (int i = 0; i != 2; ++i) {
      if (saved_[i] >= 0) { dup2(saved_[i], i + 1); close(saved_[i]); saved_[i] = -1; }
      if (pipes_[i][1] >= 0) { close(pipes_[i][1]); pipes_[i][1] = -1; }
    }
    ending_ = true;
    for (int i = 0; i != 2; ++i) {
      if (readers_[i].joinable()) readers_[i].join();
      if (pipes_[i][0] >= 0) { close(pipes_[i][0]); pipes_[i][0] = -1; }
    }
  }
  void Read(int index) {
    const std::string stream = index == 0 ? "stdout" : "stderr";
    std::string pending;
    bool overflow = false;
    char bytes[4096];
    for (;;) {
      if (index == 0) check_stop_();
      const auto count = read(pipes_[index][0], bytes, sizeof(bytes));
      if (count > 0) {
        for (ssize_t n = 0; n < count; ++n) {
          if (bytes[n] == '\n') {
            line_(stream, overflow ? "[OHOS host: oversized log line discarded]" : pending);
            pending.clear(); overflow = false;
          } else if (!overflow) {
            if (pending.size() == kMaximumLine) { pending.clear(); overflow = true; }
            else pending += bytes[n];
          }
        }
      } else if (count == 0) break;
      else if (errno == EINTR) continue;
      else if (errno == EAGAIN) {
        if (ending_) break;
        pollfd fd{pipes_[index][0], POLLIN, 0};
        poll(&fd, 1, 50);
      } else break;
    }
    if (overflow || !pending.empty()) {
      line_(stream, overflow ? "[OHOS host: oversized log line discarded]" : pending);
    }
  }
  int pipes_[2][2]{{-1, -1}, {-1, -1}};
  int saved_[2]{-1, -1};
  std::thread readers_[2];
  std::atomic<bool> ending_{false};
  std::function<void(const std::string&, std::string)> line_;
  std::function<void()> check_stop_;
};
}  // namespace

Host::~Host() { Stop(); Wait(); }

void Host::Start(HostOptions options, StartNode start_node, StopNode stop_node) {
  Require(start_node && stop_node, "ERR_OHOS_HOST_RUNNER", "The embedded runner is unavailable");
  const char* node_options = std::getenv("NODE_OPTIONS");
  Require(!node_options || !node_options[0], "ERR_OHOS_HOST_NODE_OPTIONS", "NODE_OPTIONS must be absent or empty");
  options.runtime_root = Directory(options.runtime_root);
  options.guest_root = Directory(options.guest_root, "ERR_OHOS_HOST_LAYOUT");
  options.dsh_home = Directory(options.dsh_home);
  options.cache_dir = Directory(options.cache_dir);
  options.native_library_dir = NativeDirectory(options.native_library_dir);
  Require(options.workspace_roots.size() == 1, "ERR_OHOS_HOST_WORKSPACES", "The single authorized guest workspace is required");
  for (auto& root : options.workspace_roots) root = Directory(root);
  const auto user_home = options.guest_root + "/root";
  const auto expected_home = user_home + "/.dsh";
  const auto expected_agents = user_home + "/.agents";
  const auto expected_workspace = user_home + "/workspace";
  for (const auto& path : {user_home, expected_home, expected_agents, expected_workspace}) {
    Require(Directory(path, "ERR_OHOS_HOST_LAYOUT") == path,
            "ERR_OHOS_HOST_LAYOUT", "Guest layout directories must not be redirected by symlinks");
  }
  Require(options.dsh_home == expected_home && options.workspace_roots[0] == expected_workspace,
          "ERR_OHOS_HOST_LAYOUT", "Home and workspace must match the trusted guest root");
  for (const auto& [key, value] : options.env) {
    Require(!key.empty() && key.find_first_of("=\0", 0, 2) == std::string::npos &&
                value.find('\0') == std::string::npos && !ProtectedEnv(key),
            "ERR_OHOS_HOST_ENV", "Environment cannot override host startup inputs");
  }
  const auto permission = options.env.find("DSH_PERMISSION_MODE");
  Require(permission == options.env.end() || permission->second == "workspace-write" ||
              permission->second == "read-only" || permission->second == "danger-full-access",
          "ERR_OHOS_HOST_ENV", "Invalid permission mode");
  File(options.runtime_root, "runtime/ohos/preload.mjs");
  File(options.runtime_root, "node_modules/@deepseek-ai/dsh/lib/bin.js");
  File(options.runtime_root, "runtime/ohos/process/index.mjs");
  File(options.runtime_root, "runtime/ohos/process/sandbox.mjs");
  File(options.runtime_root, "runtime/ohos/lifecycle/index.mjs");
  File(options.runtime_root, "runtime/ohos/capabilities/index.mjs");
  File(options.runtime_root, "runtime/bridge/dsh-go-bridge/lib/index.js");
  File(options.runtime_root, "runtime/ohos/process/child-process.mjs");
  std::lock_guard<std::mutex> lock(mutex_);
  Require(!state_.consumed, "ERR_OHOS_HOST_ALREADY_STARTED", "Restart the application before starting Node again");
  for (const auto& [key, value] : options.env) {
    std::string upper = key;
    std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) { return std::toupper(c); });
    if (!value.empty() && (upper.find("KEY") != std::string::npos || upper.find("TOKEN") != std::string::npos ||
        upper.find("SECRET") != std::string::npos || upper.find("PASSWORD") != std::string::npos)) {
      // A PEM/password can span lines; capture emits one line at a time.
      size_t start = 0;
      while (start < value.size()) {
        const auto end = value.find_first_of("\r\n", start);
        if (end != start) secrets_.push_back(value.substr(start, end == std::string::npos ? end : end - start));
        if (end == std::string::npos) break;
        start = end + 1;
      }
    }
  }
  state_.phase = "starting";
  state_.consumed = true;
  stop_node_ = stop_node;
  try { engine_ = std::thread([this, options = std::move(options), start_node]() mutable { Run(std::move(options), start_node); }); }
  catch (...) { state_.phase = "idle"; state_.consumed = false; stop_node_ = nullptr; secrets_.clear(); throw; }
}

void Host::Run(HostOptions options, StartNode start_node) {
  try {
    const std::string temporary = options.cache_dir + "/ohos-process";
    const std::string cache = options.cache_dir + "/node-compile-cache";
    std::filesystem::create_directories(temporary);
    std::filesystem::create_directories(cache);
    const auto checked_temporary = Directory(temporary);
    const auto checked_cache = Directory(cache);
    Require(checked_temporary == temporary && checked_cache == cache,
            "ERR_OHOS_HOST_PATH", "Runtime cache directories must not be redirected by symlinks");
    std::string roots;
    for (const auto& root : options.workspace_roots) { if (!roots.empty()) roots += ','; roots += Json(root); }
    const std::string mode = options.env.count("DSH_PERMISSION_MODE") ? options.env.at("DSH_PERMISSION_MODE") : "workspace-write";
    const std::string profile = options.dsh_home + "/ohos-host.patch.json";
    WriteProfile(profile, "[{\"id\":\"subprocess\",\"disabled\":true},{\"id\":\"sandbox\",\"disabled\":true},"
        "{\"id\":\"working-directory\",\"config\":{\"defaultDirectory\":" + Json(options.workspace_roots[0]) + "}},"
        "{\"id\":\"sandbox-policy\",\"config\":{\"mode\":" + Json(mode) + ",\"workspaceRoot\":" + Json(options.workspace_roots[0]) + "}},"
        "{\"insert\":[{\"id\":\"ohos-subprocess\",\"name\":" + Json(File(options.runtime_root, "runtime/ohos/process/index.mjs")) +
        ",\"config\":{\"workspaceRoots\":[" + roots + "],\"temporaryRoot\":" + Json(temporary) + "}},"
        "{\"id\":\"ohos-sandbox\",\"name\":" + Json(File(options.runtime_root, "runtime/ohos/process/sandbox.mjs")) + "},"
        "{\"id\":\"ohos-lifecycle\",\"name\":" + Json(File(options.runtime_root, "runtime/ohos/lifecycle/index.mjs")) + "},"
        "{\"id\":\"ohos-capabilities\",\"name\":" + Json(File(options.runtime_root, "runtime/ohos/capabilities/index.mjs")) + "},"
        "{\"id\":\"dsh-go-bridge\",\"name\":" + Json(File(options.runtime_root, "runtime/bridge/dsh-go-bridge/lib/index.js")) + "}]}]\n");
    int code;
    {
      Environment environment;
      for (const auto& [key, value] : options.env) environment.Set(key, value);
      environment.Set("DSH_HOME", options.dsh_home);
      environment.Set("HOME", options.guest_root + "/root");
      environment.Set("DSH_AGENTS_HOME", options.guest_root + "/root/.agents");
      environment.Set("TMPDIR", temporary);
      environment.Set("NODE_COMPILE_CACHE", cache);
      environment.Set("NARB_DISABLE_NATIVE_CACHE", "1");
      environment.Set("DSH_GO_OHOS_NATIVE_LIBRARY_DIR", options.native_library_dir);
      environment.Set("DSH_PERMISSION_MODE", mode);
      std::vector<std::string> argv{"dsh-node", "--jitless", "--import",
        File(options.runtime_root, "runtime/ohos/preload.mjs"),
        File(options.runtime_root, "node_modules/@deepseek-ai/dsh/lib/bin.js"), "web", "--patch", profile,
        "--host", "127.0.0.1", "--port", "0", "--no-open"};
      std::vector<char*> pointers;
      for (auto& value : argv) pointers.push_back(value.data());
      pointers.push_back(nullptr);
      {
        Capture capture([this](const std::string& stream, std::string line) { Line(stream, std::move(line)); }, [this] {
          // Covers stop between the cancellation check and dsh_node_start's
          // active flag. The existing stdout reader retries without another thread.
          std::lock_guard<std::mutex> lock(mutex_);
          if (stop_requested_) stop_node_();
        });
        // If stop arrived before the runner became active, do not initialize Node.
        bool canceled;
        { std::lock_guard<std::mutex> lock(mutex_); canceled = stop_requested_; }
        code = canceled ? 0 : start_node(static_cast<int>(argv.size()), pointers.data());
      }
    }
    std::lock_guard<std::mutex> lock(mutex_);
    state_.phase = "exited";
    state_.exit_code = code;
    state_.base_url.clear(); state_.token.clear();
    HostEvent event; event.kind = "exit"; event.exit_code = code; Push(std::move(event));
  } catch (const std::exception& error) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto* known = dynamic_cast<const HostError*>(&error);
    state_.phase = "error";
    state_.error_code = known ? known->code : "ERR_OHOS_HOST_START";
    state_.error_message = known ? error.what() : "The embedded runtime could not be started";
    state_.base_url.clear(); state_.token.clear();
    HostEvent event; event.kind = "error"; event.error_code = state_.error_code; event.message = state_.error_message;
    Push(std::move(event));
  }
}

void Host::Stop() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (state_.phase != "starting" && state_.phase != "running" && state_.phase != "stopping") return;
  stop_requested_ = true;
  state_.phase = "stopping";
  stop_node_();
}

HostState Host::State() {
  HostState state;
  { std::lock_guard<std::mutex> lock(mutex_); state = state_; }
  if (state.phase == "exited" || state.phase == "error") Wait();
  return state;
}

void Host::Push(HostEvent event) {
  if (events_.size() >= kMaximumEvents) {
    auto log = std::find_if(events_.begin(), events_.end(), [](const HostEvent& item) { return item.kind == "log"; });
    if (log != events_.end()) { events_.erase(log); ++dropped_; }
  }
  events_.push_back(std::move(event));
}

void Host::Line(const std::string& stream, std::string line) {
  for (size_t position = 0; (position = line.find("\x1b[", position)) != std::string::npos;) {
    auto end = line.find_first_not_of("0123456789;", position + 2);
    if (end == std::string::npos) { line.erase(position); break; }
    line.erase(position, end + 1 - position);
  }
  if (!line.empty() && line.back() == '\r') line.pop_back();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const std::string prefix = "dsh web: http://127.0.0.1:";
    const size_t separator = line.find("/?token=", prefix.size());
    if (state_.phase == "starting" && line.compare(0, prefix.size(), prefix) == 0 &&
        separator != std::string::npos && separator > prefix.size() && separator - prefix.size() <= 5) {
      const auto port_text = line.substr(prefix.size(), separator - prefix.size());
      const auto token = line.substr(separator + 8);
      const bool digits = std::all_of(port_text.begin(), port_text.end(), [](unsigned char c) { return c >= '0' && c <= '9'; });
      const bool valid_token = !token.empty() && std::all_of(token.begin(), token.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
      });
      const int port = digits ? std::stoi(port_text) : 0;
      if (valid_token && port > 0 && port <= 65535) {
        state_.phase = "running"; state_.base_url = line.substr(9, separator - 9); state_.token = token;
        secrets_.push_back(state_.token);
        HostEvent event; event.kind = "ready"; event.base_url = state_.base_url; event.token = state_.token;
        Push(std::move(event));
      }
    }
    for (const auto* marker : {"?token=", "&token="}) {
      size_t position = 0;
      while ((position = line.find(marker, position)) != std::string::npos) {
        position += 7;
        const auto end = line.find_first_of(" \t\r\n", position);
        line.replace(position, (end == std::string::npos ? line.size() : end) - position, "<redacted>");
        position += 10;
      }
    }
    for (const auto& secret : secrets_) {
      size_t position = 0;
      while ((position = line.find(secret, position)) != std::string::npos) {
        line.replace(position, secret.size(), "<redacted>"); position += 10;
      }
    }
    if (line.size() > kMaximumLine) line = "[OHOS host: oversized redacted log line discarded]";
    HostEvent event; event.kind = "log"; event.stream = stream; event.line = line; Push(std::move(event));
  }
  if (sink_) sink_(stream, line);
}

std::vector<HostEvent> Host::Drain() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<HostEvent> result;
  if (dropped_) {
    HostEvent event; event.kind = "log"; event.stream = "system";
    event.line = "[OHOS host: " + std::to_string(dropped_) + " old log lines dropped]";
    result.push_back(std::move(event)); dropped_ = 0;
  }
  while (!events_.empty()) { result.push_back(std::move(events_.front())); events_.pop_front(); }
  return result;
}

void Host::Wait() {
  std::lock_guard<std::mutex> lock(join_mutex_);
  if (engine_.joinable()) engine_.join();
}
}  // namespace dsh
