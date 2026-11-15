#include "bound_admission.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int copy_path(struct dsh_path_span p, char out[PATH_MAX]) {
  if (!p.bytes || p.length < 2 || p.length >= PATH_MAX || p.bytes[0] != '/' ||
      memchr(p.bytes, 0, p.length)) {
    errno = EINVAL;
    return -1;
  }
  memcpy(out, p.bytes, p.length);
  out[p.length] = 0;
  const char *part = out + 1;
  for (const char *c = part;; c++)
    if (*c == '/' || !*c) {
      size_t n = c - part;
      if (!n || (n == 1 && part[0] == '.') ||
          (n == 2 && part[0] == '.' && part[1] == '.')) {
        errno = EINVAL;
        return -1;
      }
      if (!*c)
        break;
      part = c + 1;
    }
  return 0;
}
// For a not-yet-created protected directory, canonicalize its existing
// ancestor. Never silently ignore an absent .agents/.dsh policy path.
static int protected_canonical(const char *input, char out[PATH_MAX]) {
  char prefix[PATH_MAX], suffix[PATH_MAX] = "";
  strcpy(prefix, input);
  for (;;) {
    if (realpath(prefix, out)) {
      size_t a = strlen(out), b = strlen(suffix);
      if (a + b >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
      }
      if (a == 1 && out[0] == '/' && b && suffix[0] == '/')
        out[0] = 0;
      strcat(out, suffix);
      return 0;
    }
    if (errno != ENOENT)
      return -1;
    struct stat existing;
    if (lstat(prefix, &existing) == 0 && S_ISLNK(existing.st_mode)) {
      errno = ELOOP;
      return -1;
    }
    char *slash = strrchr(prefix, '/');
    if (!slash) {
      errno = EINVAL;
      return -1;
    }
    size_t tail = strlen(slash), old = strlen(suffix);
    if (tail + old >= PATH_MAX) {
      errno = ENAMETOOLONG;
      return -1;
    }
    memmove(suffix + tail, suffix, old + 1);
    memcpy(suffix, slash, tail);
    if (slash == prefix)
      prefix[1] = 0;
    else
      *slash = 0;
  }
}
static int under(const char *a, const char *b) {
  size_t n = strlen(b);
  return !strncmp(a, b, n) && (a[n] == 0 || a[n] == '/');
}
static int open_root(const char *canonical) {
#ifdef __APPLE__
  // App-container ancestors need not be openable on iOS. Bind the canonical
  // directory directly, then verify the opened capability still names it.
  int fd = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    return -1;
  char path[PATH_MAX];
  int error = 0;
  if (fcntl(fd, F_GETPATH, path) < 0)
    error = errno;
  else if (strcmp(path, canonical))
    error = EPERM;
  if (error) {
    close(fd);
    errno = error;
    return -1;
  }
  return fd;
#else
  int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0)
    return -1;
  const char *p = canonical + 1;
  while (*p) {
    const char *slash = strchr(p, '/');
    size_t n = slash ? (size_t)(slash - p) : strlen(p);
    if (!n || n > NAME_MAX) {
      close(fd);
      errno = ENAMETOOLONG;
      return -1;
    }
    char name[NAME_MAX + 1];
    memcpy(name, p, n);
    name[n] = 0;
    int next =
        openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int e = errno;
    close(fd);
    if (next < 0) {
      errno = e;
      return -1;
    }
    fd = next;
    if (!slash)
      break;
    p = slash + 1;
  }
  return fd;
#endif
}
dsh_root *dsh_admit_workspace(struct dsh_path_span requested,
                              const struct dsh_path_span *protected_paths,
                              size_t count, bool readonly) {
  if (!protected_paths || !count) {
    errno = EINVAL;
    return NULL;
  }
  char input[PATH_MAX], root[PATH_MAX];
  if (copy_path(requested, input) < 0 || !realpath(input, root))
    return NULL;
  if (!strcmp(root, "/")) {
    errno = EPERM;
    return NULL;
  }
  for (size_t i = 0; i < count; i++) {
    char raw[PATH_MAX], protected[PATH_MAX];
    if (copy_path(protected_paths[i], raw) < 0 ||
        protected_canonical(raw, protected) < 0)
      return NULL;
    if (!strcmp(protected, "/") || under(root, protected) ||
        under(protected, root)) {
      errno = EPERM;
      return NULL;
    }
  }
  int fd = open_root(root);
  if (fd < 0)
    return NULL;
  dsh_root *result = dsh_root_new_workspace(fd, readonly);
  int e = errno;
  close(fd);
  errno = e;
  return result;
}
