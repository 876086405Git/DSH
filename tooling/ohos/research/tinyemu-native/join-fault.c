#include <node_api.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <stdlib.h>
#ifndef FAULT_MODE
#define FAULT_MODE 0
#endif
static int reference_calls;
static atomic_int joins;
napi_status __real_napi_create_reference(napi_env,napi_value,uint32_t,napi_ref*);
napi_status __wrap_napi_create_reference(napi_env env,napi_value value,uint32_t count,napi_ref *result) {
    if (FAULT_MODE == 1 && reference_calls++ == 0) return napi_generic_failure;
    return __real_napi_create_reference(env,value,count,result);
}
int __real_pthread_join(pthread_t,void**);
int __wrap_pthread_join(pthread_t thread,void **result) {
    if (atomic_fetch_add(&joins,1)) _Exit(91); /* Never join twice. Test-only. */
    if (FAULT_MODE == 2) return ESRCH;
    return __real_pthread_join(thread,result);
}
static napi_async_complete_callback original_complete;
static void no_execute(napi_env env,void *data){(void)env;(void)data;}
static void cancelled(napi_env env,napi_status status,void *data){(void)status;original_complete(env,napi_cancelled,data);}
napi_status __real_napi_create_async_work(napi_env,napi_value,napi_value,napi_async_execute_callback,napi_async_complete_callback,void*,napi_async_work*);
napi_status __wrap_napi_create_async_work(napi_env env,napi_value resource,napi_value name,napi_async_execute_callback execute,napi_async_complete_callback complete,void *data,napi_async_work *result) {
    if (FAULT_MODE == 3) { original_complete=complete;execute=no_execute;complete=cancelled; }
    return __real_napi_create_async_work(env,resource,name,execute,complete,data,result);
}
