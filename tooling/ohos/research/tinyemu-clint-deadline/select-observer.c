/* Test-only observer for the actual linked TinyEMU select calls. */
#include <node_api.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
static atomic_ullong calls, returned, timeouts, ready, errors, requested_us, maximum_us;
static atomic_int installed;
static atomic_ullong zero_delay, thread_cpu_ns;
int __real_select(int,fd_set*,fd_set*,fd_set*,struct timeval*);
int __wrap_select(int n,fd_set*r,fd_set*w,fd_set*e,struct timeval*t) {
    atomic_fetch_add(&calls,1);
    if(t) {
        unsigned long long us=(unsigned long long)t->tv_sec*1000000+t->tv_usec;
        atomic_fetch_add(&requested_us,us);
        if(!us)atomic_fetch_add(&zero_delay,1);
        unsigned long long old=atomic_load(&maximum_us);
        while(old<us&&!atomic_compare_exchange_weak(&maximum_us,&old,us)){}
    }
    int result=__real_select(n,r,w,e,t);
    struct timespec cpu;clock_gettime(CLOCK_THREAD_CPUTIME_ID,&cpu);
    atomic_store(&thread_cpu_ns,(unsigned long long)cpu.tv_sec*1000000000+cpu.tv_nsec);
    atomic_fetch_add(&returned,1);
    if(result==0)atomic_fetch_add(&timeouts,1);
    else if(result>0)atomic_fetch_add(&ready,1);
    else atomic_fetch_add(&errors,1);
    return result;
}
static void number(napi_env env,napi_value out,const char*name,unsigned long long n) {
    napi_value value;napi_create_double(env,(double)n,&value);napi_set_named_property(env,out,name,value);
}
static napi_value stats(napi_env env,napi_callback_info info) {
    (void)info;napi_value out;napi_create_object(env,&out);
    number(env,out,"calls",atomic_load(&calls));number(env,out,"returned",atomic_load(&returned));
    number(env,out,"timeouts",atomic_load(&timeouts));number(env,out,"ready",atomic_load(&ready));
    number(env,out,"errors",atomic_load(&errors));number(env,out,"requestedUs",atomic_load(&requested_us));
    number(env,out,"maximumUs",atomic_load(&maximum_us));
    number(env,out,"zeroDelayCalls",atomic_load(&zero_delay));number(env,out,"threadCpuNs",atomic_load(&thread_cpu_ns));return out;
}
napi_status __real_napi_set_named_property(napi_env,napi_value,const char*,napi_value);
napi_status __wrap_napi_set_named_property(napi_env env,napi_value object,const char*name,napi_value value) {
    napi_status code=__real_napi_set_named_property(env,object,name,value);
    if(code==napi_ok&&!strcmp(name,"create")&&!atomic_exchange(&installed,1)){
        napi_value fn;
        if(napi_create_function(env,"__idleStats",NAPI_AUTO_LENGTH,stats,NULL,&fn)!=napi_ok)return napi_generic_failure;
        return __real_napi_set_named_property(env,object,"__idleStats",fn);
    }
    return code;
}
