#pragma once

#include <cerrno>
#include <filesystem>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#include "host_core.h"

namespace dsh::ios {
namespace relocation_detail {
inline void Check(bool ok, const char* message) {
  if (!ok) throw HostError("ERR_IOS_RELOCATION_ORIGIN", message);
}
class Descriptor {
 public:
  explicit Descriptor(int value) : value_(value) {}
  ~Descriptor() { if (value_ >= 0) close(value_); }
  Descriptor(const Descriptor&) = delete;
  Descriptor& operator=(const Descriptor&) = delete;
  int get() const { return value_; }
 private:
  int value_;
};
inline std::string Directory(const std::string& path) {
  Check(!path.empty() && path.front() == '/' && path.find('\0') == std::string::npos,
        "Relocation requires absolute directory paths");
  std::error_code error;
  const auto real = std::filesystem::canonical(path, error);
  Check(!error && std::filesystem::is_directory(real, error) && !error,
        "Relocation directory is missing or invalid");
  return real.string();
}
inline bool Regular(const struct stat& info) {
  return S_ISREG(info.st_mode) && info.st_size >= 0 && info.st_size <= 64 * 1024;
}
}  // namespace relocation_detail

// Called with the iOS host mutex held, after the previous engine thread has
// joined. The shared core replaces its profile by rename; this link therefore
// retains the previous inode until JS commits the relocation marker.
inline void PreserveRelocationOrigin(const HostOptions& options) {
  using namespace relocation_detail;
  const std::string hook = options.runtime_root + "/runtime/ios/storage/relocate.mjs";
  struct stat hook_info {};
  if (lstat(hook.c_str(), &hook_info) != 0) {
    if (errno == ENOENT) return;  // Runtime predating relocation: unchanged.
    Check(false, "Cannot inspect the iOS relocation module");
  }
  Check(S_ISREG(hook_info.st_mode), "The iOS relocation module must be a regular file");
  const auto runtime = Directory(options.runtime_root);
  std::error_code error;
  const auto real_hook = std::filesystem::canonical(hook, error);
  Check(!error && real_hook.string() == runtime + "/runtime/ios/storage/relocate.mjs",
        "The relocation module must remain inside its runtime");
  const auto guest = Directory(options.guest_root);
  const auto home = Directory(options.dsh_home);
  Check(home == guest + "/root/.dsh" && options.workspace_roots.size() == 1 &&
            Directory(options.workspace_roots.front()) == guest + "/root/workspace",
        "Relocation requires the fixed iOS guest layout");
  // Do not write an origin on an invalid start with absent support directories.
  Directory(options.cache_dir);
  Directory(options.native_library_dir);
  Descriptor directory(open(home.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  Check(directory.get() >= 0, "Cannot open the relocation directory");
  constexpr const char* origin = "ios-relocation-origin.json";
  constexpr const char* profile = "ohos-host.patch.json";
  struct stat saved {};
  if (fstatat(directory.get(), origin, &saved, AT_SYMLINK_NOFOLLOW) == 0) {
    Check(Regular(saved), "Existing relocation origin is not a bounded regular file");
    Check(fsync(directory.get()) == 0, "Cannot persist the existing relocation origin directory");
    return;  // Never replace the first pre-migration profile on a retry.
  }
  Check(errno == ENOENT, "Cannot inspect the relocation origin");
  Descriptor source(openat(directory.get(), profile, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK));
  if (source.get() < 0) {
    if (errno == ENOENT) return;  // First installation has no previous profile.
    Check(false, "Cannot open the previous runtime profile");
  }
  struct stat previous {};
  Check(fstat(source.get(), &previous) == 0 && Regular(previous),
        "Previous runtime profile is not a bounded regular file");
  if (linkat(directory.get(), profile, directory.get(), origin, 0) != 0) {
    // No overwrite/copy fallback: unsupported hard links must not silently
    // permit the shared core to destroy the only trustworthy old-root record.
    Check(false, "Cannot preserve the previous runtime profile without replacement");
  }
  struct stat published {};
  const bool same = fstatat(directory.get(), origin, &published, AT_SYMLINK_NOFOLLOW) == 0 &&
      Regular(published) && published.st_dev == previous.st_dev && published.st_ino == previous.st_ino;
  if (!same) {
    unlinkat(directory.get(), origin, 0);
    Check(false, "Previous runtime profile changed while preserving its origin");
  }
  Check(fsync(directory.get()) == 0, "Cannot persist the relocation origin directory");
}
}  // namespace dsh::ios
