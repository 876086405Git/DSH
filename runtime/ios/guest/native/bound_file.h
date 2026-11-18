#ifndef DSH_IOS_BOUND_FILE_H
#define DSH_IOS_BOUND_FILE_H
#include <stdbool.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <time.h>
typedef struct dsh_root dsh_root;
typedef struct dsh_file dsh_file;
dsh_root *dsh_root_new(int trusted_root_fd, bool readonly);
// Workspace/temp policy: reject multi-link ordinary files and guest hardlink
// creation. Trusted immutable image roots may use the original constructor
// after manifest validation.
dsh_root *dsh_root_new_workspace(int trusted_root_fd, bool readonly);
void dsh_root_free(dsh_root *root);
dsh_file *dsh_file_open(dsh_root *, const char *, size_t, int flags, mode_t);
bool dsh_file_readonly(const dsh_file *);
void dsh_file_close(dsh_file *);
dsh_file *dsh_file_dup(dsh_file *);
ssize_t dsh_file_read(dsh_file *, void *, size_t);
ssize_t dsh_file_pread(dsh_file *, void *, size_t, off_t);
ssize_t dsh_file_write(dsh_file *, const void *, size_t);
ssize_t dsh_file_pwrite(dsh_file *, const void *, size_t, off_t);
off_t dsh_file_seek(dsh_file *, off_t, int);
int dsh_file_stat(dsh_file *, struct stat *);
int dsh_file_truncate(dsh_file *, off_t);
int dsh_file_chmod(dsh_file *, mode_t);
int dsh_file_chown(dsh_file *, uid_t, gid_t);
int dsh_file_times(dsh_file *, const struct timespec[2]);
int dsh_file_sync(dsh_file *);
void *dsh_file_map_private(dsh_file *, size_t, int prot, int flags, off_t);
int dsh_file_rename(dsh_root *, const char *, size_t, dsh_root *, const char *,
                    size_t);
int dsh_file_link(dsh_root *, const char *, size_t, dsh_root *, const char *,
                  size_t);
// Creates relative link text with no .. component at a bound destination.
// Existing destinations are never replaced; later resolution belongs to guest
// VFS (pre-existing links/rename can change its target).
int dsh_file_symlink(dsh_root *, const char *target, size_t target_length,
                     const char *link, size_t link_length);
int dsh_file_unlink(dsh_root *, const char *, size_t);
typedef struct dsh_directory dsh_directory;
// Empty relative path denotes this capability root; other paths use
// bound_parent.
dsh_directory *dsh_directory_open(dsh_root *, const char *, size_t);
void dsh_directory_close(dsh_directory *);
// 1 entry, 0 EOF, -1 error; copies name (never returns host dirent storage).
int dsh_directory_next(dsh_directory *, char *, size_t, ino_t *);
int dsh_directory_rewind(dsh_directory *);
long dsh_directory_tell(dsh_directory *);
void dsh_directory_seek(dsh_directory *, long);
int dsh_directory_stat(dsh_directory *, struct stat *);
int dsh_directory_chmod(dsh_directory *, mode_t);
int dsh_directory_times(dsh_directory *, const struct timespec[2]);
int dsh_directory_make(dsh_root *, const char *, size_t, mode_t);
int dsh_directory_remove(dsh_root *, const char *, size_t);
// lstat-style leaf only; never follows a host symlink.
int dsh_root_lstat(dsh_root *, const char *, size_t, struct stat *);
ssize_t dsh_root_readlink(dsh_root *, const char *, size_t, char *, size_t);
bool dsh_root_readonly(dsh_root *);
int dsh_root_statvfs(dsh_root *, struct statvfs *);
int dsh_file_relative_path(dsh_root *, dsh_file *, char *, size_t);
int dsh_directory_relative_path(dsh_root *, dsh_directory *, char *, size_t);
#endif
