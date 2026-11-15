#ifndef DSH_IOS_BOUND_PARENT_H
#define DSH_IOS_BOUND_PARENT_H
#include <stddef.h>
// A narrow building block, NOT a filesystem or a complete isolation capability.
// root_fd must be a trusted, owned directory FD. No strings choose a host root.
// On success caller owns *parent_fd; leaf is a single validated component.
int dsh_bound_parent(int root_fd, const char *path, size_t length,
                     int *parent_fd, char *leaf, size_t leaf_capacity);
#endif
