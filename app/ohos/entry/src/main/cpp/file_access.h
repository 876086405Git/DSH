#ifndef DSH_OHOS_FILE_ACCESS_H_
#define DSH_OHOS_FILE_ACCESS_H_

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <string>
#include <system_error>

namespace dsh {

// Ark supplies an application-owned workspace/cache root, never a Dart-supplied
// root. The returned regular-file descriptor belongs to the caller.
inline int OpenUserFile(const std::string& root, const std::string& relative) {
  const auto invalid = [] { throw std::system_error(EINVAL, std::generic_category(), "Invalid user file path"); };
  if (root.empty() || root.front() != '/' || root.back() == '/' || root.find('\0') != std::string::npos ||
      relative.empty() || relative.front() == '/' || relative.find('\0') != std::string::npos) invalid();
  int directory = open(root.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (directory < 0) throw std::system_error(errno, std::generic_category(), "Cannot open user file root");
  size_t start = 0;
  for (;;) {
    const size_t slash = relative.find('/', start);
    const std::string part = relative.substr(start, slash == std::string::npos ? slash : slash - start);
    if (part.empty() || part == "." || part == "..") { close(directory); invalid(); }
    const bool last = slash == std::string::npos;
    const int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? O_NONBLOCK : O_DIRECTORY);
    const int next = openat(directory, part.c_str(), flags);
    const int error = errno;
    close(directory);
    if (next < 0) throw std::system_error(error, std::generic_category(), "Cannot open user file");
    if (last) {
      struct stat status;
      if (fstat(next, &status) != 0) {
        const int stat_error = errno; close(next);
        throw std::system_error(stat_error, std::generic_category(), "Cannot inspect user file");
      }
      if (!S_ISREG(status.st_mode)) { close(next); invalid(); }
      return next;
    }
    directory = next;
    start = slash + 1;
  }
}

}  // namespace dsh
#endif
