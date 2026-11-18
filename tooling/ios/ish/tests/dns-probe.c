#include "guest_backend.h"
#include "guest_dns.h"
#include <stdio.h>
#include <stdint.h>
#include <stdatomic.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
static uint64_t id; static _Atomic int ready;static char captured[4096];static size_t used;
static int output(void*c,int stream,uint64_t end,const void*b,size_t n){while(!atomic_load(&ready))usleep(100);fwrite(b,1,n,stream==1?stdout:stderr);if(stream==1&&used+n<sizeof captured){memcpy(captured+used,b,n);used+=n;captured[used]=0;}return dsh_guest_ack(id,stream,end);}
static int job(char**argv,const char*command,int expected){const char*env[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin"};const char*args[]={"/bin/sh","-c",command};struct dsh_guest_request r={args,3,env,1,"/workspace",argv[2],argv[3],0};atomic_store(&ready,0);used=0;captured[0]=0;int e=dsh_guest_start(&r,output,0,&id);atomic_store(&ready,1);printf("start=%d expected=%d id=%llu state=%d\n",e,expected,(unsigned long long)id,dsh_guest_status());if(e!=expected)return 1;if(e)return id!=0||dsh_guest_status()!=DSH_GUEST_READY;dsh_guest_stdin_close(id);struct dsh_guest_result result;e=dsh_guest_wait(id,2000,&result);return e||result.exit_code||!result.resources_settled;}
#define CHECK(x) do{if(x){fprintf(stderr,"FAILED line %d\n",__LINE__);return 1;}}while(0)
int main(int argc,char**argv){if(argc!=5)return 90;const char*deny[]={argv[4]};struct dsh_guest_options o={argv[1],deny,1};CHECK(dsh_guest_initialize(&o));
char buf[128];const char*bad[]={"1.2.3.4\nsearch bad"};CHECK(dsh_dns_format(bad,1,buf,sizeof buf)!=EINVAL);const char*valid[]={"192.0.2.1"};CHECK(dsh_dns_format(valid,1,buf,2)!=ENOSPC);
CHECK(job(argv,"cat /etc/resolv.conf",0));CHECK(strcmp(captured,"nameserver 192.0.2.1\nnameserver 2001:db8::53\n"));
setenv("DSH_TEST_DNS","changed",1);CHECK(job(argv,"cat /etc/resolv.conf",0));CHECK(strcmp(captured,"nameserver 192.0.2.2\nnameserver 2001:db8::53\n"));
setenv("DSH_TEST_DNS","absent",1);CHECK(job(argv,"cat /etc/resolv.conf; uname -m",0));CHECK(strstr(captured,"nameserver")!=NULL);CHECK(!strstr(captured,"No usable system DNS"));CHECK(!strstr(captured,"aarch64"));
setenv("DSH_TEST_DNS","invalid",1);CHECK(job(argv,"echo should-not-run",EINVAL));
unsetenv("DSH_TEST_DNS");
const char*attack=getenv("DSH_TEST_ATTACK");
if(attack && !strcmp(attack,"parent")){
 CHECK(job(argv,"mv /etc /etc-original; ln -s /workspace /etc",0));CHECK(job(argv,"echo should-not-run",EPERM));
}else if(attack && !strcmp(attack,"pending")){
 CHECK(job(argv,"printf sentinel > /etc/.dsh-resolv.conf; printf unknown > /etc/.dsh-resolv.conf.5; ln -s /workspace/sentinel /etc/.dsh-resolv.conf.6",0));CHECK(job(argv,"cat /etc/resolv.conf",0));
}else{
 CHECK(job(argv,"cat /etc/resolv.conf; rm /etc/resolv.conf; ln -s /workspace/sentinel /etc/resolv.conf",0));CHECK(job(argv,"echo should-not-run",EPERM));
}
printf("DNS real fakefs create/readback/refresh and absent/invalid/path failure gates PASS\n");return 0;}
