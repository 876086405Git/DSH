#ifndef DSH_IOS_BOUND_ISH_DIRECTORY_H
#define DSH_IOS_BOUND_ISH_DIRECTORY_H
#include "bound_file.h"
#include "fs/fd.h"
// Takes ownership. Caller initializes lock/refcount/mount according to upstream
// fd_create.
void dsh_bound_attach_directory(struct fd *, dsh_directory *);
#endif
