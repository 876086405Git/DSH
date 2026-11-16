#define _GNU_SOURCE
#include <stdatomic.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include "temu_embed.h"
static atomic_int stop_flag;static int result,infd,outfd;static const char *config;
static int (*controlled)(const char *,int,int,TemuInitialized,TemuShouldStop,void *);
static int stopping(void*p){(void)p;return atomic_load(&stop_flag);}
static void initialized(void*p){(void)p;atomic_store(&stop_flag,1);}
static void *run(void*p){(void)p;result=controlled(config,infd,outfd,initialized,stopping,NULL);return NULL;}
static int count(const char*target){DIR*d=opendir("/proc/self/fd");if(!d)return -1;struct dirent*e;int n=0;while((e=readdir(d))){char p[512],v[4096];snprintf(p,sizeof(p),"/proc/self/fd/%s",e->d_name);ssize_t k=readlink(p,v,sizeof(v)-1);if(k>=0){v[k]=0;if(!strcmp(v,target))n++;}}closedir(d);return n;}
int main(int argc,char**argv){if(argc!=5)return 64;void*lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s",dlerror());return 65;}controlled=dlsym(lib,"temu_embed_run_controlled");void(*fault)(const char*,int)=dlsym(lib,"retire_test_config");int(*flushes)(void)=dlsym(lib,"retire_test_flushes");int(*closes)(void)=dlsym(lib,"retire_test_closes");if(!controlled||!fault)return 66;fault(argv[3],atoi(argv[4]));config=argv[2];int own=open(argv[3],O_RDONLY);if(own<0)return 67;int a[2],b[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,a)||socketpair(AF_UNIX,SOCK_STREAM,0,b))return 68;infd=a[0];outfd=b[0];int af=fcntl(infd,F_GETFL),bf=fcntl(outfd,F_GETFL);pthread_t t;if(pthread_create(&t,NULL,run,NULL))return 69;struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_sec+=5;int joined=pthread_timedjoin_np(t,NULL,&until);if(joined)return 70;int openCount=count(argv[3]);int owner=controlled(config,infd,outfd,NULL,stopping,NULL);char byte;int borrowed=fcntl(infd,F_GETFL)==af&&fcntl(outfd,F_GETFL)==bf&&write(a[1],"x",1)==1&&recv(a[0],&byte,1,MSG_DONTWAIT)==1&&write(b[0],"y",1)==1&&recv(b[1],&byte,1,MSG_DONTWAIT)==1;int stdio=fcntl(0,F_GETFD)>=0&&fcntl(1,F_GETFD)>=0&&fcntl(2,F_GETFD)>=0;close(own);printf("{\"joined\":true,\"apiResult\":%d,\"ownerRetry\":%d,\"diskFdsWithCaller\":%d,\"diskFdsAfterCallerClose\":%d,\"borrowedTransportIntact\":%s,\"stdioIntact\":%s,\"flushCalls\":%d,\"closeCalls\":%d}\n",result,owner,openCount,count(argv[3]),borrowed?"true":"false",stdio?"true":"false",flushes(),closes());return 0;}
