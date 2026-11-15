/* Test-only link seams. The product binding and TinyEMU remain actual code. */
#define _GNU_SOURCE
#include <node_api.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>
#include <sched.h>

static int client = -1, peer = -1, reader = -1, writer = -1;
static atomic_int pairs, notifications, joins, creates, closes_peer, closes_read, closes_write;
static atomic_int machine_returned, reference_calls, hook_calls, work_calls;
static atomic_int long_select_calls, long_select_returns;
static int sentinel[2] = {-1, -1}, protected_reader;
static void *(*start_function)(void *);
static void *start_data;
static int is(const char *name) {
    const char *mode = getenv("DSH_TEST_OWNER_FAULT");
    return mode && !strcmp(mode, name);
}
int __real_socketpair(int, int, int, int[2]);
int __wrap_socketpair(int domain, int type, int protocol, int pair[2]) {
    int call = atomic_fetch_add(&pairs, 1) + 1;
    if (is("second-pair") && call == 2) { errno = EMFILE; return -1; }
    int result = __real_socketpair(domain, type, protocol, pair);
    if (!result) {
        if (call % 2) { client = pair[0]; peer = pair[1]; }
        else { reader = pair[0]; writer = pair[1]; }
    }
    return result;
}
int __real_shutdown(int, int);
int __wrap_shutdown(int fd, int how) {
    if (fd == writer && how == SHUT_WR) {
        int count = atomic_fetch_add(&notifications, 1) + 1;
        if (count != 1) _Exit(91);
        if (is("notify-eio") || is("notify-eintr")) { errno = is("notify-eio") ? EIO : EINTR; return -1; }
        if (is("notify-reader-race")) {
            for (int i = 0; !atomic_load(&closes_peer) && i < 1000000; i++) sched_yield();
            if (!atomic_load(&closes_peer)) _Exit(92);
            usleep(10000);
            if (atomic_load(&closes_read)) _Exit(93);
            protected_reader = 1;
        }
    }
    return __real_shutdown(fd, how);
}
int __real_close(int);
int __wrap_close(int fd) {
    int fault = 0;
    if (fd == peer) { atomic_fetch_add(&closes_peer, 1); fault = is("peer-close") || is("rollback-close"); }
    if (fd == reader) { atomic_fetch_add(&closes_read, 1); fault = is("reader-close"); }
    if (fd == writer) { atomic_fetch_add(&closes_write, 1); fault = is("writer-close") || is("writer-reuse"); }
    int result = __real_close(fd);
    if (fault && result == 0) {
        if (is("writer-reuse")) {
            if (__real_socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sentinel)) _Exit(94);
            if (sentinel[0] != fd) {
                if (dup2(sentinel[0], fd) != fd) _Exit(95);
                __real_close(sentinel[0]); sentinel[0] = fd;
            }
        }
        errno = EINTR; return -1; /* Real close happened; errno makes ownership uncertain. */
    }
    return result;
}
int __real_pthread_join(pthread_t, void **);
int __wrap_pthread_join(pthread_t thread, void **value) {
    if (atomic_fetch_add(&joins, 1)) _Exit(96);
    if (is("join-esrch")) return ESRCH;
    return __real_pthread_join(thread, value);
}
static void *machine_start(void *unused) {
    (void)unused;
    void *value = start_function(start_data);
    atomic_store(&machine_returned, 1);
    return value;
}
int __real_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*fn)(void *), void *data) {
    int call = atomic_fetch_add(&creates, 1);
    if ((is("create-eagain") || is("rollback-close")) && !call) return EAGAIN;
    start_function = fn; start_data = data;
    int result = __real_pthread_create(thread, attr, machine_start, NULL);
    if (!result && is("already-returned")) {
        for (int i = 0; !atomic_load(&machine_returned) && i < 1000000; i++) sched_yield();
        if (!atomic_load(&machine_returned)) _Exit(97);
    }
    return result;
}
napi_status __real_napi_create_reference(napi_env, napi_value, uint32_t, napi_ref *);
napi_status __wrap_napi_create_reference(napi_env env, napi_value value, uint32_t count, napi_ref *out) {
    if (is("reference-fail") && !atomic_fetch_add(&reference_calls, 1)) return napi_generic_failure;
    return __real_napi_create_reference(env, value, count, out);
}
napi_status __real_napi_add_env_cleanup_hook(napi_env, napi_cleanup_hook, void *);
napi_status __wrap_napi_add_env_cleanup_hook(napi_env env, napi_cleanup_hook fn, void *data) {
    if (is("hook-fail") && !atomic_fetch_add(&hook_calls, 1)) return napi_generic_failure;
    return __real_napi_add_env_cleanup_hook(env, fn, data);
}
static napi_async_complete_callback actual_complete;
static void no_execute(napi_env env, void *data) { (void)env; (void)data; }
static void cancelled(napi_env env, napi_status status, void *data) { (void)status; actual_complete(env, napi_cancelled, data); }
napi_status __real_napi_create_async_work(napi_env,napi_value,napi_value,napi_async_execute_callback,napi_async_complete_callback,void *,napi_async_work *);
napi_status __wrap_napi_create_async_work(napi_env env, napi_value resource, napi_value name, napi_async_execute_callback execute, napi_async_complete_callback complete, void *data, napi_async_work *out) {
    atomic_fetch_add(&work_calls, 1);
    if (is("work-cancelled")) { actual_complete = complete; execute = no_execute; complete = cancelled; }
    return __real_napi_create_async_work(env, resource, name, execute, complete, data, out);
}
int __real_select(int, fd_set *, fd_set *, fd_set *, struct timeval *);
int __wrap_select(int max, fd_set *read, fd_set *write, fd_set *error, struct timeval *timeout) {
    int extended = timeout && (timeout->tv_sec > 0 || timeout->tv_usec > 10000);
    if (extended) atomic_fetch_add(&long_select_calls, 1);
    int result = __real_select(max, read, write, error, timeout);
    if (extended) atomic_fetch_add(&long_select_returns, 1);
    return result;
}
static void number(napi_env env, napi_value out, const char *key, int n) {
    napi_value value; napi_create_int32(env, n, &value); napi_set_named_property(env, out, key, value);
}
static napi_value stats(napi_env env, napi_callback_info info) {
    (void)info; napi_value out; napi_create_object(env, &out);
    number(env, out, "notifications", atomic_load(&notifications));
    number(env, out, "joins", atomic_load(&joins));
    number(env, out, "workCalls", atomic_load(&work_calls));
    number(env, out, "bodyReturned", atomic_load(&machine_returned));
    number(env, out, "peerCloses", atomic_load(&closes_peer));
    number(env, out, "readCloses", atomic_load(&closes_read));
    number(env, out, "writeCloses", atomic_load(&closes_write));
    number(env, out, "longSelectCalls", atomic_load(&long_select_calls));
    number(env, out, "longSelectReturns", atomic_load(&long_select_returns));
    return out;
}
napi_status __real_napi_set_named_property(napi_env, napi_value, const char *, napi_value);
napi_status __wrap_napi_set_named_property(napi_env env, napi_value out, const char *name, napi_value value) {
    napi_status status = __real_napi_set_named_property(env, out, name, value);
    if (status == napi_ok && !strcmp(name, "create")) {
        napi_value fn;
        if (napi_create_function(env, "__ownerTestStats", NAPI_AUTO_LENGTH, stats, NULL, &fn) != napi_ok) return napi_generic_failure;
        return __real_napi_set_named_property(env, out, "__ownerTestStats", fn);
    }
    return status;
}
__attribute__((destructor)) static void facts(void) {
    int reuse_ok = 0;
    if (sentinel[0] >= 0) {
        char value = 0;
        reuse_ok = send(sentinel[0], "q", 1, MSG_NOSIGNAL) == 1 && recv(sentinel[1], &value, 1, MSG_DONTWAIT) == 1 && value == 'q';
        __real_close(sentinel[0]); __real_close(sentinel[1]);
    }
    fprintf(stderr, "OWNER_FACTS {\"pairs\":%d,\"notifications\":%d,\"joins\":%d,\"creates\":%d,\"peerCloses\":%d,\"readCloses\":%d,\"writeCloses\":%d,\"workCalls\":%d,\"bodyReturned\":%d,\"protectedReader\":%d,\"reuseUnaffected\":%d,\"clientFd\":%d}\n",
        atomic_load(&pairs), atomic_load(&notifications), atomic_load(&joins), atomic_load(&creates),
        atomic_load(&closes_peer), atomic_load(&closes_read), atomic_load(&closes_write), atomic_load(&work_calls),
        atomic_load(&machine_returned), protected_reader, reuse_ok, client);
}
