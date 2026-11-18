#define _GNU_SOURCE
#include <stdatomic.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include "temu_embed.h"
static atomic_int stop_flag;
static int result,in_fd,out_fd;
static const char *config;
static int (*controlled)(const char *,int,int,TemuInitialized,TemuShouldStop,void *);
static int stopping(void *p) {(void)p;return atomic_load(&stop_flag);}
static void *run(void *p) {(void)p;result=controlled(config,in_fd,out_fd,NULL,stopping,NULL);return NULL;}
static int disk_fds(void) {
 DIR *d=opendir("/proc/self/fd");if(!d)return -1;struct dirent *e;int n=0;
 while((e=readdir(d))){char p[512],v[4096];snprintf(p,sizeof(p),"/proc/self/fd/%s",e->d_name);ssize_t k=readlink(p,v,sizeof(v)-1);if(k<0)continue;v[k]=0;
 if(strstr(v,"/bootstrap.ext4")||strstr(v,"/target.ext4")||strstr(v,"/download.block"))n++;}
 closedir(d);return n;
}
int main(int argc,char **argv) {
 if(argc!=4 && argc!=5)return 64;
 void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s",dlerror());return 65;}
 controlled=dlsym(lib,"temu_embed_run_controlled");if(!controlled)return 66;
 config=argv[2];int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 67;
 int input[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,input))return 70;
 in_fd=input[0];out_fd=pair[0];
 int input_flags=fcntl(in_fd,F_GETFL),output_flags=fcntl(out_fd,F_GETFL);
 FILE *console=fopen(argv[3],"wb");if(!console)return 68;
 pthread_t thread;if(pthread_create(&thread,NULL,run,NULL))return 69;
 char tail[8192]={0};size_t held=0;int ready=0;
 struct timespec start,now;clock_gettime(CLOCK_MONOTONIC,&start);
 while(!ready) {
   struct pollfd p={pair[1],POLLIN,0};int n=poll(&p,1,100);
   if(n>0){char b[4096];ssize_t k=recv(pair[1],b,sizeof(b),MSG_DONTWAIT);
     if(k>0){fwrite(b,1,k,console);fflush(console);
       if(held+(size_t)k>=sizeof(tail)){size_t keep=64;memmove(tail,tail+held-keep,keep);held=keep;}
       memcpy(tail+held,b,k);held+=(size_t)k;tail[held]=0;
       ready=strstr(tail,"__906_INSTALLED__")!=NULL;
       if(strstr(tail,"__906_READONLY_FAILED__") || strstr(tail,"__906_INSTALL_FAILED__")) break;
     }
   }
   clock_gettime(CLOCK_MONOTONIC,&now);if(now.tv_sec-start.tv_sec>90)break;
 }
 if(argc==5)close(input[1]);else atomic_store(&stop_flag,1);
 struct timespec deadline;clock_gettime(CLOCK_REALTIME,&deadline);deadline.tv_sec+=5;
 int joined=pthread_timedjoin_np(thread,NULL,&deadline);fclose(console);
 printf("{\"openDiskFds\":%d,\"installCompleted\":%s,\"joined\":%s,\"apiResult\":%d,\"inputFlagsUnchanged\":%s,\"outputFlagsUnchanged\":%s}\n",disk_fds(),ready?"true":"false",joined?"false":"true",result,fcntl(in_fd,F_GETFL)==input_flags?"true":"false",fcntl(out_fd,F_GETFL)==output_flags?"true":"false");
 return ready&&!joined&&result==(argc==5?-7:-4)?0:1;
}
