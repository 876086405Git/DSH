#ifndef DSH_IOS_BOUND_ISH_FS_H
#define DSH_IOS_BOUND_ISH_FS_H
#include "bound_file.h"
#include "kernel/fs.h"
// Trusted App initialization only, before guest tasks run. Ownership transfers
// on success. Caller validates roots do not overlap .dsh/App state and chooses
// strict/image constructor. Fixed projected guest UID/GID are supplied, never
// copied from host ownership.
int dsh_bound_mount(const char *point, dsh_root *root, uid_t_ uid, uid_t_ gid);
#endif
