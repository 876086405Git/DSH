#include "bound_ish_fs.h"
#include "bound_ish_directory.h"
#include "bound_ish_fd.h"
#include "kernel/calls.h"
#include "kernel/errno.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
struct bound_mount {
  dsh_root *root;
  uid_t_ uid;
  uid_t_ gid;
};
static _Thread_local struct bound_mount *pending;
static int mount_root(struct mount *m) {
  if (!pending)
    return _EPERM;
  m->data = pending;
  return 0;
}
static int unmount_root(struct mount *m) {
  struct bound_mount *b = m->data;
  dsh_root_free(b->root);
  free(b);
  m->data = NULL;
  return 0;
}
static const char *relative(const char *p) { return *p == '/' ? p + 1 : p; }
static struct bound_mount *context(struct mount *m) { return m->data; }
static void projected_stat(struct bound_mount *b, const struct stat *s,
                           struct statbuf *out) {
  memset(out, 0, sizeof *out);
  out->dev = s->st_dev;
  out->inode = s->st_ino;
  out->mode = s->st_mode;
  out->nlink = s->st_nlink;
  out->uid = b->uid;
  out->gid = b->gid;
  out->size = s->st_size;
  out->blksize = s->st_blksize;
  out->blocks = s->st_blocks;
  out->atime = s->st_atime;
  out->mtime = s->st_mtime;
  out->ctime = s->st_ctime;
  if (dsh_root_readonly(b->root))
    out->mode &= ~0222;
}
static int stat_path(struct mount *m, const char *p, struct statbuf *out) {
  struct stat s;
  struct bound_mount *b = context(m);
  p = relative(p);
  if (dsh_root_lstat(b->root, p, strlen(p), &s) < 0)
    return errno_map();
  projected_stat(b, &s, out);
  return 0;
}
static int stat_fd(struct fd *f, struct statbuf *out) {
  struct stat s;
  int r = S_ISDIR(f->type) ? dsh_directory_stat(f->data, &s)
                           : dsh_file_stat(f->data, &s);
  if (r < 0)
    return errno_map();
  projected_stat(context(f->mount), &s, out);
  return 0;
}
static struct fd *open_path(struct mount *m, const char *p, int flags,
                            int mode) {
  const int supported = O_ACCMODE_ | O_CREAT_ | O_EXCL_ | O_TRUNC_ | O_APPEND_ |
                        O_DIRECTORY_ | O_NOFOLLOW_ | O_CLOEXEC_ | O_LARGEFILE_ |
                        O_NOCTTY_ | O_NONBLOCK_;
  if (flags & ~supported)
    return ERR_PTR(_ENOTSUP);
  p = relative(p);
  struct bound_mount *b = context(m);
  struct stat s;
  int r = dsh_root_lstat(b->root, p, strlen(p), &s);
  if (r == 0 && S_ISDIR(s.st_mode)) {
    if (flags & (O_ACCMODE_ | O_CREAT_ | O_TRUNC_ | O_APPEND_))
      return ERR_PTR(_EISDIR);
    dsh_directory *d = dsh_directory_open(b->root, p, strlen(p));
    if (!d)
      return ERR_PTR(errno_map());
    struct fd *f = fd_create(NULL);
    if (!f) {
      dsh_directory_close(d);
      return ERR_PTR(_ENOMEM);
    }
    dsh_bound_attach_directory(f, d);
    return f;
  }
  if (flags & O_DIRECTORY_)
    return ERR_PTR(r < 0 ? errno_map() : _ENOTDIR);
  int hostflags = flags & O_ACCMODE_;
  if (flags & O_CREAT_)
    hostflags |= O_CREAT;
  if (flags & O_EXCL_)
    hostflags |= O_EXCL;
  if (flags & O_TRUNC_)
    hostflags |= O_TRUNC;
  if (flags & O_APPEND_)
    hostflags |= O_APPEND;
  // Linux open ignores file-type bits in mode; BusyBox cp passes st_mode.
  // Keep the confined helper's rejection of special permission bits, while
  // projecting an ordinary file's permissions instead of rejecting its type.
  dsh_file *file = dsh_file_open(b->root, p, strlen(p), hostflags,
                                 mode & ~S_IFMT);
  if (!file)
    return ERR_PTR(errno_map());
  struct fd *f = fd_create(NULL);
  if (!f) {
    dsh_file_close(file);
    return ERR_PTR(_ENOMEM);
  }
  dsh_bound_attach_fd(f, file);
  f->type = S_IFREG;
  return f;
}
static ssize_t read_link(struct mount *m, const char *p, char *b, size_t n) {
  p = relative(p);
  ssize_t r = dsh_root_readlink(context(m)->root, p, strlen(p), b, n);
  return r < 0 ? errno_map() : r;
}
static int mkdir_path(struct mount *m, const char *p, mode_t_ mode) {
  p = relative(p);
  // An empty mount-relative path is the existing capability root.
  if (!*p) return _EEXIST;
  dsh_root *root = context(m)->root;
  struct stat existing;
  // mkdir -p may probe an already existing directory on a readonly mount.
  // This observation creates nothing; absent/non-directory paths stay readonly.
  if (dsh_root_readonly(root) &&
      dsh_root_lstat(root, p, strlen(p), &existing) == 0 && S_ISDIR(existing.st_mode))
    return _EEXIST;
  int r = dsh_directory_make(root, p, strlen(p), mode & ~S_IFMT);
  return r < 0 ? errno_map() : r;
}
static int rmdir_path(struct mount *m, const char *p) {
  p = relative(p);
  int r = dsh_directory_remove(context(m)->root, p, strlen(p));
  return r < 0 ? errno_map() : r;
}
static int unlink_path(struct mount *m, const char *p) {
  p = relative(p);
  int r = dsh_file_unlink(context(m)->root, p, strlen(p));
  return r < 0 ? errno_map() : r;
}
static int rename_path(struct mount *m, const char *a, const char *b) {
  a = relative(a);
  b = relative(b);
  dsh_root *r = context(m)->root;
  int v = dsh_file_rename(r, a, strlen(a), r, b, strlen(b));
  return v < 0 ? errno_map() : v;
}
static int link_path(struct mount *m, const char *a, const char *b) {
  a = relative(a);
  b = relative(b);
  dsh_root *r = context(m)->root;
  int v = dsh_file_link(r, a, strlen(a), r, b, strlen(b));
  return v < 0 ? errno_map() : v;
}
static int symlink_path(struct mount *m, const char *target, const char *link) {
  link = relative(link);
  int result = dsh_file_symlink(context(m)->root, target, strlen(target),
                                 link, strlen(link));
  return result < 0 ? errno_map() : result;
}
static int get_path(struct fd *f, char *out) {
  dsh_root *r = context(f->mount)->root;
  int v = S_ISDIR(f->type)
              ? dsh_directory_relative_path(r, f->data, out, MAX_PATH)
              : dsh_file_relative_path(r, f->data, out, MAX_PATH);
  return v < 0 ? errno_map() : v;
}
static int set_fd(struct fd *f, struct attr a) {
  if (S_ISDIR(f->type)) {
    if (dsh_root_readonly(context(f->mount)->root)) return _EROFS;
    if (a.type != attr_mode) return _ENOTSUP;
    int result = dsh_directory_chmod(f->data, a.mode & ~S_IFMT);
    return result < 0 ? errno_map() : result;
  }
  return dsh_bound_fsetattr(f, a);
}
static int set_path(struct mount *m, const char *p, struct attr a) {
  p = relative(p);
  dsh_root *r = context(m)->root;
  if (dsh_root_readonly(r))
    return _EROFS;
  if (a.type == attr_uid || a.type == attr_gid)
    return _ENOTSUP;
  if (a.type != attr_size && a.type != attr_mode)
    return _EINVAL;
  if (a.type == attr_mode) {
    struct stat st;
    if (dsh_root_lstat(r, p, strlen(p), &st) < 0) return errno_map();
    if (S_ISDIR(st.st_mode)) {
      dsh_directory *directory = dsh_directory_open(r, p, strlen(p));
      if (!directory) return errno_map();
      int result = dsh_directory_chmod(directory, a.mode & ~S_IFMT);
      int error = result < 0 ? errno_map() : result;
      dsh_directory_close(directory);
      return error;
    }
  }
  dsh_file *f = dsh_file_open(r, p, strlen(p),
                              a.type == attr_size ? O_RDWR : O_RDONLY, 0);
  if (!f)
    return errno_map();
  int v = a.type == attr_size   ? dsh_file_truncate(f, a.size)
          : a.type == attr_mode ? dsh_file_chmod(f, a.mode & ~S_IFMT)
                                : -1;
  int result = v < 0 ? errno_map() : v;
  dsh_file_close(f);
  return result;
}
static int stat_fs(struct mount *m, struct statfsbuf *out) {
  struct statvfs s;
  if (dsh_root_statvfs(context(m)->root, &s) < 0)
    return errno_map();
  memset(out, 0, sizeof *out);
  out->type = 0x445348;
  out->bsize = s.f_bsize;
  out->frsize = s.f_frsize;
  out->blocks = s.f_blocks;
  out->bfree = s.f_bfree;
  out->bavail = s.f_bavail;
  out->files = s.f_files;
  out->ffree = s.f_ffree;
  out->namelen = 255;
  out->flags = dsh_root_readonly(context(m)->root) ? 1 : 0;
  return 0;
}
static int times_path(struct mount *m, const char *p,
                       struct timespec atime, struct timespec mtime) {
  dsh_root *root = context(m)->root;
  if (dsh_root_readonly(root)) return _EROFS;
  struct timespec times[2] = {atime, mtime};
  for (size_t i = 0; i < 2; i++) {
    // Linux and Darwin use different sentinel values for utimensat.
    if (times[i].tv_nsec == (1L << 30) - 1) times[i].tv_nsec = UTIME_NOW;
    else if (times[i].tv_nsec == (1L << 30) - 2) times[i].tv_nsec = UTIME_OMIT;
    else if (times[i].tv_nsec < 0 || times[i].tv_nsec >= 1000000000L) return _EINVAL;
  }
  p = relative(p);
  struct stat st;
  if (dsh_root_lstat(root, p, strlen(p), &st) < 0) return errno_map();
  if (S_ISDIR(st.st_mode)) {
    dsh_directory *directory = dsh_directory_open(root, p, strlen(p));
    if (!directory) return errno_map();
    int result = dsh_directory_times(directory, times);
    int error = result < 0 ? errno_map() : result;
    dsh_directory_close(directory);
    return error;
  }
  dsh_file *file = dsh_file_open(root, p, strlen(p), O_RDONLY, 0);
  if (!file) return errno_map();
  int result = dsh_file_times(file, times);
  int error = result < 0 ? errno_map() : result;
  dsh_file_close(file);
  return error;
}
static const struct fs_ops operations = {.name = "dsh-bound",
                                         .magic = 0x445348,
                                         .mount = mount_root,
                                         .umount = unmount_root,
                                         .open = open_path,
                                         .stat = stat_path,
                                         .fstat = stat_fd,
                                         .readlink = read_link,
                                         .mkdir = mkdir_path,
                                         .rmdir = rmdir_path,
                                         .unlink = unlink_path,
                                         .rename = rename_path,
                                         .link = link_path,
                                         .symlink = symlink_path,
                                         .getpath = get_path,
                                         .setattr = set_path,
                                         .fsetattr = set_fd,
                                         .utime = times_path,
                                         .statfs = stat_fs};
int dsh_bound_mount(const char *point, dsh_root *root, uid_t_ uid, uid_t_ gid) {
  if (!point || !root || pending)
    return _EINVAL;
  struct bound_mount *b = malloc(sizeof *b);
  if (!b)
    return _ENOMEM;
  *b = (struct bound_mount){root, uid, gid};
  pending = b;
  int result = do_mount(&operations, "", point, "",
                        dsh_root_readonly(root) ? MS_READONLY_ : 0);
  pending = NULL;
  if (result < 0)
    free(b);
  return result;
}
