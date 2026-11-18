#ifndef DSH_FS_EXPORT_H
#define DSH_FS_EXPORT_H

/* An App-owned host directory as a 9P2000.L export; NULL if it cannot be opened.
   fs.h has no include guard, so this header names only the struct. */
struct FSDevice *fs_export_init(const char *root_path);

#endif
