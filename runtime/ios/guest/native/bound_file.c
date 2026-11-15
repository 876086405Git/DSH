#include "bound_file.h"
#include "bound_parent.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
struct dsh_root {
  int fd;
  bool readonly;
  dev_t dev;
  ino_t ino;
  bool reject_multilink;
};
struct dsh_file {
  int fd;
  bool readonly;
  bool reject_multilink;
};
static int deny(void) {
  errno = EROFS;
  return -1;
}
static int regular(int fd) {
  struct stat s;
  if (fstat(fd, &s) < 0)
    return -1;
  if (!S_ISREG(s.st_mode)) {
    errno = EINVAL;
    return -1;
  }
  return 0;
}
static int leaf_regular(int parent, const char *name, bool missing_ok) {
  struct stat s;
  if (fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) < 0)
    return missing_ok && errno == ENOENT ? 0 : -1;
  if (!S_ISREG(s.st_mode)) {
    errno = S_ISLNK(s.st_mode) ? ELOOP : EINVAL;
    return -1;
  }
  return 0;
}
dsh_root *dsh_root_new(int fd, bool readonly) {
  struct stat s;
  if (fstat(fd, &s) < 0)
    return NULL;
  if (!S_ISDIR(s.st_mode)) {
    errno = ENOTDIR;
    return NULL;
  }
  int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (copy < 0)
    return NULL;
  dsh_root *r = malloc(sizeof *r);
  if (!r) {
    int e = errno;
    close(copy);
    errno = e;
    return NULL;
  }
  *r = (dsh_root){copy, readonly, s.st_dev, s.st_ino, false};
  return r;
}
dsh_root *dsh_root_new_workspace(int fd, bool readonly) {
  dsh_root *r = dsh_root_new(fd, readonly);
  if (r)
    r->reject_multilink = true;
  return r;
}
static int link_policy(dsh_root *r, int fd) {
  if (!r->reject_multilink)
    return 0;
  struct stat s;
  if (fstat(fd, &s) < 0)
    return -1;
  if (s.st_nlink != 1) {
    errno = EPERM;
    return -1;
  }
  return 0;
}
void dsh_root_free(dsh_root *r) {
  if (r) {
    close(r->fd);
    free(r);
  }
}
dsh_file *dsh_file_open(dsh_root *r, const char *p, size_t n, int flags,
                        mode_t mode) {
  if (!r) {
    errno = EINVAL;
    return NULL;
  }
  int allowed = O_ACCMODE | O_CREAT | O_EXCL | O_TRUNC | O_APPEND | O_CLOEXEC;
  if ((flags & ~allowed) || ((flags & O_ACCMODE) == O_ACCMODE) ||
      (mode & ~0777) || ((flags & O_EXCL) && !(flags & O_CREAT))) {
    errno = EINVAL;
    return NULL;
  }
  bool writing = (flags & O_ACCMODE) != O_RDONLY ||
                 (flags & (O_CREAT | O_TRUNC | O_APPEND));
  if (r->readonly && writing) {
    deny();
    return NULL;
  }
  int parent;
  char leaf[NAME_MAX + 1];
  if (dsh_bound_parent(r->fd, p, n, &parent, leaf, sizeof leaf) < 0)
    return NULL;
  int fd = -1;
  int access = (flags & O_ACCMODE) | (flags & O_APPEND) | O_NOFOLLOW |
               O_CLOEXEC | O_NONBLOCK | O_NOCTTY;
  if (flags & O_CREAT) {
    // Exclusive creation never follows or truncates a pre-existing leaf.
    fd = openat(parent, leaf, access | O_CREAT | O_EXCL, mode);
    if (fd < 0 && (errno != EEXIST || (flags & O_EXCL)))
      goto fail;
  }
  if (fd < 0) {
    if (leaf_regular(parent, leaf, false) < 0)
      goto fail;
    fd = openat(parent, leaf, access);
    if (fd < 0)
      goto fail;
  }
  // No truncation, payload write or metadata mutation precedes this check.
  if (regular(fd) < 0 || link_policy(r, fd) < 0)
    goto fail;
  if ((flags & O_TRUNC) && ftruncate(fd, 0) < 0)
    goto fail;
  dsh_file *f = malloc(sizeof *f);
  if (!f)
    goto fail;
  *f = (dsh_file){fd, r->readonly, r->reject_multilink};
  close(parent);
  return f;
fail: {
  int e = errno;
  if (fd >= 0)
    close(fd);
  close(parent);
  errno = e;
  return NULL;
}
}
static int file_link_policy(dsh_file *f) {
  if (!f->reject_multilink)
    return 0;
  struct stat s;
  if (fstat(f->fd, &s) < 0)
    return -1;
  if (s.st_nlink != 1) {
    errno = EPERM;
    return -1;
  }
  return 0;
}
bool dsh_file_readonly(const dsh_file *f) { return f->readonly; }
void dsh_file_close(dsh_file *f) {
  if (f) {
    close(f->fd);
    free(f);
  }
}
dsh_file *dsh_file_dup(dsh_file *f) {
  int fd = fcntl(f->fd, F_DUPFD_CLOEXEC, 0);
  if (fd < 0)
    return NULL;
  dsh_file *n = malloc(sizeof *n);
  if (!n) {
    int e = errno;
    close(fd);
    errno = e;
    return NULL;
  }
  *n = (dsh_file){fd, f->readonly, f->reject_multilink};
  return n;
}
ssize_t dsh_file_read(dsh_file *f, void *b, size_t n) {
  return file_link_policy(f) < 0 ? -1 : read(f->fd, b, n);
}
ssize_t dsh_file_pread(dsh_file *f, void *b, size_t n, off_t o) {
  return file_link_policy(f) < 0 ? -1 : pread(f->fd, b, n, o);
}
ssize_t dsh_file_write(dsh_file *f, const void *b, size_t n) {
  return f->readonly               ? deny()
         : file_link_policy(f) < 0 ? -1
                                   : write(f->fd, b, n);
}
ssize_t dsh_file_pwrite(dsh_file *f, const void *b, size_t n, off_t o) {
  return f->readonly               ? deny()
         : file_link_policy(f) < 0 ? -1
                                   : pwrite(f->fd, b, n, o);
}
off_t dsh_file_seek(dsh_file *f, off_t o, int w) { return lseek(f->fd, o, w); }
int dsh_file_stat(dsh_file *f, struct stat *s) { return fstat(f->fd, s); }
int dsh_file_truncate(dsh_file *f, off_t n) {
  return f->readonly               ? deny()
         : file_link_policy(f) < 0 ? -1
                                   : ftruncate(f->fd, n);
}
int dsh_file_chmod(dsh_file *f, mode_t m) {
  if (f->readonly)
    return deny();
  if (m & ~0777) {
    errno = EPERM;
    return -1;
  }
  if (file_link_policy(f) < 0)
    return -1;
  return fchmod(f->fd, m);
}
int dsh_file_chown(dsh_file *f, uid_t u, gid_t g) {
  return f->readonly               ? deny()
         : file_link_policy(f) < 0 ? -1
                                   : fchown(f->fd, u, g);
}
int dsh_file_times(dsh_file *f, const struct timespec t[2]) {
  return f->readonly               ? deny()
         : file_link_policy(f) < 0 ? -1
                                   : futimens(f->fd, t);
}
int dsh_file_sync(dsh_file *f) { return fsync(f->fd); }
void *dsh_file_map_private(dsh_file *f, size_t n, int prot, int flags,
                           off_t o) {
  // No shared file-backed mapping is exposed, even if initially PROT_READ.
  if (f->reject_multilink || flags != MAP_PRIVATE ||
      (prot & ~(PROT_READ | PROT_WRITE))) {
    errno = ENOTSUP;
    return MAP_FAILED;
  }
  return mmap(NULL, n, prot, MAP_PRIVATE, f->fd, o);
}
static int leaf_renameable(int parent, const char *name, bool missing_ok) {
  struct stat s;
  if (fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) < 0)
    return missing_ok && errno == ENOENT ? 0 : -1;
  if (!S_ISREG(s.st_mode) && !S_ISDIR(s.st_mode) && !S_ISLNK(s.st_mode)) {
    errno = EPERM;
    return -1;
  }
  return 0;
}
static int pair(dsh_root *a, const char *p, size_t n, dsh_root *b,
                const char *q, size_t k, bool linkop) {
  if (a->readonly || b->readonly)
    return deny();
  if (linkop && (a->reject_multilink || b->reject_multilink)) {
    errno = ENOTSUP;
    return -1;
  }
  if (a->dev != b->dev || a->ino != b->ino) {
    errno = EXDEV;
    return -1;
  }
  int x = -1, y = -1;
  char src[NAME_MAX + 1], dst[NAME_MAX + 1];
  if (dsh_bound_parent(a->fd, p, n, &x, src, sizeof src) < 0)
    return -1;
  if (dsh_bound_parent(b->fd, q, k, &y, dst, sizeof dst) < 0)
    goto fail;
  if (linkop
          ? (leaf_regular(x, src, false) < 0 || leaf_regular(y, dst, true) < 0)
          : (leaf_renameable(x, src, false) < 0 ||
             leaf_renameable(y, dst, true) < 0))
    goto fail;
  int result = linkop ? linkat(x, src, y, dst, 0) : renameat(x, src, y, dst);
  {
    int e = errno;
    close(x);
    close(y);
    errno = e;
    return result;
  }
fail: {
  int e = errno;
  if (x >= 0)
    close(x);
  if (y >= 0)
    close(y);
  errno = e;
  return -1;
}
}
int dsh_file_rename(dsh_root *a, const char *p, size_t n, dsh_root *b,
                    const char *q, size_t k) {
  return pair(a, p, n, b, q, k, false);
}
int dsh_file_link(dsh_root *a, const char *p, size_t n, dsh_root *b,
                  const char *q, size_t k) {
  return pair(a, p, n, b, q, k, true);
}
int dsh_file_symlink(dsh_root *r, const char *target, size_t length,
                     const char *link, size_t link_length) {
  if (!r) { errno = EINVAL; return -1; }
  if (r->readonly) return deny();
  if (!target || !length || length >= PATH_MAX || memchr(target, '\0', length)) {
    errno = EINVAL;
    return -1;
  }
  if (target[0] == '/') { errno = EPERM; return -1; }
  // Deliberately narrow: relative text with no parent component. Do not infer
  // a permanent target boundary from the link's current directory depth;
  // links and their parent directories may subsequently be renamed.
  size_t start = 0;
  for (size_t i = 0; i <= length; ++i) {
    if (i != length && target[i] != '/') continue;
    size_t n = i - start;
    if (n > NAME_MAX) { errno = ENAMETOOLONG; return -1; }
    if (n == 2 && target[start] == '.' && target[start + 1] == '.') {
      errno = EPERM;
      return -1;
    }
    start = i + 1;
  }
  int parent;
  char leaf[NAME_MAX + 1];
  if (dsh_bound_parent(r->fd, link, link_length, &parent, leaf, sizeof leaf) < 0)
    return -1;
  char text[PATH_MAX];
  memcpy(text, target, length); text[length] = '\0';
  int result = symlinkat(text, parent, leaf), saved = errno;
  close(parent);
  errno = saved;
  return result;
}
int dsh_file_unlink(dsh_root *r, const char *p, size_t n) {
  if (r->readonly)
    return deny();
  int fd;
  char leaf[NAME_MAX + 1];
  if (dsh_bound_parent(r->fd, p, n, &fd, leaf, sizeof leaf) < 0)
    return -1;
  struct stat st;
  int result = fstatat(fd, leaf, &st, AT_SYMLINK_NOFOLLOW);
  if (result == 0) {
    if (!S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode)) {
      errno = S_ISDIR(st.st_mode) ? EISDIR : EPERM;
      result = -1;
    } else {
      result = unlinkat(fd, leaf, 0);
    }
  }
  int e = errno;
  close(fd);
  errno = e;
  return result;
}

struct dsh_directory {
  DIR *stream;
  bool readonly;
};
dsh_directory *dsh_directory_open(dsh_root *r, const char *p, size_t n) {
  if (!r || !p) {
    errno = EINVAL;
    return NULL;
  }
  int fd;
  if (n == 0) {
    // Fresh open description: dup would share iteration offsets across callers.
    fd = openat(r->fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  } else {
    int parent;
    char leaf[NAME_MAX + 1];
    if (dsh_bound_parent(r->fd, p, n, &parent, leaf, sizeof leaf) < 0)
      return NULL;
    fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int e = errno;
    close(parent);
    errno = e;
  }
  if (fd < 0)
    return NULL;
  DIR *stream = fdopendir(fd);
  if (!stream) {
    int e = errno;
    close(fd);
    errno = e;
    return NULL;
  }
  dsh_directory *d = malloc(sizeof *d);
  if (!d) {
    int e = errno;
    closedir(stream);
    errno = e;
    return NULL;
  }
  d->stream = stream;
  d->readonly = r->readonly;
  return d;
}
void dsh_directory_close(dsh_directory *d) {
  if (d) {
    closedir(d->stream);
    free(d);
  }
}
int dsh_directory_next(dsh_directory *d, char *name, size_t capacity,
                       ino_t *inode) {
  if (!d || !name || capacity == 0 || !inode) {
    errno = EINVAL;
    return -1;
  }
  errno = 0;
  struct dirent *entry = readdir(d->stream);
  if (!entry)
    return errno ? -1 : 0;
  size_t n = strlen(entry->d_name);
  if (n >= capacity) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(name, entry->d_name, n + 1);
  *inode = entry->d_ino;
  return 1;
}
int dsh_directory_rewind(dsh_directory *d) {
  if (!d) {
    errno = EINVAL;
    return -1;
  }
  rewinddir(d->stream);
  return 0;
}
int dsh_directory_stat(dsh_directory *d, struct stat *s) {
  return fstat(dirfd(d->stream), s);
}
int dsh_directory_chmod(dsh_directory *d, mode_t mode) {
  if (d->readonly)
    return deny();
  if (mode & ~0777) {
    errno = EPERM;
    return -1;
  }
  return fchmod(dirfd(d->stream), mode);
}
int dsh_directory_times(dsh_directory *d, const struct timespec times[2]) {
  return d->readonly ? deny() : futimens(dirfd(d->stream), times);
}
int dsh_directory_make(dsh_root *r, const char *p, size_t n, mode_t mode) {
  if (r->readonly)
    return deny();
  if (mode & ~0777) {
    errno = EPERM;
    return -1;
  }
  int parent;
  char leaf[NAME_MAX + 1];
  if (dsh_bound_parent(r->fd, p, n, &parent, leaf, sizeof leaf) < 0)
    return -1;
  int result = mkdirat(parent, leaf, mode), e = errno;
  close(parent);
  errno = e;
  return result;
}
int dsh_directory_remove(dsh_root *r, const char *p, size_t n) {
  if (r->readonly)
    return deny();
  int parent;
  char leaf[NAME_MAX + 1];
  if (dsh_bound_parent(r->fd, p, n, &parent, leaf, sizeof leaf) < 0)
    return -1;
  // AT_REMOVEDIR cannot follow a symlink or unlink a regular file.
  int result = unlinkat(parent, leaf, AT_REMOVEDIR), e = errno;
  close(parent);
  errno = e;
  return result;
}
int dsh_root_lstat(dsh_root *r, const char *p, size_t n, struct stat *s) {
  if (!r || !p || !s) {
    errno = EINVAL;
    return -1;
  }
  if (!n)
    return fstat(r->fd, s);
  int parent;
  char leaf[NAME_MAX + 1];
  if (dsh_bound_parent(r->fd, p, n, &parent, leaf, sizeof leaf) < 0)
    return -1;
  int result = fstatat(parent, leaf, s, AT_SYMLINK_NOFOLLOW), e = errno;
  close(parent);
  errno = e;
  return result;
}
ssize_t dsh_root_readlink(dsh_root *r, const char *p, size_t n, char *b,
                          size_t capacity) {
  if (!r || !p || !b || !capacity) {
    errno = EINVAL;
    return -1;
  }
  int parent;
  char leaf[NAME_MAX + 1];
  if (dsh_bound_parent(r->fd, p, n, &parent, leaf, sizeof leaf) < 0)
    return -1;
  ssize_t result = readlinkat(parent, leaf, b, capacity);
  int e = errno;
  close(parent);
  errno = e;
  return result;
}

long dsh_directory_tell(dsh_directory *d) { return telldir(d->stream); }
void dsh_directory_seek(dsh_directory *d, long position) {
  seekdir(d->stream, position);
}

bool dsh_root_readonly(dsh_root *r) { return r->readonly; }
int dsh_root_statvfs(dsh_root *r, struct statvfs *s) {
  return fstatvfs(r->fd, s);
}
static int descriptor_path(int fd, char path[PATH_MAX]) {
#if defined(__APPLE__)
  return fcntl(fd, F_GETPATH, path);
#elif defined(__linux__)
  char proc[64];
  snprintf(proc, sizeof proc, "/proc/self/fd/%d", fd);
  ssize_t n = readlink(proc, path, PATH_MAX - 1);
  if (n < 0)
    return -1;
  path[n] = 0;
  // proc renders a suffix for unlinked descriptors, but the same text is a
  // valid live filename. Verify the named inode instead of guessing by text.
  struct stat opened, named;
  if (fstat(fd, &opened) < 0)
    return -1;
  if (lstat(path, &named) < 0)
    return -1;
  if (opened.st_dev != named.st_dev || opened.st_ino != named.st_ino) {
    errno = ENOENT;
    return -1;
  }
  return 0;
#else
  errno = ENOTSUP;
  return -1;
#endif
}
static int relative_path(dsh_root *r, int fd, char *out, size_t capacity) {
  char root[PATH_MAX], file[PATH_MAX];
  if (descriptor_path(r->fd, root) < 0 || descriptor_path(fd, file) < 0)
    return -1;
  size_t n = strlen(root);
  if (strncmp(root, file, n) || (file[n] && file[n] != '/')) {
    errno = EXDEV;
    return -1;
  }
  size_t length = strlen(file + n);
  if (length + 1 > capacity) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(out, file + n, length + 1);
  return 0;
}
int dsh_file_relative_path(dsh_root *r, dsh_file *f, char *out, size_t n) {
  return relative_path(r, f->fd, out, n);
}
int dsh_directory_relative_path(dsh_root *r, dsh_directory *d, char *out,
                                size_t n) {
  return relative_path(r, dirfd(d->stream), out, n);
}
