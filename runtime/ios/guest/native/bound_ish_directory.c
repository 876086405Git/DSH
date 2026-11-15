#include "bound_ish_directory.h"
#include "kernel/errno.h"
static int next(struct fd *f, struct dir_entry *entry) {
  ino_t inode;
  int r = dsh_directory_next(f->data, entry->name, sizeof entry->name, &inode);
  if (r < 0)
    return errno_map();
  if (r)
    entry->inode = inode;
  return r;
}
static unsigned long tell(struct fd *f) { return dsh_directory_tell(f->data); }
static void seek(struct fd *f, unsigned long position) {
  dsh_directory_seek(f->data, position);
}
static int close_dir(struct fd *f) {
  dsh_directory_close(f->data);
  f->data = NULL;
  return 0;
}
static ssize_t no_read(struct fd *f, void *b, size_t n) {
  (void)f;
  (void)b;
  (void)n;
  return _EISDIR;
}
static ssize_t no_write(struct fd *f, const void *b, size_t n) {
  (void)f;
  (void)b;
  (void)n;
  return _EISDIR;
}
static int no_map(struct fd *f, struct mem *m, page_t s, pages_t n, off_t o,
                  int p, int flags) {
  (void)f;
  (void)m;
  (void)s;
  (void)n;
  (void)o;
  (void)p;
  (void)flags;
  return _ENOTSUP;
}
static ssize_t no_ioctl_size(int c) {
  (void)c;
  return -1;
}
static int no_ioctl(struct fd *f, int c, void *a) {
  (void)f;
  (void)c;
  (void)a;
  return _ENOTTY;
}
static int no_flags(struct fd *f, dword_t v) {
  (void)f;
  (void)v;
  return _ENOTSUP;
}
static const struct fd_ops operations = {.read = no_read,
                                         .write = no_write,
                                         .readdir = next,
                                         .telldir = tell,
                                         .seekdir = seek,
                                         .close = close_dir,
                                         .mmap = no_map,
                                         .ioctl_size = no_ioctl_size,
                                         .ioctl = no_ioctl,
                                         .setflags = no_flags};
void dsh_bound_attach_directory(struct fd *f, dsh_directory *d) {
  f->data = d;
  f->ops = &operations;
  f->real_fd = -1;
  f->type = S_IFDIR;
}
