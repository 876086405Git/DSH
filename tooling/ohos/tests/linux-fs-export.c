/* Drives the production fs_export FSDevice the way the 9P server does, with the
   escapes a guest can attempt through ordinary file operations. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "cutils.h"
#include "fs.h"
#include "fs_export.h"

static int failures;
static void check(const char *name, int pass, long observed)
{
    printf("{\"case\":\"%s\",\"pass\":%s,\"observed\":%ld}\n", name, pass ? "true" : "false", observed);
    failures += !pass;
}

static FSFile *walk(FSDevice *fs, FSFile *from, int n, char **names, int *walked)
{
    FSFile *f;
    FSQID qids[8];
    *walked = fs->fs_walk(fs, &f, qids, from, n, names);
    return f;
}

int main(int argc, char **argv)
{
    const char *root = argv[1], *outside = argv[2];
    char path[4096], buf[256];
    FSDevice *fs = fs_export_init(root);
    FSFile *top, *f, *g;
    FSQID qid;
    FSStat st;
    int n, ret;

    if (!fs)
        return 2;
    fs->fs_attach(fs, &top, &qid, 0, "", "");
    check("root-is-directory", qid.type == P9_QTDIR, qid.type);

    /* Ordinary use: create, write, read back, stat as the guest identity. */
    f = walk(fs, top, 0, NULL, &n);
    ret = fs->fs_create(fs, &qid, f, "hello.txt", P9_O_RDWR, 0644, 0);
    check("create", ret == 0, ret);
    ret = fs->fs_write(fs, f, 0, (const uint8_t *)"guest\n", 6);
    check("write", ret == 6, ret);
    ret = fs->fs_read(fs, f, 0, (uint8_t *)buf, sizeof(buf));
    check("read-back", ret == 6 && !memcmp(buf, "guest\n", 6), ret);
    ret = fs->fs_stat(fs, f, &st);
    check("guest-owner", ret == 0 && st.st_uid == 60081 && st.st_gid == 60081, st.st_uid);
    ret = fs->fs_setattr(fs, f, P9_SETATTR_UID | P9_SETATTR_GID, 0, 60081, 60081, 0, 0, 0, 0, 0);
    check("chown-to-guest-is-noop", ret == 0, ret);
    ret = fs->fs_setattr(fs, f, P9_SETATTR_UID, 0, 0, 0, 0, 0, 0, 0, 0);
    check("chown-to-root-refused", ret == -EPERM, ret);
    fs->fs_delete(fs, f);
    snprintf(path, sizeof(path), "%s/hello.txt", root);
    check("host-sees-write", access(path, F_OK) == 0, errno);

    /* Names are single components. */
    char *dotdot[] = { ".." }, *slashed[] = { "a/../.." };
    f = walk(fs, top, 1, dotdot, &n);
    check("walk-dotdot-refused", n == 0, n);
    fs->fs_delete(fs, f);
    f = walk(fs, top, 1, slashed, &n);
    check("walk-slash-refused", n == 0, n);
    fs->fs_delete(fs, f);
    ret = fs->fs_mkdir(fs, &qid, top, "..", 0755, 0);
    check("mkdir-dotdot-refused", ret == -EINVAL, ret);

    /* An open fid inside a directory the guest then replaces with a link out. */
    ret = fs->fs_mkdir(fs, &qid, top, "a", 0755, 0);
    char *ab[] = { "a" };
    f = walk(fs, top, 1, ab, &n);
    ret = fs->fs_mkdir(fs, &qid, f, "b", 0755, 0);
    char *abb[] = { "a", "b" };
    g = walk(fs, top, 2, abb, &n);
    check("walk-into-real-directories", n == 2, n);
    ret = fs->fs_renameat(fs, top, "a", top, "a2");
    check("rename-directory", ret == 0, ret);
    ret = fs->fs_symlink(fs, &qid, top, "a", outside, 0);
    check("guest-symlink-to-host-path", ret == 0, ret);
    ret = fs->fs_create(fs, &qid, g, "escaped", P9_O_RDWR, 0644, 0);
    snprintf(path, sizeof(path), "%s/b/escaped", outside);
    check("stale-fid-does-not-follow-link", ret < 0 && access(path, F_OK) != 0, ret);
    fs->fs_delete(fs, g);
    fs->fs_delete(fs, f);

    /* The link itself is never followed by the host. */
    char *link_name[] = { "a" }, *through[] = { "a", "secret" };
    f = walk(fs, top, 1, link_name, &n);
    check("walk-to-link", n == 1, n);
    ret = fs->fs_open(fs, &qid, f, P9_O_RDONLY, NULL, NULL);
    check("open-link-refused", ret == -ELOOP, ret);
    ret = fs->fs_setattr(fs, f, P9_SETATTR_MODE, 0777, 0, 0, 0, 0, 0, 0, 0);
    check("chmod-link-refused", ret < 0, ret);
    ret = fs->fs_readlink(fs, buf, sizeof(buf), f);
    check("readlink-is-guest-data", ret == 0 && !strcmp(buf, outside), ret);
    fs->fs_delete(fs, f);
    f = walk(fs, top, 2, through, &n);
    check("walk-through-link-stops", n == 1, n);
    fs->fs_delete(fs, f);
    snprintf(path, sizeof(path), "%s/secret", outside);
    struct stat host;
    stat(path, &host);
    check("outside-mode-unchanged", (host.st_mode & 0777) == 0600, host.st_mode & 0777);

    /* A FIFO must not stall the VM thread. */
    ret = fs->fs_mknod(fs, &qid, top, "fifo", S_IFIFO | 0600, 0, 0, 0);
    char *fifo[] = { "fifo" };
    f = walk(fs, top, 1, fifo, &n);
    ret = fs->fs_open(fs, &qid, f, P9_O_RDONLY, NULL, NULL);
    check("fifo-open-does-not-block", ret == 0, ret);
    fs->fs_delete(fs, f);

    /* Directory listing and removal through the export. */
    f = walk(fs, top, 0, NULL, &n);
    ret = fs->fs_open(fs, &qid, f, P9_O_RDONLY | P9_O_DIRECTORY, NULL, NULL);
    uint8_t list[4096];
    ret = fs->fs_readdir(fs, f, 0, list, sizeof(list));
    check("readdir", ret > 0 && memmem(list, ret, "hello.txt", 9) != NULL, ret);
    fs->fs_delete(fs, f);
    ret = fs->fs_unlinkat(fs, top, "a2/b");
    check("unlink-path-refused", ret == -EINVAL, ret);
    char *a2[] = { "a2" };
    f = walk(fs, top, 1, a2, &n);
    ret = fs->fs_unlinkat(fs, f, "b");
    check("rmdir", ret == 0, ret);
    fs->fs_delete(fs, f);
    ret = fs->fs_unlinkat(fs, top, "hello.txt");
    check("unlink", ret == 0, ret);
    return failures ? 1 : 0;
}
