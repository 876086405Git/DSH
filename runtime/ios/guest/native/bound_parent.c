#include "bound_parent.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int dsh_bound_parent(int root_fd, const char *path, size_t length,
                     int *parent_fd, char *leaf, size_t leaf_capacity) {
  if (!path || !parent_fd || !leaf || !length || length >= PATH_MAX ||
      path[0] == '/' || path[length - 1] == '/' || memchr(path, '\0', length)) {
    errno = EINVAL;
    return -1;
  }
  // Validate every component before obtaining any new descriptor.
  size_t start = 0;
  for (size_t i = 0; i <= length; i++) {
    if (i != length && path[i] != '/')
      continue;
    size_t n = i - start;
    if (!n || n > NAME_MAX || (n == 1 && path[start] == '.') ||
        (n == 2 && path[start] == '.' && path[start + 1] == '.') ||
        (i == length && n >= leaf_capacity)) {
      errno = EINVAL;
      return -1;
    }
    start = i + 1;
  }
  struct stat info;
  if (fstat(root_fd, &info) < 0)
    return -1;
  if (!S_ISDIR(info.st_mode)) {
    errno = ENOTDIR;
    return -1;
  }
  int current = fcntl(root_fd, F_DUPFD_CLOEXEC, 0);
  if (current < 0)
    return -1;
  start = 0;
  for (size_t i = 0; i <= length; i++) {
    if (i != length && path[i] != '/')
      continue;
    size_t n = i - start;
    if (i == length) {
      memcpy(leaf, path + start, n);
      leaf[n] = '\0';
      *parent_fd = current;
      return 0;
    }
    char component[NAME_MAX + 1];
    memcpy(component, path + start, n);
    component[n] = '\0';
    int next = openat(current, component,
                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int saved = errno;
    close(current);
    if (next < 0) {
      errno = saved;
      return -1;
    }
    current = next;
    start = i + 1;
  }
  close(current);
  errno = EINVAL;
  return -1;
}
