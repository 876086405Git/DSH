#include "bound_ish_fd.h"
#include "bound_ish_mapping.h"
#include "kernel/errno.h"
static ssize_t converted(ssize_t result) {
  return result < 0 ? errno_map() : result;
}
static ssize_t read_file(struct fd *f, void *b, size_t n) {
  return converted(dsh_file_read(f->data, b, n));
}
static ssize_t pread_file(struct fd *f, void *b, size_t n, off_t o) {
  return converted(dsh_file_pread(f->data, b, n, o));
}
static ssize_t write_file(struct fd *f, const void *b, size_t n) {
  return converted(dsh_file_write(f->data, b, n));
}
static ssize_t pwrite_file(struct fd *f, const void *b, size_t n, off_t o) {
  return converted(dsh_file_pwrite(f->data, b, n, o));
}
static off_t_ seek_file(struct fd *f, off_t_ o, int w) {
  off_t r = dsh_file_seek(f->data, o, w);
  return r < 0 ? errno_map() : r;
}
static int sync_file(struct fd *f) { return converted(dsh_file_sync(f->data)); }
static int close_file(struct fd *f) {
  dsh_file_close(f->data);
  f->data = NULL;
  return 0;
}
static ssize_t no_ioctl_size(int cmd) {
  (void)cmd;
  return -1;
}
static int no_ioctl(struct fd *f, int cmd, void *a) {
  (void)f;
  (void)cmd;
  (void)a;
  return _ENOTTY;
}
static int no_setflags(struct fd *f, dword_t flags) {
  (void)f;
  (void)flags;
  return _ENOTSUP;
}
static const struct fd_ops operations = {.read = read_file,
                                         .pread = pread_file,
                                         .write = write_file,
                                         .pwrite = pwrite_file,
                                         .lseek = seek_file,
                                         .fsync = sync_file,
                                         .close = close_file,
                                         .mmap = dsh_bound_mmap,
                                         .ioctl_size = no_ioctl_size,
                                         .ioctl = no_ioctl,
                                         .setflags = no_setflags};
void dsh_bound_attach_fd(struct fd *f, dsh_file *file) {
  f->data = file;
  f->real_fd = -1;
  f->ops = &operations;
}
int dsh_bound_fsetattr(struct fd *f, struct attr a) {
  int result;
  switch (a.type) {
  case attr_size:
    result = dsh_file_truncate(f->data, a.size);
    break;
  case attr_mode:
    result = dsh_file_chmod(f->data, a.mode & ~S_IFMT);
    break;
  // Guest uid/gid are virtual metadata, not host chown arguments.
  case attr_uid:
  case attr_gid:
    return dsh_file_readonly(f->data) ? _EROFS : _ENOTSUP;
  default:
    return _EINVAL;
  }
  return converted(result);
}
