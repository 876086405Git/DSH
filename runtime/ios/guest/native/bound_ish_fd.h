#ifndef DSH_IOS_BOUND_ISH_FD_H
#define DSH_IOS_BOUND_ISH_FD_H
#include "bound_file.h"
#include "fs/fd.h"
#include "kernel/fs.h"
// Partial adapter: not registered or sufficient as fs_ops. Ownership of file
// passes to fd.close. No upstream allocator or guest mount is invoked here.
void dsh_bound_attach_fd(struct fd *fd, dsh_file *file);
int dsh_bound_fsetattr(struct fd *fd, struct attr attr);
#endif
