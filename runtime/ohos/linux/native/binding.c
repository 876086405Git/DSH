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
    int peer, result, fatal_reason, join_error, joined;
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
static void *machine(void *data) {
    Owner *owner = data;
    owner->result = temu_embed_run_controlled(owner->config, owner->peer, owner->peer, NULL, stopping, owner);
    owner->fatal_reason = dsh_temu_fatal_reason;
    close(owner->peer); /* Only the native socket end; transferred fd is never closed here. */
    return NULL;
}
static void finalize(napi_env env, void *data, void *hint) {
    (void)env; (void)hint;
    atomic_store(&((Owner *)data)->stop, 1);
    /* The VM allocations and owner remain quarantined, including after GC.
       Finalization is not join or cleanup completion. Library is NODELETE. */
}
static void cleanup(void *data) { atomic_store(&((Owner *)data)->stop, 1); }
static napi_value request_stop(napi_env env, napi_callback_info info) {
    void *data; napi_value value;
    if (napi_get_cb_info(env, info, NULL, NULL, NULL, &data) != napi_ok) return NULL;
    atomic_store(&((Owner *)data)->stop, 1);
    napi_get_undefined(env, &value); return value;
}
static void join_execute(napi_env env, void *data) {
    (void)env; Owner *owner = data;
    owner->join_error = pthread_join(owner->thread, NULL);
    owner->joined = owner->join_error == 0;
    if (owner->joined) owner->ram_retirement = dsh_temu_ram_retire_joined();
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
static void join_complete(napi_env env, napi_status status, void *data) {
    Owner *owner = data; napi_value out;
    if (napi_create_object(env, &out) != napi_ok) {
        napi_delete_async_work(env, owner->work); owner->work = NULL; return;
    }
    int synchronized = status == napi_ok && owner->joined;
    boolean(env, out, "joined", synchronized);
    boolean(env, out, "ownerQuarantined", 1);
    if (synchronized) {
        boolean(env, out, "retirementError", owner->result == -8);
        integer(env, out, "apiResult", owner->result);
        integer(env, out, "fatalReason", owner->fatal_reason);
        napi_value ram;
        if (napi_create_object(env, &ram) != napi_ok) {
            napi_delete_async_work(env, owner->work); owner->work = NULL; return;
        }
        boolean(env, ram, "eligible", owner->ram_retirement.eligible);
        boolean(env, ram, "attempted", owner->ram_retirement.attempted);
        bytes(env, ram, "trackedBytes", owner->ram_retirement.tracked_bytes);
        bytes(env, ram, "eligibleBytes", owner->ram_retirement.eligible_bytes);
        bytes(env, ram, "advisedBytes", owner->ram_retirement.advised_bytes);
        integer(env, ram, "errorCode", owner->ram_retirement.error_code);
        napi_set_named_property(env, out, "ramRetirement", ram);
    } else {
        /* No successful pthread_join: do not read machine-thread fields. */
        napi_value unknown; napi_get_null(env, &unknown);
        napi_set_named_property(env, out, "retirementError", unknown);
        napi_set_named_property(env, out, "apiResult", unknown);
        napi_set_named_property(env, out, "fatalReason", unknown);
        napi_set_named_property(env, out, "ramRetirement", unknown);
    }
    integer(env, out, "joinError", owner->join_error);
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
    if (atomic_flag_test_and_set(&claimed)) {
        free(owner->config); free(owner); return fail(env, "ERR_OHOS_LINUX_OWNER_QUARANTINED", "This process already retains a Linux VM owner");
    }
    int pair[2] = {-1,-1};
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair)) goto failed;
    owner->peer = pair[1];
    if (napi_create_object(env, &out) != napi_ok || napi_create_int32(env, pair[0], &fdvalue) != napi_ok ||
        napi_set_named_property(env, out, "fd", fdvalue) != napi_ok) goto failed;
    napi_property_descriptor methods[] = {
        {"requestStop",NULL,request_stop,NULL,NULL,NULL,napi_default,owner},
        {"join",NULL,join_owner,NULL,NULL,NULL,napi_default,owner}
    };
    if (napi_define_properties(env, out, 2, methods) != napi_ok) goto failed;
    if (napi_wrap(env, out, owner, finalize, NULL, NULL) != napi_ok) goto failed;
    if (napi_add_env_cleanup_hook(env, cleanup, owner) != napi_ok) { void *removed; napi_remove_wrap(env,out,&removed); goto failed; }
    int error = pthread_create(&owner->thread, NULL, machine, owner);
    if (error) {
        void *removed; napi_remove_wrap(env, out, &removed); napi_remove_env_cleanup_hook(env, cleanup, owner); errno = error; goto failed;
    }
    /* Ownership transfer occurs only on successful return. */
    return out;
failed:
    if (pair[0] >= 0) close(pair[0]);
    if (pair[1] >= 0) close(pair[1]);
    free(owner->config); free(owner); atomic_flag_clear(&claimed);
    return fail(env, "ERR_OHOS_LINUX_CREATE", "Cannot construct Linux transport/thread");
}
static napi_value initialize(napi_env env, napi_value exports) {
    napi_value function;
    if (napi_create_function(env, "create", NAPI_AUTO_LENGTH, create, NULL, &function) != napi_ok) return NULL;
    napi_set_named_property(env, exports, "create", function);
    return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, initialize)
