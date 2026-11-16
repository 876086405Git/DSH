// Linux integration driver: generate the production Host profile, argv and
// fixed environment (ARGV_JSON.env.json). This callback does not start Node.
#include "host_core.h"

#include <cstdlib>
#include <fstream>
#include <filesystem>
#include <iostream>
#include <string>

namespace {
std::string output;
std::string Json(const std::string& value) {
  std::string result = "\"";
  const char hex[] = "0123456789abcdef";
  for (unsigned char c : value) {
    if (c == '"' || c == '\\') { result += '\\'; result += c; }
    else if (c < 0x20) { result += "\\u00"; result += hex[c >> 4]; result += hex[c & 15]; }
    else result += c;
  }
  return result + '"';
}
int CaptureArguments(int argc, char** argv) {
  std::ofstream file(output);
  file << '[';
  for (int i = 0; i < argc; ++i) { if (i) file << ','; file << Json(argv[i]); }
  file << "]\n";
  std::ofstream environment(output + ".env.json");
  environment << '{';
  bool first = true;
  for (const auto* key : {"HOME", "DSH_HOME", "DSH_AGENTS_HOME", "TMPDIR", "NODE_COMPILE_CACHE",
      "NARB_DISABLE_NATIVE_CACHE", "DSH_GO_OHOS_NATIVE_LIBRARY_DIR", "DSH_GO_OHOS_LINUX_DIRECTORY", "DSH_PERMISSION_MODE"}) {
    const auto* value = std::getenv(key);
    if (!value) return 97;
    if (!first) environment << ',';
    first = false;
    environment << Json(key) << ':' << Json(value);
  }
  environment << "}\n";
  return file && environment ? 0 : 97;
}
int NoEngineToStop() { return 0; }
}  // namespace

int main(int argc, char** argv) {
  if (argc != 8 && argc != 9) {
    std::cerr << "Usage: host-profile RUNTIME_ROOT GUEST_ROOT DSH_HOME WORKSPACE CACHE_DIR NATIVE_LIBRARY_DIR ARGV_JSON [safe]\n";
    return 2;
  }
  output = argv[7];
  dsh::Host host;
  try {
    dsh::HostOptions options;
    options.runtime_root = argv[1]; options.guest_root = argv[2]; options.dsh_home = argv[3];
    options.workspace_roots = {argv[4]}; options.cache_dir = argv[5];
    options.native_library_dir = argv[6];
    options.linux_directory = (std::filesystem::path(options.guest_root).parent_path().parent_path() / "linux-tools").string();
    std::filesystem::create_directories(options.linux_directory);
    if (argc == 9) {
      if (std::string(argv[8]) != "safe") return 2;
      options.safe_mode = true;
    }
    host.Start(std::move(options), CaptureArguments, NoEngineToStop);
    host.Wait();
    const auto state = host.State();
    if (state.phase != "exited" || state.exit_code != 0) {
      std::cerr << state.phase << ' ' << state.error_code << '\n'; return 1;
    }
    std::cout << "Generated production Host profile, argv and fixed environment; Node was not started by this driver.\n";
    return 0;
  } catch (const dsh::HostError& error) {
    std::cerr << error.code << '\n'; return 1;
  }
}
