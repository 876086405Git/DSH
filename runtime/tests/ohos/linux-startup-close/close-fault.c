/* Test-only link seams: reach the real three startup close sites. A failed
 * fclose deliberately retains its FILE/descriptor; it is never retried. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int target(FILE *file)
{
    const char *wanted = getenv("DSH_TEST_STARTUP_DISK");
    char descriptor[64], path[PATH_MAX + 1];
    snprintf(descriptor, sizeof(descriptor), "/proc/self/fd/%d", fileno(file));
    ssize_t n = readlink(descriptor, path, sizeof(path) - 1);
    if (!wanted || n < 0) return 0;
    path[n] = '\0';
    return !strcmp(path, wanted);
}
static int site(const char *name)
{
    const char *value = getenv("DSH_TEST_STARTUP_SITE");
    return value && !strcmp(value, name);
}
int __real_fseek(FILE *, long, int);
int __wrap_fseek(FILE *file, long offset, int whence)
{
    if (target(file) && site("seek")) {
        fprintf(stderr, "STARTUP_SITE seek\n");
        errno = EIO; return -1;
    }
    return __real_fseek(file, offset, whence);
}
off64_t __real_ftello64(FILE *);
off64_t __wrap_ftello64(FILE *file)
{
    if (target(file) && site("tell")) {
        fprintf(stderr, "STARTUP_SITE tell\n");
        errno = EIO; return -1;
    }
    return __real_ftello64(file);
}
int __real_fclose(FILE *);
int __wrap_fclose(FILE *file)
{
    if (!target(file)) return __real_fclose(file);
    const char *value = getenv("DSH_TEST_STARTUP_CLOSE");
    int fault = value && !strcmp(value, "retain-eio"), fd = fileno(file);
    int result;
    if (fault) { errno = EIO; result = EOF; }
    else result = __real_fclose(file);
    int error = result ? errno : 0, live = fcntl(fd, F_GETFD) >= 0;
    fprintf(stderr, "STARTUP_CLOSE {\"fd\":%d,\"fault\":%s,\"returned\":%d,\"errorCode\":%d,\"live\":%s}\n",
            fd, fault ? "true" : "false", result, error, live ? "true" : "false");
    errno = error; return result;
}
