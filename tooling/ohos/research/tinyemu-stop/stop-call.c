#define _GNU_SOURCE
#include <stdatomic.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include "temu_embed.h"
static atomic_int initialized_flag, stop_flag, polls;
static int result, in_fd, out_fd;
static const char *config;
static int (*controlled)(const char *, int, int, TemuInitialized, TemuShouldStop, void *);
static int (*legacy)(const char *, int, int, TemuInitialized, void *);
static void initialized(void *opaque) {(void)opaque; atomic_store(&initialized_flag,1);}
static int stopping(void *opaque) {(void)opaque; atomic_fetch_add(&polls,1); return atomic_load(&stop_flag);}
static void *run(void *opaque) {
    (void)opaque;
    result=controlled ? controlled(config,in_fd,out_fd,initialized,stopping,NULL)
                      : legacy(config,in_fd,out_fd,initialized,NULL);
    return NULL;
}
static void pause_ms(void) {struct timespec t={0,1000000}; nanosleep(&t,NULL);}
int main(int argc, char **argv) {
    if(argc!=4) return 64;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!lib) {fprintf(stderr,"%s\n",dlerror());return 65;}
    controlled=dlsym(lib,"temu_embed_run_controlled");
    legacy=dlsym(lib,"temu_embed_run_initialized");
    if(!legacy) return 66;
    config=argv[2]; int peer[2];
    if(socketpair(AF_UNIX,SOCK_STREAM,0,peer)) return 67;
    int input[2]; if(socketpair(AF_UNIX,SOCK_STREAM,0,input)) return 73;
    in_fd=input[0]; out_fd=peer[0];
    int input_flags=fcntl(in_fd,F_GETFL);
    int flags=fcntl(out_fd,F_GETFL);
    int closed=!strcmp(argv[3],"closed");
    if(closed) close(peer[1]);
    else {
        int size=1024;setsockopt(out_fd,SOL_SOCKET,SO_SNDBUF,&size,sizeof(size));
        char fill[1024];memset(fill,'x',sizeof(fill));
        while(send(out_fd,fill,sizeof(fill),MSG_DONTWAIT|MSG_NOSIGNAL)>0) {}
        if(errno!=EAGAIN && errno!=EWOULDBLOCK) return 68;
    }
    pthread_t thread;
    if(pthread_create(&thread,NULL,run,NULL)) return 69;
    for(int i=0;i<2000&&!atomic_load(&initialized_flag);i++) pause_ms();
    if(!atomic_load(&initialized_flag)) return 70;
    if(!closed) {
        if(controlled) {
            for(int i=0;i<2000&&atomic_load(&polls)<3;i++) pause_ms();
            if(atomic_load(&polls)<3) return 71;
        } else {for(int i=0;i<100;i++) pause_ms();}
        atomic_store(&stop_flag,1);
    }
    struct timespec deadline;clock_gettime(CLOCK_REALTIME,&deadline);deadline.tv_sec+=2;
    int joined=pthread_timedjoin_np(thread,NULL,&deadline);
    printf("{\"controlled\":%s,\"joined\":%s,\"joinError\":%d,\"apiResult\":%d,\"inputFlagsUnchanged\":%s,\"flagsUnchanged\":%s,\"callbacks\":%d}\n",
        controlled?"true":"false",joined?"false":"true",joined,result,fcntl(in_fd,F_GETFL)==input_flags?"true":"false",fcntl(out_fd,F_GETFL)==flags?"true":"false",atomic_load(&polls));
    fflush(stdout);
    if(joined) return 1; /* Own test process exit; no product cleanup claim. */
    if(controlled && controlled(config,in_fd,out_fd,initialized,stopping,NULL)!=TEMU_EMBED_OWNER_UNRELEASED) return 72;
    close(input[1]);close(in_fd);close(out_fd);if(!closed)close(peer[1]);
    /* Library and VM allocations deliberately retained until test process end. */
    return result==(closed?TEMU_EMBED_OUTPUT_UNRELEASED:TEMU_EMBED_CANCELLED_UNRELEASED) && fcntl(out_fd,F_GETFL)==-1 ? 0:2;
}
