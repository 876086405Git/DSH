/* Actual TinyEMU entry/guest instructions/socket waits. The only injections
 * are explicit syscall faults/barriers, never a replacement VM or state model.
 * pthread_timedjoin_np is a HOST TEST watchdog, not a target dependency. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>
#include "temu_embed.h"

/* Product assert failures still use its real fatal boundary. Give fixture
 * assertions their own diagnostics instead of the product's _exit(127). */
#undef assert
#define assert(condition) do { if (!(condition)) { \
    fprintf(stderr, "fixture assertion at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    _Exit(90); \
} } while (0)

static const char *mode, *config;
static int input[2], output[2], wake_pair[2];
static atomic_int initialized_flag, stop_flag, long_selects, output_polls, release_select;
static atomic_int select_calls, max_select_us, max_select_nfds;
static atomic_int poll_timeout, poll_nfds, injected;
static _Thread_local int vm_thread;
static int api_result, wait_error;

int __real_select(int, fd_set *, fd_set *, fd_set *, struct timeval *);
int __real_poll(struct pollfd *, nfds_t, int);
int __real_clock_gettime(clockid_t, struct timespec *);

static int is(const char *value) { return strcmp(mode, value) == 0; }
static void pause_ms(void)
{
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};
    nanosleep(&delay, NULL);
}
static void maximum(atomic_int *value, int item)
{
    int before = atomic_load(value);
    while (before < item && !atomic_compare_exchange_weak(value, &before, item)) {}
}

int __wrap_select(int count, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    if (!vm_thread) return __real_select(count, r, w, e, tv);
    int us = (int)(tv->tv_sec * 1000000 + tv->tv_usec);
    atomic_fetch_add(&select_calls, 1); maximum(&max_select_us, us);
    maximum(&max_select_nfds, count);
    if (us > 10000 || (is("legacy-select") && us == 10000)) {
        atomic_fetch_add(&long_selects, 1);
        if (is("select-before"))
            while (!atomic_load(&release_select)) pause_ms();
        if ((is("select-eintr") || is("select-fail") || is("select-fail-stop")) && !atomic_exchange(&injected, 1)) {
            if (is("select-fail-stop")) atomic_store(&stop_flag, 1);
            errno = is("select-eintr") ? EINTR : EBADF;
            return -1;
        }
    }
    return __real_select(count, r, w, e, tv);
}

int __wrap_poll(struct pollfd *fds, nfds_t count, int timeout)
{
    if (vm_thread) {
        atomic_store(&poll_timeout, timeout); atomic_store(&poll_nfds, count);
        atomic_fetch_add(&output_polls, 1);
        if ((is("output-eintr") || is("output-fail") || is("output-fail-stop")) && !atomic_exchange(&injected, 1)) {
            if (is("output-fail-stop")) atomic_store(&stop_flag, 1);
            errno = is("output-eintr") ? EINTR : EIO;
            return -1;
        }
    }
    return __real_poll(fds, count, timeout);
}

int __wrap_clock_gettime(clockid_t id, struct timespec *ts)
{
    if (vm_thread && is("clock-fail") && id == CLOCK_MONOTONIC && atomic_load(&initialized_flag)) {
        errno = EIO; return -1;
    }
    return __real_clock_gettime(id, ts);
}

static void initialized(void *opaque)
{
    (void)opaque; atomic_store(&initialized_flag, 1);
}
static int stopping(void *opaque)
{
    (void)opaque;
    int value = atomic_load(&stop_flag);
    /* A legal nonblocking callback need not preserve errno. */
    if (is("select-eintr") || is("select-fail") || is("select-fail-stop") || is("output-eintr") || is("output-fail") || is("output-fail-stop")) errno = EDOM;
    return value;
}
static void *run_machine(void *opaque)
{
    (void)opaque; vm_thread = 1;
    api_result = (is("legacy-select") || is("legacy-output"))
        ? temu_embed_run_controlled(config, input[0], output[0], initialized, stopping, NULL)
        : temu_embed_run_controlled_wake(config, input[0], output[0], wake_pair[0], initialized, stopping, NULL);
    wait_error = dsh_temu_wait_error;
    vm_thread = 0; return NULL;
}

static void wait_for(atomic_int *value, int minimum)
{
    for (int i = 0; i < 2000 && atomic_load(value) < minimum; i++) pause_ms();
    assert(atomic_load(value) >= minimum);
}

static void fill_output(void)
{
    int bytes = 1024;
    assert(setsockopt(output[0], SOL_SOCKET, SO_SNDBUF, &bytes, sizeof(bytes)) == 0);
    char fill[1024] = {0};
    while (send(output[0], fill, sizeof(fill), MSG_DONTWAIT | MSG_NOSIGNAL) > 0) {}
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
}

static int invalid_inputs(void)
{
    int count = 0, bad[2];
    assert(temu_embed_run_controlled_wake(config, input[0], output[0], -1, initialized, stopping, NULL) == -1); count++;
    assert(temu_embed_run_controlled_wake(config, input[0], output[0], FD_SETSIZE, initialized, stopping, NULL) == -1); count++;
    assert(temu_embed_run_controlled_wake(config, input[0], output[0], input[0], initialized, stopping, NULL) == -1); count++;
    assert(temu_embed_run_controlled_wake(config, input[0], output[0], output[0], initialized, stopping, NULL) == -1); count++;
    assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, bad) == 0);
    assert(temu_embed_run_controlled_wake(config, input[0], output[0], bad[0], initialized, stopping, NULL) == -1); count++;
    close(bad[0]); close(bad[1]);
    /* This host forbids standalone AF_UNIX socket(), although socketpair is
     * available. Use an explicitly unconnected INET descriptor as invalid
     * input; do not claim to have exercised a standalone UNIX socket here. */
    bad[0] = socket(AF_INET, SOCK_STREAM, 0); assert(bad[0] >= 0);
    assert(temu_embed_run_controlled_wake(config, input[0], output[0], bad[0], initialized, stopping, NULL) == -1); count++;
    close(bad[0]);
    return count;
}

int main(int argc, char **argv)
{
    assert(argc == 3); config = argv[1]; mode = argv[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, input) == 0);
    assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, output) == 0);
    assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, wake_pair) == 0);
    int input_flags = fcntl(input[0], F_GETFL), output_flags = fcntl(output[0], F_GETFL);
    int wake_flags = fcntl(wake_pair[0], F_GETFL), invalid = 0;
    if (is("invalid")) invalid = invalid_inputs();
    int output_mode = is("output-stop") || is("output-eintr") || is("output-fail") || is("output-fail-stop") || is("legacy-output");
    if (output_mode) fill_output();
    if (is("output-closed")) { close(output[1]); output[1] = -1; }
    if (is("stop-before") || is("invalid")) {
        atomic_store(&stop_flag, 1); assert(shutdown(wake_pair[1], SHUT_WR) == 0);
    }
    pthread_t thread; assert(pthread_create(&thread, NULL, run_machine, NULL) == 0);
    wait_for(&initialized_flag, 1);
    int fault = is("select-fail") || is("select-fail-stop") || is("output-fail") || is("output-fail-stop") || is("clock-fail") || is("output-closed");
    if (!fault && !is("stop-before") && !is("invalid")) {
        if (output_mode) wait_for(&output_polls, is("output-eintr") ? 2 : 1);
        else wait_for(&long_selects, is("select-eintr") ? 2 : 1);
        if (is("wake-data")) {
            assert(send(wake_pair[1], "x", 1, MSG_NOSIGNAL) == 1);
        } else {
            if (!is("wake-eof")) atomic_store(&stop_flag, 1);
            if (!is("legacy-select") && !is("legacy-output")) assert(shutdown(wake_pair[1], SHUT_WR) == 0);
        }
        atomic_store(&release_select, 1);
    }
    struct timespec deadline; assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0); deadline.tv_sec += 2;
    int joined = pthread_timedjoin_np(thread, NULL, &deadline);
    assert(joined == 0);
    int expected = is("output-closed") ? -5 :
        (is("select-fail") || is("select-fail-stop") || is("output-fail") || is("output-fail-stop") || is("clock-fail") || is("wake-eof") || is("wake-data")) ? -10 : -4;
    int expected_errno = (is("select-fail") || is("select-fail-stop")) ? EBADF :
        (is("output-fail") || is("output-fail-stop") || is("clock-fail")) ? EIO :
        (is("wake-eof") || is("wake-data")) ? EPROTO : 0;
    int descriptors_live = fcntl(input[0], F_GETFD) >= 0 && fcntl(output[0], F_GETFD) >= 0
        && fcntl(wake_pair[0], F_GETFD) >= 0 && fcntl(wake_pair[1], F_GETFD) >= 0;
    int flags_unchanged = fcntl(input[0], F_GETFL) == input_flags && fcntl(output[0], F_GETFL) == output_flags
        && fcntl(wake_pair[0], F_GETFL) == wake_flags;
    int repeated = temu_embed_run_controlled(config, input[0], output[0], initialized, stopping, NULL);
    int passed = api_result == expected && wait_error == expected_errno && descriptors_live && flags_unchanged
        && repeated == TEMU_EMBED_OWNER_UNRELEASED;
    if (output_mode) passed &= atomic_load(&poll_nfds) == (is("legacy-output") ? 1 : 2)
        && atomic_load(&poll_timeout) == (is("legacy-output") ? 10 : -1);
    if (is("legacy-select")) passed &= atomic_load(&max_select_us) == 10000;
    if (is("select-before") || is("select-stop")) passed &= atomic_load(&max_select_us) == (INT_MAX / 1000) * 1000;
    printf("{\"mode\":\"%s\",\"apiResult\":%d,\"expectedApi\":%d,\"waitError\":%d,\"expectedWaitError\":%d,\"selectCalls\":%d,\"maximumSelectUs\":%d,\"selectNfds\":%d,\"outputPollCalls\":%d,\"outputPollNfds\":%d,\"outputPollTimeout\":%d,\"invalidPreclaimCases\":%d,\"joined\":true,\"borrowedDescriptorsLive\":%s,\"ofdFlagsUnchanged\":%s,\"repeatOwnerResult\":%d,\"passed\":%s}\n",
        mode, api_result, expected, wait_error, expected_errno, atomic_load(&select_calls), atomic_load(&max_select_us),
        atomic_load(&max_select_nfds), atomic_load(&output_polls), atomic_load(&poll_nfds), atomic_load(&poll_timeout), invalid,
        descriptors_live ? "true" : "false", flags_unchanged ? "true" : "false", repeated, passed ? "true" : "false");
    for (int i = 0; i < 2; i++) { close(input[i]); if (output[i] >= 0) close(output[i]); close(wake_pair[i]); }
    return !passed;
}
