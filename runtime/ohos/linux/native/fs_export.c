/*
 * An App-owned host directory exported to the guest over virtio-9p (9P2000.L).
 *
 * Replaces TinyEMU's fs_disk in the embedded build. fs_disk keeps a host path
 * string per fid and lets the host resolve it, so a symlink the guest made, or
 * a directory it renamed under an open fid, leads the host anywhere the App can
 * reach. Here every operation resolves its root-relative path again from the
 * export root, one component at a time with O_NOFOLLOW: the guest kernel
 * resolves its own symlinks, the host never follows one. Names are single
 * components; "." and ".." are refused.
 *
 * Every object is reported as owned by the fixed unprivileged guest job
 * identity, so host permission bits apply to it as the owner. Errors keep their
 * Linux errno, which 9P2000.L carries unchanged between these Linux hosts and
 * the riscv64 guest.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#include "cutils.h"
#include "fs.h"
#include "fs_export.h"

#define GUEST_ID 60081

typedef struct {
    FSDevice common;
    int root; /* O_PATH directory of the export */
} FSExport;

struct FSFile {
    char *rel;  /* "" for the export root, else validated names joined by '/' */
    int fd;     /* opened regular file or -1 */
    DIR *dir;   /* opened directory or NULL */
};

static int host_error(void)
{
    return -(errno > 0 && errno < 4096 ? errno : EIO);
}

static BOOL valid_name(const char *name)
{
    return name[0] && strcmp(name, ".") && strcmp(name, "..") && !strchr(name, '/');
}

static char *join(const char *rel, const char *name)
{
    size_t a = strlen(rel), b = strlen(name);
    char *path = malloc(a + b + 2);
    if (!path)
        return NULL;
    memcpy(path, rel, a);
    if (a)
        path[a++] = '/';
    memcpy(path + a, name, b + 1);
    return path;
}

/* The directory at rel, never through a symlink. */
static int open_dir(FSExport *fs, const char *rel)
{
    char *copy = strdup(rel), *save = NULL, *name;
    int fd = openat(fs->root, ".", O_PATH | O_DIRECTORY | O_CLOEXEC);

    if (!copy) {
        if (fd >= 0)
            close(fd);
        errno = ENOMEM;
        return -1;
    }
    for (name = strtok_r(copy, "/", &save); name && fd >= 0; name = strtok_r(NULL, "/", &save)) {
        int next = openat(fd, name, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), error = errno;
        close(fd);
        errno = error;
        fd = next;
    }
    free(copy);
    return fd;
}

/* The directory holding rel and its last name ("." for the root). */
static int open_parent(FSExport *fs, const char *rel, const char **leaf)
{
    const char *slash = strrchr(rel, '/');
    char *parent;
    int fd;

    if (!rel[0]) {
        *leaf = ".";
        return open_dir(fs, "");
    }
    *leaf = slash ? slash + 1 : rel;
    parent = slash ? strndup(rel, slash - rel) : strdup("");
    if (!parent) {
        errno = ENOMEM;
        return -1;
    }
    fd = open_dir(fs, parent);
    free(parent);
    return fd;
}

static void to_qid(FSQID *qid, const struct stat *st)
{
    qid->type = S_ISDIR(st->st_mode) ? P9_QTDIR : S_ISLNK(st->st_mode) ? P9_QTSYMLINK : P9_QTFILE;
    qid->version = 0;
    qid->path = st->st_ino;
}

static int stat_rel(FSExport *fs, const char *rel, struct stat *st)
{
    const char *leaf;
    int fd = open_parent(fs, rel, &leaf), ret;

    if (fd < 0)
        return host_error();
    ret = fstatat(fd, leaf, st, AT_SYMLINK_NOFOLLOW) ? host_error() : 0;
    close(fd);
    return ret;
}

static FSFile *file_new(char *rel)
{
    FSFile *f;
    if (!rel || !(f = mallocz(sizeof(*f)))) {
        free(rel);
        return NULL;
    }
    f->rel = rel;
    f->fd = -1;
    return f;
}

static void ex_close(FSDevice *fs, FSFile *f)
{
    if (f->dir)
        closedir(f->dir);
    else if (f->fd >= 0)
        close(f->fd);
    f->dir = NULL;
    f->fd = -1;
}

static void ex_delete(FSDevice *fs, FSFile *f)
{
    ex_close(fs, f);
    free(f->rel);
    free(f);
}

static void ex_statfs(FSDevice *fs1, FSStatFS *st)
{
    struct statfs st1;
    memset(st, 0, sizeof(*st));
    if (fstatfs(((FSExport *)fs1)->root, &st1) == 0) {
        st->f_bsize = st1.f_bsize;
        st->f_blocks = st1.f_blocks;
        st->f_bfree = st1.f_bfree;
        st->f_bavail = st1.f_bavail;
        st->f_files = st1.f_files;
        st->f_ffree = st1.f_ffree;
    }
}

static int ex_attach(FSDevice *fs1, FSFile **pf, FSQID *qid, uint32_t uid,
                     const char *uname, const char *aname)
{
    struct stat st;
    if (fstat(((FSExport *)fs1)->root, &st))
        return host_error();
    if (!(*pf = file_new(strdup(""))))
        return -ENOMEM;
    to_qid(qid, &st);
    return 0;
}

static int ex_walk(FSDevice *fs1, FSFile **pf, FSQID *qids, FSFile *f, int n, char **names)
{
    char *rel = strdup(f->rel), *next;
    struct stat st;
    int i;

    for (i = 0; rel && i < n; i++) {
        if (!valid_name(names[i]) || !(next = join(rel, names[i])))
            break;
        if (stat_rel((FSExport *)fs1, next, &st)) {
            free(next);
            break;
        }
        free(rel);
        rel = next;
        to_qid(&qids[i], &st);
    }
    *pf = file_new(rel);
    return *pf ? i : -ENOMEM;
}

static int ex_mkdir(FSDevice *fs1, FSQID *qid, FSFile *f, const char *name, uint32_t mode, uint32_t gid)
{
    struct stat st;
    int fd, ret;

    if (!valid_name(name))
        return -EINVAL;
    if ((fd = open_dir((FSExport *)fs1, f->rel)) < 0)
        return host_error();
    ret = mkdirat(fd, name, mode) || fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) ? host_error() : 0;
    close(fd);
    if (!ret)
        to_qid(qid, &st);
    return ret;
}

static const int open_flags[][2] = {
    { P9_O_EXCL, O_EXCL }, { P9_O_TRUNC, O_TRUNC }, { P9_O_APPEND, O_APPEND },
    { P9_O_DSYNC, O_DSYNC }, { P9_O_SYNC, O_SYNC },
};

/* O_NONBLOCK: a FIFO in the export must not stall the VM thread on open. */
static int host_flags(uint32_t flags)
{
    int ret = (flags & P9_O_NOACCESS) | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC;
    size_t i;
    for (i = 0; i < countof(open_flags); i++)
        if (flags & open_flags[i][0])
            ret |= open_flags[i][1];
    return ret;
}

/* A directory is read through DIR; anything else through its fd. */
static int adopt(FSFile *f, int fd, FSQID *qid)
{
    struct stat st;
    if (fstat(fd, &st)) {
        int ret = host_error();
        close(fd);
        return ret;
    }
    if (S_ISDIR(st.st_mode)) {
        if (!(f->dir = fdopendir(fd))) {
            int ret = host_error();
            close(fd);
            return ret;
        }
    } else {
        f->fd = fd;
    }
    to_qid(qid, &st);
    return 0;
}

static int ex_open(FSDevice *fs1, FSQID *qid, FSFile *f, uint32_t flags,
                   FSOpenCompletionFunc *cb, void *opaque)
{
    const char *leaf;
    int parent, fd;

    ex_close(fs1, f);
    if ((parent = open_parent((FSExport *)fs1, f->rel, &leaf)) < 0)
        return host_error();
    fd = openat(parent, leaf, (flags & P9_O_DIRECTORY ? O_RDONLY | O_DIRECTORY : 0) | host_flags(flags));
    if (fd < 0) {
        int ret = host_error();
        close(parent);
        return ret;
    }
    close(parent);
    return adopt(f, fd, qid);
}

static int ex_create(FSDevice *fs1, FSQID *qid, FSFile *f, const char *name,
                     uint32_t flags, uint32_t mode, uint32_t gid)
{
    char *rel;
    int dir, fd, ret;

    if (!valid_name(name))
        return -EINVAL;
    ex_close(fs1, f);
    if ((dir = open_dir((FSExport *)fs1, f->rel)) < 0)
        return host_error();
    fd = openat(dir, name, host_flags(flags) | O_CREAT, mode);
    ret = fd < 0 ? host_error() : 0;
    close(dir);
    if (ret)
        return ret;
    if (!(rel = join(f->rel, name))) {
        close(fd);
        return -ENOMEM;
    }
    free(f->rel);
    f->rel = rel;
    return adopt(f, fd, qid);
}

static int ex_stat(FSDevice *fs1, FSFile *f, FSStat *st)
{
    struct stat st1;
    int ret = stat_rel((FSExport *)fs1, f->rel, &st1);
    if (ret)
        return ret;
    to_qid(&st->qid, &st1);
    st->st_mode = st1.st_mode;
    st->st_uid = GUEST_ID;
    st->st_gid = GUEST_ID;
    st->st_nlink = st1.st_nlink;
    st->st_rdev = st1.st_rdev;
    st->st_size = st1.st_size;
    st->st_blksize = st1.st_blksize;
    st->st_blocks = st1.st_blocks;
    st->st_atime_sec = st1.st_atim.tv_sec;
    st->st_atime_nsec = st1.st_atim.tv_nsec;
    st->st_mtime_sec = st1.st_mtim.tv_sec;
    st->st_mtime_nsec = st1.st_mtim.tv_nsec;
    st->st_ctime_sec = st1.st_ctim.tv_sec;
    st->st_ctime_nsec = st1.st_ctim.tv_nsec;
    return 0;
}

static int set_attributes(int parent, const char *leaf, uint32_t mask, uint32_t mode, uint32_t uid,
                          uint32_t gid, uint64_t size, const struct timespec *times)
{
    struct stat st;

    if (fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW))
        return host_error();
    /* Everything already belongs to the guest identity; no other owner exists. */
    if (((mask & P9_SETATTR_UID) && uid != GUEST_ID) || ((mask & P9_SETATTR_GID) && gid != GUEST_ID))
        return -EPERM;
    if (mask & P9_SETATTR_MODE) {
        if (S_ISLNK(st.st_mode))
            return -EOPNOTSUPP;
        /* Checked and changed on one object: never follows a link swapped in meanwhile. */
        if (fchmodat(parent, leaf, mode, AT_SYMLINK_NOFOLLOW))
            return host_error();
    }
    if (mask & P9_SETATTR_SIZE) {
        int fd = openat(parent, leaf, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC), ret;
        if (fd < 0)
            return host_error();
        ret = ftruncate(fd, size) ? host_error() : 0;
        close(fd);
        if (ret)
            return ret;
    }
    if ((mask & (P9_SETATTR_ATIME | P9_SETATTR_MTIME)) &&
        utimensat(parent, leaf, times, AT_SYMLINK_NOFOLLOW))
        return host_error();
    return 0;
}

static int ex_setattr(FSDevice *fs1, FSFile *f, uint32_t mask, uint32_t mode, uint32_t uid,
                      uint32_t gid, uint64_t size, uint64_t atime_sec, uint64_t atime_nsec,
                      uint64_t mtime_sec, uint64_t mtime_nsec)
{
    struct timespec times[2] = {
        { (mask & P9_SETATTR_ATIME_SET) ? atime_sec : 0,
          !(mask & P9_SETATTR_ATIME) ? UTIME_OMIT : (mask & P9_SETATTR_ATIME_SET) ? (long)atime_nsec : UTIME_NOW },
        { (mask & P9_SETATTR_MTIME_SET) ? mtime_sec : 0,
          !(mask & P9_SETATTR_MTIME) ? UTIME_OMIT : (mask & P9_SETATTR_MTIME_SET) ? (long)mtime_nsec : UTIME_NOW },
    };
    const char *leaf;
    int parent = open_parent((FSExport *)fs1, f->rel, &leaf), ret;

    if (parent < 0)
        return host_error();
    ret = set_attributes(parent, leaf, mask, mode, uid, gid, size, times);
    close(parent);
    return ret;
}

static int ex_readdir(FSDevice *fs, FSFile *f, uint64_t offset, uint8_t *buf, int count)
{
    struct dirent *de;
    int len, pos = 0, name_len, d_type;

    if (!f->dir)
        return -P9_EPROTO;
    if (offset == 0)
        rewinddir(f->dir);
    else
        seekdir(f->dir, offset);
    while ((de = readdir(f->dir))) {
        name_len = strlen(de->d_name);
        len = 13 + 8 + 1 + 2 + name_len;
        if (pos + len > count)
            break;
        offset = telldir(f->dir);
        d_type = de->d_type;
        if (d_type == DT_UNKNOWN) {
            struct stat st;
            d_type = fstatat(dirfd(f->dir), de->d_name, &st, AT_SYMLINK_NOFOLLOW) ? DT_REG : st.st_mode >> 12;
        }
        buf[pos++] = d_type == DT_DIR ? P9_QTDIR : d_type == DT_LNK ? P9_QTSYMLINK : P9_QTFILE;
        put_le32(buf + pos, 0);
        pos += 4;
        put_le64(buf + pos, de->d_ino);
        pos += 8;
        put_le64(buf + pos, offset);
        pos += 8;
        buf[pos++] = d_type;
        put_le16(buf + pos, name_len);
        pos += 2;
        memcpy(buf + pos, de->d_name, name_len);
        pos += name_len;
    }
    return pos;
}

static int ex_read(FSDevice *fs, FSFile *f, uint64_t offset, uint8_t *buf, int count)
{
    ssize_t ret;
    if (f->fd < 0)
        return -P9_EPROTO;
    ret = pread(f->fd, buf, count, offset);
    return ret < 0 ? host_error() : ret;
}

static int ex_write(FSDevice *fs, FSFile *f, uint64_t offset, const uint8_t *buf, int count)
{
    ssize_t ret;
    if (f->fd < 0)
        return -P9_EPROTO;
    ret = pwrite(f->fd, buf, count, offset);
    return ret < 0 ? host_error() : ret;
}

static int ex_link(FSDevice *fs1, FSFile *df, FSFile *f, const char *name)
{
    const char *leaf;
    int from, to, ret;

    if (!valid_name(name))
        return -EINVAL;
    if ((from = open_parent((FSExport *)fs1, f->rel, &leaf)) < 0)
        return host_error();
    if ((to = open_dir((FSExport *)fs1, df->rel)) < 0) {
        ret = host_error();
        close(from);
        return ret;
    }
    ret = linkat(from, leaf, to, name, 0) ? host_error() : 0;
    close(from);
    close(to);
    return ret;
}

static int ex_symlink(FSDevice *fs1, FSQID *qid, FSFile *f, const char *name,
                      const char *target, uint32_t gid)
{
    struct stat st;
    int fd, ret;

    if (!valid_name(name))
        return -EINVAL;
    if ((fd = open_dir((FSExport *)fs1, f->rel)) < 0)
        return host_error();
    ret = symlinkat(target, fd, name) || fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) ? host_error() : 0;
    close(fd);
    if (!ret)
        to_qid(qid, &st);
    return ret;
}

static int ex_mknod(FSDevice *fs1, FSQID *qid, FSFile *f, const char *name, uint32_t mode,
                    uint32_t major, uint32_t minor, uint32_t gid)
{
    struct stat st;
    int fd, ret;

    if (!valid_name(name))
        return -EINVAL;
    if ((fd = open_dir((FSExport *)fs1, f->rel)) < 0)
        return host_error();
    ret = mknodat(fd, name, mode, makedev(major, minor)) || fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) ? host_error() : 0;
    close(fd);
    if (!ret)
        to_qid(qid, &st);
    return ret;
}

static int ex_readlink(FSDevice *fs1, char *buf, int buf_size, FSFile *f)
{
    const char *leaf;
    int fd = open_parent((FSExport *)fs1, f->rel, &leaf);
    ssize_t ret;

    if (fd < 0)
        return host_error();
    ret = readlinkat(fd, leaf, buf, buf_size - 1);
    if (ret < 0) {
        int error = host_error();
        close(fd);
        return error;
    }
    close(fd);
    buf[ret] = '\0';
    return 0;
}

static int ex_renameat(FSDevice *fs1, FSFile *f, const char *name, FSFile *new_f, const char *new_name)
{
    int from, to, ret;

    if (!valid_name(name) || !valid_name(new_name))
        return -EINVAL;
    if ((from = open_dir((FSExport *)fs1, f->rel)) < 0)
        return host_error();
    if ((to = open_dir((FSExport *)fs1, new_f->rel)) < 0) {
        ret = host_error();
        close(from);
        return ret;
    }
    ret = renameat(from, name, to, new_name) ? host_error() : 0;
    close(from);
    close(to);
    return ret;
}

static int ex_unlinkat(FSDevice *fs1, FSFile *f, const char *name)
{
    int fd, ret;

    if (!valid_name(name))
        return -EINVAL;
    if ((fd = open_dir((FSExport *)fs1, f->rel)) < 0)
        return host_error();
    /* Like remove(3): Tunlinkat names files and directories alike. */
    ret = unlinkat(fd, name, 0);
    if (ret && errno == EISDIR)
        ret = unlinkat(fd, name, AT_REMOVEDIR);
    ret = ret ? host_error() : 0;
    close(fd);
    return ret;
}

static int ex_lock(FSDevice *fs, FSFile *f, const FSLock *lock)
{
    struct flock fl = { .l_type = lock->type, .l_whence = SEEK_SET, .l_start = lock->start, .l_len = lock->length };

    if (f->fd < 0)
        return -P9_EPROTO;
    if (fcntl(f->fd, F_SETLK, &fl) == 0)
        return P9_LOCK_SUCCESS;
    return errno == EAGAIN || errno == EACCES ? P9_LOCK_BLOCKED : host_error();
}

static int ex_getlock(FSDevice *fs, FSFile *f, FSLock *lock)
{
    struct flock fl = { .l_type = lock->type, .l_whence = SEEK_SET, .l_start = lock->start, .l_len = lock->length };

    if (f->fd < 0)
        return -P9_EPROTO;
    if (fcntl(f->fd, F_GETLK, &fl) < 0)
        return host_error();
    lock->type = fl.l_type;
    lock->start = fl.l_start;
    lock->length = fl.l_len;
    return 0;
}

static void ex_end(FSDevice *fs1)
{
    close(((FSExport *)fs1)->root);
}

FSDevice *fs_export_init(const char *root_path)
{
    FSExport *fs;
    int root = open(root_path, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);

    if (root < 0 || !(fs = mallocz(sizeof(*fs)))) {
        if (root >= 0)
            close(root);
        return NULL;
    }
    fs->root = root;
    fs->common.fs_end = ex_end;
    fs->common.fs_delete = ex_delete;
    fs->common.fs_statfs = ex_statfs;
    fs->common.fs_attach = ex_attach;
    fs->common.fs_walk = ex_walk;
    fs->common.fs_mkdir = ex_mkdir;
    fs->common.fs_open = ex_open;
    fs->common.fs_create = ex_create;
    fs->common.fs_stat = ex_stat;
    fs->common.fs_setattr = ex_setattr;
    fs->common.fs_close = ex_close;
    fs->common.fs_readdir = ex_readdir;
    fs->common.fs_read = ex_read;
    fs->common.fs_write = ex_write;
    fs->common.fs_link = ex_link;
    fs->common.fs_symlink = ex_symlink;
    fs->common.fs_mknod = ex_mknod;
    fs->common.fs_readlink = ex_readlink;
    fs->common.fs_renameat = ex_renameat;
    fs->common.fs_unlinkat = ex_unlinkat;
    fs->common.fs_lock = ex_lock;
    fs->common.fs_getlock = ex_getlock;
    return (FSDevice *)fs;
}
