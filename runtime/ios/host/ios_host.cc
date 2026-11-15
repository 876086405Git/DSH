// A plain C surface over the shared host core, which is what Swift can reach through
// dlopen/dlsym. State and events travel as JSON so no C++ type crosses the boundary.
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "host_core.h"
#include "relocation_origin.h"
#include "guest_config_binding.h"

extern "C" int dsh_node_start(int argc, char** argv);
extern "C" int dsh_node_stop();

namespace {
std::mutex host_mutex;
std::unique_ptr<dsh::Host> host;

char* Copy(const std::string& text) {
  char* copy = static_cast<char*>(std::malloc(text.size() + 1));
  if (copy != nullptr) std::memcpy(copy, text.c_str(), text.size() + 1);
  return copy;
}

std::string Json(const std::string& text) {
  std::string result = "\"";
  const char hex[] = "0123456789abcdef";
  for (unsigned char c : text) {
    if (c == '"' || c == '\\') { result += '\\'; result += static_cast<char>(c); }
    else if (c < 0x20) { result += "\\u00"; result += hex[c >> 4]; result += hex[c & 15]; }
    else result += static_cast<char>(c);
  }
  return result + '"';
}

std::string Field(const char* name, const std::string& value, bool last = false) {
  return "\"" + std::string(name) + "\":" + Json(value) + (last ? "" : ",");
}

std::string ExitCode(const std::optional<int>& code) {
  return "\"exitCode\":" + (code ? std::to_string(*code) : std::string("null"));
}
}  // namespace

// Called only by the App before engine start; no JS or environment setter exists.
extern "C" __attribute__((visibility("default")))
int dsh_host_guest_config(int enabled, const char* json) {
  if ((enabled != 0 && enabled != 1) || !json || std::strlen(json) > 65536) return 1;
  std::lock_guard<std::mutex> lock(host_mutex);
  if (host) {
    const auto phase = host->State().phase;
    if (phase != "exited" && phase != "error") return 1;
  }
  std::lock_guard<std::mutex> config_lock(dsh_ios::guest_config::mutex);
  dsh_ios::guest_config::snapshot = json;
  dsh_ios::guest_config::enabled = enabled != 0;
  return 0;
}

extern "C" __attribute__((visibility("default")))
int dsh_host_start(const char* runtime_root, const char* guest_root, const char* dsh_home, const char* cache_dir,
                   const char* native_library_dir, const char* workspace, int env_count, const char** env_keys,
                   const char** env_values, char** error_code, char** error_message) {
  dsh::HostOptions options;
  options.runtime_root = runtime_root;
  options.guest_root = guest_root;
  options.dsh_home = dsh_home;
  options.cache_dir = cache_dir;
  options.native_library_dir = native_library_dir;
  options.workspace_roots = {workspace};
  for (int i = 0; i < env_count; ++i) options.env[env_keys[i]] = env_values[i];
  // The virtual shell finds its commands through this, in its own filesystem. What the
  // process inherits varies (the Simulator's has no /bin), and nothing else runs from it.
  options.env["PATH"] = "/usr/bin:/bin";
  std::lock_guard<std::mutex> lock(host_mutex);
  try {
    // A Host is good for one engine thread, so a new run gets a new one. Its destructor
    // waits for the old thread, and only an already finished run gets here.
    if (host) {
      const auto phase = host->State().phase;
      if (phase != "exited" && phase != "error") throw dsh::HostError("ERR_IOS_HOST_ALREADY_STARTED", "The engine is still running");
      host.reset();
    }
    dsh::ios::PreserveRelocationOrigin(options);
    auto next = std::make_unique<dsh::Host>();
    next->Start(std::move(options), dsh_node_start, dsh_node_stop);
    host = std::move(next);
    return 0;
  } catch (const dsh::HostError& error) {
    if (error_code != nullptr) *error_code = Copy(error.code);
    if (error_message != nullptr) *error_message = Copy(error.what());
  } catch (const std::exception& error) {
    if (error_code != nullptr) *error_code = Copy("ERR_IOS_HOST_START");
    if (error_message != nullptr) *error_message = Copy(error.what());
  }
  return 1;
}

extern "C" __attribute__((visibility("default"))) void dsh_host_stop() {
  std::lock_guard<std::mutex> lock(host_mutex);
  if (host) host->Stop();
}

extern "C" __attribute__((visibility("default"))) char* dsh_host_state() {
  std::lock_guard<std::mutex> lock(host_mutex);
  const auto state = host ? host->State() : dsh::HostState{};
  return Copy("{" + Field("phase", state.phase) + Field("baseUrl", state.base_url) + Field("token", state.token) +
              Field("errorCode", state.error_code) + Field("errorMessage", state.error_message) +
              ExitCode(state.exit_code) + "}");
}

extern "C" __attribute__((visibility("default"))) char* dsh_host_drain() {
  std::lock_guard<std::mutex> lock(host_mutex);
  std::string json = "[";
  if (host) {
    bool first = true;
    for (const auto& event : host->Drain()) {
      if (!first) json += ',';
      first = false;
      json += "{" + Field("kind", event.kind) + Field("stream", event.stream) + Field("line", event.line) +
              Field("baseUrl", event.base_url) + Field("token", event.token) + Field("errorCode", event.error_code) +
              Field("message", event.message) + ExitCode(event.exit_code) + "}";
    }
  }
  return Copy(json + "]");
}

extern "C" __attribute__((visibility("default"))) void dsh_host_free(char* text) { std::free(text); }
