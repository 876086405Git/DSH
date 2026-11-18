#ifndef DSH_IOS_BOUND_ISH_MAPPING_H
#define DSH_IOS_BOUND_ISH_MAPPING_H
#include "bound_file.h"
#include "fs/fd.h"
// Anonymous host backing; caller owns until successful pt_map transfer.
// file_bytes reports the copied prefix; whole pages after it must fault in
// the guest until replaced by a later MAP_FIXED segment.
void *dsh_private_backing(dsh_file *, size_t, off_t, size_t *file_bytes);
int dsh_bound_mmap(struct fd *, struct mem *, page_t, pages_t, off_t, int, int);
#endif
