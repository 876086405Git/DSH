#include <node_api.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "temu_embed.h"
#include "embed-fatal.h"
#include "embed-ram.h"

typedef struct {
    pthread_t thread;
    atomic_int stop;
    int peer, result, fatal_reason, wait_error, join_error, join_attempted, joined;
    pthread_mutex_t wake_mutex;
    int wake_read, wake_write, body_returned;
    int notification, notification_error;
    int peer_close_error, read_close_error, write_close_error;
    char *config;
    napi_async_work work;
    napi_deferred deferred;
    napi_ref promise;
    DshTemuRamRetirement ram_retirement;
} Owner;
static atomic_flag claimed = ATOMIC_FLAG_INIT;
static napi_value fail(napi_env env, const char *code, const char *message) {
    napi_throw_error(env, code, message); return NULL;
}
static int stopping(void *data) { return atomic_load(&((Owner *)data)->stop); }
static int close_owned(int *owned) {
    int fd = *owned;
    *owned = -1; /* Never retry a possibly reused integer, including EINTR. */
    return fd >= 0 && close(fd) ? errno : 0;
}
static void stop_and_notify(Owner *owner) {
    atomic_store(&owner->stop, 1);
    pthread_mutex_lock(&owner->wake_mutex);
    if (!owner->notification) {
        if (owner->body_returned) owner->notification = 2;
        else if (owner->wake_write < 0) {
            owner->notification = -1; owner->notification_error = EBADF;
        } else if (shutdown(owner->wake_write, SHUT_WR)) {
            owner->notification = -1; owner->notification_error = errno;
        } else owner->notification = 1;
    }
    pthread_mutex_unlock(&owner->wake_mutex);
}
static void *machine(void *data) {
    Owner *owner = data;
    owner->result = temu_embed_run_controlled_wake(owner->config, owner->peer, owner->peer,
                                                  owner->wake_read, NULL, stopping, owner);
    owner->fatal_reason = dsh_temu_fatal_reason;
    owner->wait_error = dsh_temu_wait_error;
    owner->peer_close_error = close_owned(&owner->peer);
    pthread_mutex_lock(&owner->wake_mutex);
    owner->body_returned = 1; /* Join admission only, never proof of thread exit. */
    owner->read_close_error = close_owned(&owner->wake_read);
    pthread_mutex_unlock(&owner->wake_mutex);
    return NULL;
}
static void finalize(napi_env env, void *data, void *hint) {
    (void)env; (void)hint;
    stop_and_notify(data);
    /* The VM allocations and owner remain quarantined, including after GC.
       Finalization is not join or cleanup completion. Library is NODELETE. */
}
static void cleanup(void *data) { stop_and_notify(data); }
static napi_value request_stop(napi_env env, napi_callback_info info) {
    void *data; napi_value value;
    if (napi_get_cb_info(env, info, NULL, NULL, NULL, &data) != napi_ok) return NULL;
    stop_and_notify(data);
    napi_get_undefined(env, &value); return value;
}
static void join_execute(napi_env env, void *data) {
    (void)env; Owner *owner = data;
    owner->join_attempted = 1;
    owner->join_error = pthread_join(owner->thread, NULL);
    owner->joined = owner->join_error == 0;
    if (owner->joined) {
        pthread_mutex_lock(&owner->wake_mutex);
        owner->write_close_error = close_owned(&owner->wake_write);
        pthread_mutex_unlock(&owner->wake_mutex);
        owner->ram_retirement = dsh_temu_ram_retire_joined();
    }
}
static void boolean(napi_env env, napi_value out, const char *key, int b) {
    napi_value value; napi_get_boolean(env, b, &value); napi_set_named_property(env, out, key, value);
}
static void integer(napi_env env, napi_value out, const char *key, int n) {
    napi_value value; napi_create_int32(env, n, &value); napi_set_named_property(env, out, key, value);
}
static void bytes(napi_env env, napi_value out, const char *key, uint64_t n) {
    napi_value value; napi_create_double(env, (double)n, &value); napi_set_named_property(env, out, key, value);
}
static napi_value join_result(napi_env env, Owner *owner) {
    napi_value out, notification, unknown;
    if (napi_create_object(env, &out) != napi_ok ||
        napi_create_object(env, &notification) != napi_ok) return NULL;
    napi_get_null(env, &unknown);
    int synchronized = owner->joined;
    boolean(env, out, "joined", synchronized);
    boolean(env, out, "joinAttempted", owner->join_attempted);
    boolean(env, out, "ownerQuarantined", 1);
    pthread_mutex_lock(&owner->wake_mutex);
    int state = owner->notification, error = owner->notification_error;
    pthread_mutex_unlock(&owner->wake_mutex);
    boolean(env, notification, "attempted", state == 1 || state == -1);
    boolean(env, notification, "notified", state == 1);
    boolean(env, notification, "unnecessary", state == 2);
    integer(env, notification, "errorCode", error);
    napi_set_named_property(env, out, "stopNotification", notification);
    if (synchronized) {
        if (owner->result == TEMU_EMBED_UNRECOVERED_START_FAILURE)
            napi_set_named_property(env, out, "retirementError", unknown);
        else boolean(env, out, "retirementError", owner->result == -8);
        integer(env, out, "apiResult", owner->result);
        integer(env, out, "fatalReason", owner->fatal_reason);
        integer(env, out, "waitError", owner->wait_error);
        napi_value ram, fds;
        if (napi_create_object(env, &ram) != napi_ok || napi_create_object(env, &fds) != napi_ok) return NULL;
        boolean(env, fds, "retired", !owner->peer_close_error && !owner->read_close_error && !owner->write_close_error);
        integer(env, fds, "consoleError", owner->peer_close_error);
        integer(env, fds, "wakeReadError", owner->read_close_error);
        integer(env, fds, "wakeWriteError", owner->write_close_error);
        napi_set_named_property(env, out, "fdRetirement", fds);
        boolean(env, ram, "eligible", owner->ram_retirement.eligible);
        boolean(env, ram, "attempted", owner->ram_retirement.attempted);
        bytes(env, ram, "trackedBytes", owner->ram_retirement.tracked_bytes);
        bytes(env, ram, "eligibleBytes", owner->ram_retirement.eligible_bytes);
        bytes(env, ram, "advisedBytes", owner->ram_retirement.advised_bytes);
        integer(env, ram, "errorCode", owner->ram_retirement.error_code);
        napi_set_named_property(env, out, "ramRetirement", ram);
    } else {
        /* No successful pthread_join: do not read machine-thread fields. */
        napi_set_named_property(env, out, "retirementError", unknown);
        napi_set_named_property(env, out, "apiResult", unknown);
        napi_set_named_property(env, out, "fatalReason", unknown);
        napi_set_named_property(env, out, "ramRetirement", unknown);
        napi_set_named_property(env, out, "waitError", unknown);
        napi_set_named_property(env, out, "fdRetirement", unknown);
    }
    if (owner->join_attempted) integer(env, out, "joinError", owner->join_error);
    else napi_set_named_property(env, out, "joinError", unknown);
    return out;
}
static void join_complete(napi_env env, napi_status status, void *data) {
    (void)status; Owner *owner = data;
    napi_value out = join_result(env, owner);
    if (!out) {
        napi_delete_async_work(env, owner->work); owner->work = NULL; return;
    }
    napi_resolve_deferred(env, owner->deferred, out);
    napi_delete_async_work(env, owner->work); owner->work = NULL;
}
static napi_value join_owner(napi_env env, napi_callback_info info) {
    void *data; napi_value promise, name;
    if (napi_get_cb_info(env, info, NULL, NULL, NULL, &data) != napi_ok) return NULL;
    Owner *owner = data;
    if (!atomic_load(&owner->stop)) return fail(env, "ERR_OHOS_LINUX_STOP_REQUIRED", "requestStop must precede join");
    if (owner->promise) {
        if (napi_get_reference_value(env, owner->promise, &promise) != napi_ok)
            return fail(env, "ERR_OHOS_LINUX_JOIN", "Join already started; cannot retrieve its Promise");
        return promise;
    }
    stop_and_notify(owner); /* Also serializes a concurrent cleanup notification. */
    pthread_mutex_lock(&owner->wake_mutex);
    int notify_failed = owner->notification == -1;
    pthread_mutex_unlock(&owner->wake_mutex);
    if (notify_failed) {
        napi_value out = join_result(env, owner);
        if (!out || napi_create_promise(env, &owner->deferred, &promise) != napi_ok ||
            napi_create_reference(env, promise, 1, &owner->promise) != napi_ok)
            return fail(env, "ERR_OHOS_LINUX_JOIN", "Cannot retain failed notification result; owner remains quarantined");
        napi_resolve_deferred(env, owner->deferred, out);
        return promise; /* No pthread_join or async worker after failed notification. */
    }
    if (napi_create_promise(env, &owner->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "TinyEMU explicit stop join", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_async_work(env, NULL, name, join_execute, join_complete, owner, &owner->work) != napi_ok)
        return fail(env, "ERR_OHOS_LINUX_JOIN", "Cannot allocate explicit join work; owner remains quarantined");
    napi_ref reference = NULL;
    if (napi_create_reference(env, promise, 1, &reference) != napi_ok) {
        napi_delete_async_work(env, owner->work); owner->work = NULL;
        return fail(env, "ERR_OHOS_LINUX_JOIN", "Cannot retain join Promise; no join was queued");
    }
    owner->promise = reference; /* Cache before queueing; no duplicate join. */
    if (napi_queue_async_work(env, owner->work) != napi_ok) {
        napi_delete_reference(env, owner->promise); owner->promise = NULL;
        napi_delete_async_work(env, owner->work); owner->work = NULL;
        return fail(env, "ERR_OHOS_LINUX_JOIN", "Cannot queue explicit join; owner remains quarantined");
    }
    return promise;
}
static napi_value create(napi_env env, napi_callback_info info) {
    napi_value arg, out, fdvalue; size_t argc = 1, length = 0; napi_valuetype type;
    if (napi_get_cb_info(env, info, &argc, &arg, NULL, NULL) != napi_ok || argc != 1 ||
        napi_typeof(env, arg, &type) != napi_ok || type != napi_string ||
        napi_get_value_string_utf8(env, arg, NULL, 0, &length) != napi_ok || length < 1 || length > 4095)
        return fail(env, "ERR_OHOS_LINUX_CONFIG", "An absolute local configuration path is required");
    Owner *owner = calloc(1, sizeof(*owner));
    if (!owner) return fail(env, "ERR_OHOS_LINUX_ALLOC", "Cannot allocate Linux owner");
    owner->config = malloc(length + 1);
    if (!owner->config) { free(owner); return fail(env, "ERR_OHOS_LINUX_ALLOC", "Cannot allocate configuration path"); }
    napi_get_value_string_utf8(env, arg, owner->config, length + 1, &length);
    if (owner->config[0] != '/' || strlen(owner->config) != length) {
        free(owner->config); free(owner); return fail(env, "ERR_OHOS_LINUX_CONFIG", "Configuration must be absolute without NUL");
    }
    owner->peer = owner->wake_read = owner->wake_write = -1;
    if (pthread_mutex_init(&owner->wake_mutex, NULL)) {
        free(owner->config); free(owner); return fail(env, "ERR_OHOS_LINUX_CREATE", "Cannot initialize Linux notification owner");
    }
    if (atomic_flag_test_and_set(&claimed)) {
        pthread_mutex_destroy(&owner->wake_mutex); free(owner->config); free(owner); return fail(env, "ERR_OHOS_LINUX_OWNER_QUARANTINED", "This process already retains a Linux VM owner");
    }
    int pair[2] = {-1,-1}, wake[2] = {-1,-1}, wrapped = 0, hooked = 0;
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair)) goto failed;
    owner->peer = pair[1];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, wake)) goto failed;
    owner->wake_read = wake[0]; owner->wake_write = wake[1];
    if (napi_create_object(env, &out) != napi_ok || napi_create_int32(env, pair[0], &fdvalue) != napi_ok ||
        napi_set_named_property(env, out, "fd", fdvalue) != napi_ok) goto failed;
    napi_property_descriptor methods[] = {
        {"requestStop",NULL,request_stop,NULL,NULL,NULL,napi_default,owner},
        {"join",NULL,join_owner,NULL,NULL,NULL,napi_default,owner}
    };
    if (napi_define_properties(env, out, 2, methods) != napi_ok) goto failed;
    if (napi_wrap(env, out, owner, finalize, NULL, NULL) != napi_ok) goto failed;
    wrapped = 1;
    if (napi_add_env_cleanup_hook(env, cleanup, owner) != napi_ok) goto failed;
    hooked = 1;
    int error = pthread_create(&owner->thread, NULL, machine, owner);
    if (error) {
        errno = error; goto failed;
    }
    /* Ownership transfer occurs only on successful return. */
    return out;
failed:
    if (wrapped) { void *removed; wrapped = napi_remove_wrap(env, out, &removed) != napi_ok; }
    if (hooked) hooked = napi_remove_env_cleanup_hook(env, cleanup, owner) != napi_ok;
    int client_error = close_owned(&pair[0]);
    owner->peer_close_error = close_owned(&owner->peer);
    pthread_mutex_lock(&owner->wake_mutex);
    owner->read_close_error = close_owned(&owner->wake_read);
    owner->write_close_error = close_owned(&owner->wake_write);
    pthread_mutex_unlock(&owner->wake_mutex);
    if (!wrapped && !hooked && !client_error && !owner->peer_close_error &&
        !owner->read_close_error && !owner->write_close_error && !pthread_mutex_destroy(&owner->wake_mutex)) {
        free(owner->config); free(owner); atomic_flag_clear(&claimed);
        return fail(env, "ERR_OHOS_LINUX_CREATE", "Cannot construct Linux transport/thread");
    }
    return fail(env, "ERR_OHOS_LINUX_CREATE_QUARANTINED", "Cannot construct Linux transport/thread; native ownership remains quarantined");
}
static napi_value initialize(napi_env env, napi_value exports) {
    napi_value function;
    if (napi_create_function(env, "create", NAPI_AUTO_LENGTH, create, NULL, &function) != napi_ok) return NULL;
    napi_set_named_property(env, exports, "create", function);
    return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, initialize)
