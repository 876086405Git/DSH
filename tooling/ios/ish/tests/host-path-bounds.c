/* Patched-source host regression. No iSH kernel, host directory, device, or
 * network operation runs here. The Python driver extracts complete production
 * functions into the included header; every external effect has an adapter. */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#if !defined(__linux__)
#error This fixture exercises the Linux branch, not an Apple execution.
#endif
#if TEST_PATH_MAX != 1024 && TEST_PATH_MAX != 4096
#error Unsupported synthetic host capacity.
#endif
#undef PATH_MAX
#define PATH_MAX TEST_PATH_MAX
/* These values are checked against the freshly patched pinned headers. */
#define MAX_PATH 4096
#define _ENOENT (-2)
#define _EIO (-5)
#define _EACCES (-13)
#define _ENOTDIR (-20)
#define _EINVAL (-22)
#define _ENAMETOOLONG (-36)
#define _ELOOP (-40)
#define N_SYMLINK_FOLLOW 1
#define N_SYMLINK_NOFOLLOW 2
#define AC_X 1

static const char *case_name;
static unsigned cases;
#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "FAIL %s:%d [%s]: %s\n", __FILE__, __LINE__, case_name, #expr); \
    exit(1); \
} } while (0)

struct fakefs_db { int unused; };
struct mount;
struct fd;
struct dir_entry { uint64_t inode; char name[256]; };
struct statbuf { mode_t mode; };
struct fd_ops { int (*readdir)(struct fd *, struct dir_entry *); };
struct fs_ops {
    int (*mount)(struct mount *);
    ssize_t (*readlink)(struct mount *, const char *, char *, size_t);
    int (*stat)(struct mount *, const char *, struct statbuf *);
};
struct mount {
    const char *source;
    int root_fd;
    struct fakefs_db fakefs;
    const struct fs_ops *fs;
};
struct fd { const struct fd_ops *ops; struct mount *mount; int real_fd; };
static struct fd_ops fakefs_fdops;
static struct mount *g_fakefs_mount;
static unsigned char g_bind_mounts[32];
static int ish_verbose_trace_enabled;

struct dir_step {
    int result;
    const char *name, *path;
    int path_error;
    uint64_t host_inode, db_inode, ensured_inode;
    bool via_hook, under_bind;
};
static struct {
    int mount_calls, mount_error, db_init_calls, db_init_error;
    char db_path[PATH_MAX];
    struct dir_step steps[4];
    size_t step_count, next_step;
    struct dir_step *current;
    int readdir_calls, getpath_calls, translate_calls, begin_calls, commit_calls;
    int inode_calls, under_bind_calls, ensure_calls, concat_calls;
    char inode_paths[4][MAX_PATH + 1];
    char translated_path[MAX_PATH + 1];
    int readlink_calls;
    size_t readlink_capacity;
    const char *readlink_reply;
    int readlink_error;
    char proc_path[128];
    const char *link_at, *link_target;
    bool link_fills_capacity;
    int find_calls, release_calls, live_mounts, symlink_reads, stat_calls;
    int access_calls, access_error;
    mode_t stat_mode;
    size_t link_capacity;
} trace;

static void copy_text(char *out, size_t capacity, const char *text) {
    size_t length = strlen(text);
    CHECK(length < capacity);
    memcpy(out, text, length + 1);
}
static void start_case(const char *name) {
    case_name = name;
    ++cases;
    memset(&trace, 0, sizeof trace);
    trace.stat_mode = S_IFDIR | 0755;
    g_fakefs_mount = NULL;
    memset(g_bind_mounts, 0x55, sizeof g_bind_mounts);
}
static int recorded_mount(struct mount *mount) {
    ++trace.mount_calls;
    mount->root_fd = 73;
    return trace.mount_error;
}
static int fake_db_init(struct fakefs_db *db, const char *path, int root_fd) {
    (void)db;
    CHECK(trace.mount_calls == 1 && root_fd == 73);
    ++trace.db_init_calls;
    copy_text(trace.db_path, sizeof trace.db_path, path);
    return trace.db_init_error;
}
static int recorded_readdir(struct fd *fd, struct dir_entry *entry) {
    (void)fd;
    ++trace.readdir_calls;
    CHECK(trace.next_step < trace.step_count);
    trace.current = &trace.steps[trace.next_step++];
    if (trace.current->result > 0) {
        copy_text(entry->name, sizeof entry->name, trace.current->name);
        entry->inode = trace.current->host_inode;
    }
    return trace.current->result;
}
static int realfs_getpath(struct fd *fd, char *path) {
    (void)fd;
    ++trace.getpath_calls;
    copy_text(path, MAX_PATH, trace.current->path);
    return trace.current->path_error;
}
static bool bind_mount_translate_path_ex(const char *path, char *out,
                                         size_t capacity, bool *via_hook) {
    (void)out;
    CHECK(capacity == PATH_MAX);
    ++trace.translate_calls;
    copy_text(trace.translated_path, sizeof trace.translated_path, path);
    *via_hook = trace.current->via_hook;
    return *via_hook;
}
static void db_begin_read(struct fakefs_db *db) {
    (void)db;
    CHECK(trace.begin_calls == trace.commit_calls);
    ++trace.begin_calls;
}
static uint64_t path_get_inode(struct fakefs_db *db, const char *path) {
    (void)db;
    CHECK(trace.begin_calls == trace.commit_calls + 1);
    CHECK(trace.inode_calls < 4);
    copy_text(trace.inode_paths[trace.inode_calls++], MAX_PATH + 1, path);
    return trace.current->db_inode;
}
static void db_commit(struct fakefs_db *db) {
    (void)db;
    CHECK(trace.begin_calls == trace.commit_calls + 1);
    ++trace.commit_calls;
}
static bool is_under_bind_mount(const char *path) {
    CHECK(strcmp(path, trace.translated_path) == 0);
    ++trace.under_bind_calls;
    return trace.current->under_bind;
}
static uint64_t bind_mount_ensure_inode(struct fakefs_db *db, struct mount *mount,
                                        const char *path) {
    (void)db; (void)mount;
    CHECK(strcmp(path, trace.translated_path) == 0);
    ++trace.ensure_calls;
    return trace.current->ensured_inode;
}
static char *recorded_strcat(char *out, const char *suffix) {
    ++trace.concat_calls;
    return strcat(out, suffix);
}
static ssize_t recorded_readlink(const char *path, char *out, size_t capacity) {
    ++trace.readlink_calls;
    trace.readlink_capacity = capacity;
    copy_text(trace.proc_path, sizeof trace.proc_path, path);
    if (trace.readlink_error) { errno = EIO; return -1; }
    size_t length = strlen(trace.readlink_reply);
    CHECK(length <= capacity);
    memcpy(out, trace.readlink_reply, length); /* readlink does not append NUL. */
    return (ssize_t)length;
}
static ssize_t recorded_symlink(struct mount *mount, const char *path,
                                char *out, size_t capacity);
static int recorded_stat(struct mount *mount, const char *path, struct statbuf *stat);
static const struct fs_ops path_ops = {.readlink = recorded_symlink, .stat = recorded_stat};
static struct mount path_mount = {.source = "", .fs = &path_ops};
static struct mount *find_mount_and_trim_path(char *path) {
    CHECK(path[0] == '/' || path[0] == '\0');
    ++trace.find_calls;
    CHECK(trace.live_mounts++ == 0);
    return &path_mount; /* Root-mounted adapter: no prefix needs trimming. */
}
static void mount_release(struct mount *mount) {
    CHECK(mount == &path_mount && trace.live_mounts-- == 1);
    ++trace.release_calls;
}
static ssize_t recorded_symlink(struct mount *mount, const char *path,
                                char *out, size_t capacity) {
    CHECK(mount == &path_mount);
    ++trace.symlink_reads;
    if (!trace.link_at || strcmp(path, trace.link_at) != 0) return _EINVAL;
    trace.link_capacity = capacity;
    if (trace.link_fills_capacity) {
        memset(out, 't', capacity); /* Every supplied byte is valid; no NUL. */
        return (ssize_t)capacity;
    }
    size_t length = strlen(trace.link_target);
    CHECK(length <= capacity);
    memcpy(out, trace.link_target, length);
    return (ssize_t)length;
}
static int recorded_stat(struct mount *mount, const char *path, struct statbuf *stat) {
    (void)path;
    CHECK(mount == &path_mount);
    ++trace.stat_calls;
    stat->mode = trace.stat_mode;
    return 0;
}
static int access_check(const struct statbuf *stat, int flags) {
    CHECK(stat->mode == trace.stat_mode && flags == AC_X);
    ++trace.access_calls;
    return trace.access_error;
}
static const struct fd_ops realfs_fdops = {.readdir = recorded_readdir};
static const struct fs_ops realfs = {.mount = recorded_mount};

/* The generated header redirects libc readlink only around getpath, so the
 * fs_ops.readlink callback retains its original member name. strcat records
 * whether guarded concatenations were reached. Function bytes stay verbatim. */
#define strcat recorded_strcat
#include "patched-host-path-functions.h"
#undef strcat

static void make_path(char *out, size_t length) {
    CHECK(length > 0 && length < MAX_PATH);
    memset(out, 'd', length);
    out[0] = '/';
    for (size_t i = 32; i + 1 < length; i += 32) out[i] = '/';
    out[length] = '\0';
}
static void add_entry(const char *name, const char *path, uint64_t inode) {
    CHECK(trace.step_count < 4);
    trace.steps[trace.step_count++] = (struct dir_step){
        .result = 1, .name = name, .path = path, .host_inode = 17, .db_inode = inode};
}
static void no_directory_followup(void) {
    CHECK(trace.translate_calls == 0 && trace.begin_calls == 0);
    CHECK(trace.commit_calls == 0 && trace.inode_calls == 0);
    CHECK(trace.under_bind_calls == 0 && trace.ensure_calls == 0);
    CHECK(trace.concat_calls == 0);
}
static void test_mount(void) {
    const char *invalid[] = {"data", "", "/fixture/root/other", "/fixture/root/data/",
                             "/fixture/root/", "/fixture/root/database"};
    for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; ++i) {
        start_case("mount rejects malformed final component");
        struct mount mount = {.source = invalid[i]};
        CHECK(fakefs_mount(&mount) == _EINVAL);
        CHECK(trace.mount_calls == 0 && trace.db_init_calls == 0);
        CHECK(g_fakefs_mount == NULL && g_bind_mounts[0] == 0x55);
    }
    start_case("mount normal path");
    struct mount mount = {.source = "/fixture/root/data"};
    CHECK(fakefs_mount(&mount) == 0);
    CHECK(trace.mount_calls == 1 && trace.db_init_calls == 1);
    CHECK(strcmp(trace.db_path, "/fixture/root/meta.db") == 0);
    CHECK(g_fakefs_mount == &mount);
    for (size_t i = 0; i < sizeof g_bind_mounts; ++i) CHECK(g_bind_mounts[i] == 0);

    /* Independent table: prefix includes its trailing slash; "meta.db" plus
     * NUL is 8 bytes. These inputs are strings, not real deep directories. */
    size_t exact_prefix = PATH_MAX == 1024 ? 1016 : 4088;
    for (size_t over = 0; over < 2; ++over) {
        start_case(over ? "mount metadata exceeds capacity" : "mount metadata exactly fits");
        char source[PATH_MAX], expected[PATH_MAX];
        size_t prefix = exact_prefix + over;
        memset(source, 'm', prefix);
        source[0] = '/'; source[prefix - 1] = '/';
        memcpy(source + prefix, "data", 5);
        mount = (struct mount){.source = source};
        int result = fakefs_mount(&mount);
        if (over) {
            CHECK(result == _ENAMETOOLONG);
            CHECK(trace.mount_calls == 0 && trace.db_init_calls == 0);
            CHECK(g_fakefs_mount == NULL && g_bind_mounts[0] == 0x55);
        } else {
            memcpy(expected, source, prefix);
            memcpy(expected + prefix, "meta.db", 8);
            CHECK(result == 0 && trace.mount_calls == 1 && trace.db_init_calls == 1);
            CHECK(strlen(trace.db_path) == PATH_MAX - 1);
            CHECK(memcmp(trace.db_path, expected, PATH_MAX) == 0);
        }
    }
    start_case("mount underlying error");
    mount = (struct mount){.source = "/fixture/root/data"};
    trace.mount_error = _EIO;
    CHECK(fakefs_mount(&mount) == _EIO);
    CHECK(trace.mount_calls == 1 && trace.db_init_calls == 0 && g_fakefs_mount == NULL);
    start_case("mount metadata error");
    trace.db_init_error = _EACCES;
    CHECK(fakefs_mount(&mount) == _EACCES);
    CHECK(trace.mount_calls == 1 && trace.db_init_calls == 1 && g_fakefs_mount == NULL);
}
static void test_readdir(void) {
    struct mount mount = {.source = "/fixture/root/data"};
    struct fd fd = {.ops = &fakefs_fdops, .mount = &mount};
    struct dir_entry entry;
    start_case("readdir keeps success 1 after getpath returns 0");
    add_entry("leaf", "/parent", 91);
    CHECK(fakefs_readdir(&fd, &entry) == 1 && entry.inode == 91);
    CHECK(strcmp(trace.inode_paths[0], "/parent/leaf") == 0);
    CHECK(trace.concat_calls == 2 && trace.getpath_calls == 1);
    CHECK(trace.begin_calls == 1 && trace.commit_calls == 1);

    const int terminal[] = {0, _EIO};
    for (size_t i = 0; i < 2; ++i) {
        start_case(i ? "readdir underlying error" : "readdir EOF");
        trace.steps[trace.step_count++] = (struct dir_step){.result = terminal[i]};
        CHECK(fakefs_readdir(&fd, &entry) == terminal[i]);
        CHECK(trace.readdir_calls == 1 && trace.getpath_calls == 0);
        no_directory_followup();
    }
    const int path_errors[] = {-1, _EIO};
    for (size_t i = 0; i < 2; ++i) {
        start_case("getpath error stops concatenation and metadata lookup");
        add_entry("leaf", "/discarded", 91);
        trace.steps[0].path_error = path_errors[i];
        CHECK(fakefs_readdir(&fd, &entry) == path_errors[i]);
        CHECK(trace.readdir_calls == 1 && trace.getpath_calls == 1);
        CHECK(entry.inode == 17);
        no_directory_followup();
    }
    const struct {size_t directory, name; int result;} limits[] = {
        {4094, 1, 1}, {4095, 1, _ENAMETOOLONG},
        {3840, 255, 1}, {3841, 255, _ENAMETOOLONG}};
    for (size_t i = 0; i < 4; ++i) {
        start_case("readdir complete directory/name capacity");
        char path[MAX_PATH], name[256], expected[MAX_PATH + 1];
        make_path(path, limits[i].directory);
        memset(name, 'f', limits[i].name); name[limits[i].name] = '\0';
        add_entry(name, path, 91);
        CHECK(fakefs_readdir(&fd, &entry) == limits[i].result);
        if (limits[i].result < 0) {
            no_directory_followup();
        } else {
            memcpy(expected, path, limits[i].directory);
            expected[limits[i].directory] = '/';
            memcpy(expected + limits[i].directory + 1, name, limits[i].name + 1);
            CHECK(strlen(trace.inode_paths[0]) == 4096);
            CHECK(strcmp(trace.inode_paths[0], expected) == 0 && entry.inode == 91);
            CHECK(trace.begin_calls == 1 && trace.commit_calls == 1);
        }
    }
    const struct {const char *name, *path, *expected;} dots[] = {
        {".", "/one/two", "/one/two"}, {"..", "/one/two", "/one"},
        {".", "", ""}, {"..", "", ""}};
    for (size_t i = 0; i < 4; ++i) {
        start_case("readdir dot or dotdot");
        add_entry(dots[i].name, dots[i].path, 91);
        CHECK(fakefs_readdir(&fd, &entry) == 1);
        CHECK(strcmp(trace.inode_paths[0], dots[i].expected) == 0);
        CHECK(trace.concat_calls == 0 && trace.inode_calls == 1);
    }
    start_case("hook entry keeps host inode and success 1");
    add_entry("leaf", "/hook", 0); trace.steps[0].via_hook = true;
    CHECK(fakefs_readdir(&fd, &entry) == 1 && entry.inode == 17);
    CHECK(trace.translate_calls == 1 && trace.inode_calls == 0 && trace.begin_calls == 0);

    start_case("metadata miss retries next entry");
    add_entry("missing", "/parent", 0); add_entry("visible", "/parent", 92);
    CHECK(fakefs_readdir(&fd, &entry) == 1 && entry.inode == 92);
    CHECK(strcmp(entry.name, "visible") == 0);
    CHECK(trace.readdir_calls == 2 && trace.getpath_calls == 2);
    CHECK(trace.begin_calls == 2 && trace.commit_calls == 2);
    CHECK(strcmp(trace.inode_paths[0], "/parent/missing") == 0);
    CHECK(strcmp(trace.inode_paths[1], "/parent/visible") == 0);
    start_case("metadata miss followed by EOF");
    add_entry("missing", "/parent", 0);
    trace.steps[trace.step_count++] = (struct dir_step){.result = 0};
    CHECK(fakefs_readdir(&fd, &entry) == 0);
    CHECK(trace.readdir_calls == 2 && trace.getpath_calls == 1 && trace.inode_calls == 1);
    start_case("bind metadata is supplied after database miss");
    add_entry("leaf", "/bound", 0);
    trace.steps[0].under_bind = true; trace.steps[0].ensured_inode = 93;
    CHECK(fakefs_readdir(&fd, &entry) == 1 && entry.inode == 93);
    CHECK(trace.ensure_calls == 1 && trace.readdir_calls == 1);
    start_case("bind metadata miss retries next entry");
    add_entry("missing", "/bound", 0); trace.steps[0].under_bind = true;
    add_entry("visible", "/bound", 94);
    CHECK(fakefs_readdir(&fd, &entry) == 1 && entry.inode == 94);
    CHECK(trace.ensure_calls == 1 && trace.readdir_calls == 2 && trace.inode_calls == 2);
}
static void test_linux_fd(void) {
    const struct {int fd; const char *expected;} descriptors[] = {
        {0, "/proc/self/fd/0"}, {INT_MAX, "/proc/self/fd/2147483647"}};
    CHECK(INT_MAX == 2147483647);
    for (size_t i = 0; i < 2; ++i) {
        start_case("Linux descriptor spelling uses readlink adapter only");
        char out[MAX_PATH]; memset(out, 'z', sizeof out);
        trace.readlink_reply = "/recorded/path";
        CHECK(getpath(descriptors[i].fd, out) == 14);
        CHECK(strcmp(trace.proc_path, descriptors[i].expected) == 0);
        CHECK(trace.readlink_calls == 1 && trace.readlink_capacity == 4095);
        CHECK(strcmp(out, "/recorded/path") == 0 && out[15] == 'z');
    }
    start_case("Linux readlink error is returned");
    char out[MAX_PATH]; memset(out, 'z', sizeof out);
    trace.readlink_error = 1;
    CHECK(getpath(INT_MAX, out) == -1);
    CHECK(strcmp(trace.proc_path, "/proc/self/fd/2147483647") == 0 && out[0] == 'z');
}
struct guarded_path {unsigned char before[16]; char text[MAX_PATH]; unsigned char after[16];};
static int normalize(const char *input, int flags, int levels, struct guarded_path *out) {
    memset(out, 0x6a, sizeof *out);
    int result = __path_normalize(NULL, input, out->text, flags, levels);
    for (size_t i = 0; i < 16; ++i) CHECK(out->before[i] == 0x6a && out->after[i] == 0x6a);
    CHECK(trace.find_calls == trace.release_calls && trace.live_mounts == 0);
    return result;
}
static void padded_target(char *out, size_t length, const char *head) {
    size_t prefix = strlen(head);
    CHECK(prefix <= length && length < MAX_PATH);
    memcpy(out, head, prefix);
    memset(out + prefix, '/', length - prefix); out[length] = '\0';
}
static void test_normalize(void) {
    struct guarded_path out;
    start_case("normal relative symlink");
    trace.link_at = "/base/link"; trace.link_target = "target";
    CHECK(normalize("/base/link/child", N_SYMLINK_FOLLOW, 0, &out) == 0);
    CHECK(strcmp(out.text, "/base/target/child") == 0);
    CHECK(trace.release_calls == 5 && trace.stat_calls == 3);
    start_case("normal absolute symlink");
    trace.link_at = "/base/link"; trace.link_target = "/dest";
    CHECK(normalize("/base/link/child", N_SYMLINK_FOLLOW, 0, &out) == 0);
    CHECK(strcmp(out.text, "/dest/child") == 0 && trace.release_calls == 4);
    start_case("nofollow terminal symlink");
    trace.link_at = "/link"; trace.link_target = "/dest";
    CHECK(normalize("/link", N_SYMLINK_NOFOLLOW, 0, &out) == 0);
    CHECK(strcmp(out.text, "/link") == 0 && trace.release_calls == 0);

    const struct {const char *input; size_t capacity; int releases;} full[] = {
        {"/link", 4095, 1}, {"/base/link", 4090, 2}};
    for (size_t i = 0; i < 2; ++i) {
        start_case("readlink fills exactly the offered capacity");
        trace.link_at = full[i].input; trace.link_fills_capacity = true;
        CHECK(normalize(full[i].input, N_SYMLINK_FOLLOW, 0, &out) == _ENAMETOOLONG);
        CHECK(trace.link_capacity == full[i].capacity && trace.release_calls == full[i].releases);
        CHECK(trace.concat_calls == 0);
    }
    /* Expanded path is 4095 bytes + NUL at exact fit, 4096 + NUL when
     * over. Repeated separators normalize down, isolating the append gate
     * from the component walk's existing conservative length boundary. */
    const struct {const char *input, *link, *head, *expected; size_t length;
                  int result, releases;} expansions[] = {
        {"/link/x", "/link", "/root", "/root/x", 4093, 0, 3},
        {"/link/x", "/link", "/root", NULL, 4094, _ENAMETOOLONG, 1},
        {"/base/link/x", "/base/link", "dest", "/base/dest/x", 4087, 0, 5},
        {"/base/link/x", "/base/link", "dest", NULL, 4088, _ENAMETOOLONG, 2}};
    for (size_t i = 0; i < 4; ++i) {
        start_case("symlink target plus remainder capacity");
        char target[MAX_PATH]; padded_target(target, expansions[i].length, expansions[i].head);
        trace.link_at = expansions[i].link; trace.link_target = target;
        CHECK(normalize(expansions[i].input, N_SYMLINK_FOLLOW, 0, &out) == expansions[i].result);
        CHECK(trace.release_calls == expansions[i].releases);
        CHECK(trace.concat_calls == (expansions[i].result == 0 ? 2 : 0));
        if (expansions[i].expected) CHECK(strcmp(out.text, expansions[i].expected) == 0);
    }
    start_case("symlink depth error releases mount");
    trace.link_at = "/link"; trace.link_target = "/dest";
    CHECK(normalize("/link", N_SYMLINK_FOLLOW, 5, &out) == _ELOOP);
    CHECK(trace.release_calls == 1 && trace.concat_calls == 0);
    start_case("non-symlink readlink result keeps existing probe semantics");
    CHECK(normalize("/plain", N_SYMLINK_FOLLOW, 0, &out) == 0);
    CHECK(strcmp(out.text, "/plain") == 0 && trace.release_calls == 1);
    start_case("non-directory error releases mount");
    trace.stat_mode = S_IFREG | 0644;
    CHECK(normalize("/file/child", N_SYMLINK_FOLLOW, 0, &out) == _ENOTDIR);
    CHECK(trace.release_calls == 1 && trace.access_calls == 0);
    start_case("access error releases mount");
    trace.access_error = _EACCES;
    CHECK(normalize("/private/child", N_SYMLINK_FOLLOW, 0, &out) == _EACCES);
    CHECK(trace.release_calls == 1 && trace.access_calls == 1);
}
int main(void) {
    case_name = "fixture constants";
    test_mount(); test_readdir(); test_linux_fd(); test_normalize();
    printf("PASS: %u patched-only cases; synthetic PATH_MAX=%d; guest MAX_PATH=%d; Linux adapters\n",
           cases, PATH_MAX, MAX_PATH);
    return 0;
}
