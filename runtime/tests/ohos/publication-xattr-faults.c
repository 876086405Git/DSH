/* Linux test-only interposition. These are injected syscall outcomes, not
 * measurements of a device filesystem. Never link this file into the host. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>

ssize_t fgetxattr(int fd, const char *name, void *value, size_t size) {
  const char *mode = getenv("DSH_TEST_XATTR_GET_FAULT");
  if (mode && strcmp(name, "user.dsh_go_ownership") == 0) {
    if (strcmp(mode, "range-after-size") == 0) {
      if (value == NULL && size == 0) return 2;
      errno = ERANGE; return -1;
    }
    if (strcmp(mode, "empty-then-grow") == 0) {
      static unsigned queries = 0;
      if (value == NULL && size == 0) return queries++ == 0 ? 0 : 4;
      errno = ERANGE; return -1;
    }
    if (strcmp(mode, "missing-after-size") == 0) {
      if (value == NULL && size == 0) return 36;
      errno = ENODATA; return -1;
    }
    if (strcmp(mode, "shrink-after-size") == 0) {
      if (value == NULL && size == 0) return 8;
      if (size < 2) { errno = ERANGE; return -1; }
      memcpy(value, "ok", 2); return 2;
    }
    if (strcmp(mode, "empty") == 0) return 0;
    if (strcmp(mode, "unsupported") == 0) { errno = ENOTSUP; return -1; }
  }
  ssize_t (*actual)(int, const char *, void *, size_t) = dlsym(RTLD_NEXT, "fgetxattr");
  return actual(fd, name, value, size);
}

int fsetxattr(int fd, const char *name, const void *value, size_t size, int flags) {
  const char *mode = getenv("DSH_TEST_XATTR_SET_FAULT");
  if (mode && strcmp(name, "user.dsh_go_ownership") == 0) {
    if (strcmp(mode, "io") == 0) { errno = EIO; return -1; }
    if (strcmp(mode, "unsupported") == 0) { errno = ENOTSUP; return -1; }
  }
  int (*actual)(int, const char *, const void *, size_t, int) = dlsym(RTLD_NEXT, "fsetxattr");
  return actual(fd, name, value, size, flags);
}
