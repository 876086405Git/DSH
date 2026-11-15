#pragma once

#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace dsh {
struct HostOptions {
  std::string runtime_root, guest_root, dsh_home, cache_dir, native_library_dir;
  std::vector<std::string> workspace_roots;
  std::map<std::string, std::string> env;
};

struct HostState {
  std::string phase = "idle";
  bool consumed = false;
  std::string base_url, token, error_code, error_message;
  std::optional<int> exit_code;
};

struct HostEvent {
  std::string kind, stream, line, base_url, token, error_code, message;
  std::optional<int> exit_code;
};

class HostError : public std::runtime_error {
 public:
  HostError(std::string code, const char* message) : std::runtime_error(message), code(std::move(code)) {}
  const std::string code;
};

using StartNode = int (*)(int, char**);
using StopNode = int (*)();
using LogSink = std::function<void(const std::string&, const std::string&)>;

// Own exactly one engine thread. Product lifetime is the whole application.
class Host {
 public:
  explicit Host(LogSink sink = {}) : sink_(std::move(sink)) {}
  ~Host();
  void Start(HostOptions options, StartNode start_node, StopNode stop_node);
  void Stop();
  HostState State();
  std::vector<HostEvent> Drain();
  void Wait();

 private:
  void Run(HostOptions options, StartNode start_node);
  void Line(const std::string& stream, std::string line);
  void Push(HostEvent event);
  std::mutex mutex_;
  std::mutex join_mutex_;
  HostState state_;
  std::deque<HostEvent> events_;
  size_t dropped_ = 0;
  std::vector<std::string> secrets_;
  std::thread engine_;
  StopNode stop_node_ = nullptr;
  bool stop_requested_ = false;
  LogSink sink_;
};
}  // namespace dsh
