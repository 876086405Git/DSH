/* Actual slirp and UDP FDs; only CLOCK_MONOTONIC is explicitly injected. */
#include "slirp/slirp.h"
#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
static uint64_t fixture_ms;
static unsigned clock_reads, output_packets;
int controlled_clock(clockid_t id, struct timespec *ts)
{
    assert(id == CLOCK_MONOTONIC);
    ts->tv_sec = fixture_ms / 1000;
    ts->tv_nsec = (fixture_ms % 1000) * 1000000;
    clock_reads++; return 0;
}
int slirp_can_output(void *opaque) { (void)opaque; return 1; }
void slirp_output(void *opaque,const uint8_t *packet,int len)
{ (void)opaque; assert(packet && len > 0); output_packets++; }
static Slirp *new_slirp(void)
{
    struct in_addr zero={0},network={htonl(0x0a000200)},mask={htonl(0xffffff00)},host={htonl(0x0a000202)},guest={htonl(0x0a00020f)},dns={htonl(0x0a000203)};
    Slirp *s=slirp_init(0,network,mask,host,NULL,NULL,NULL,guest,dns,NULL);assert(s);return s;
}
static void at(Slirp *s,uint64_t when)
{
    fixture_ms=when;fd_set r,w,e;FD_ZERO(&r);FD_ZERO(&w);FD_ZERO(&e);clock_reads=0;
    slirp_select_poll(s,&r,&w,&e,1);
    assert(clock_reads==1 && curtime==(uint32_t)when);
}
static int listed(Slirp *s, int fd)
{
    for(struct socket*so=s->udb.so_next;so!=&s->udb;so=so->so_next)if(so->s==fd)return 1;
    return 0;
}
static int check_fd(Slirp *s,int fd,int retained)
{
    fd_set r,w,e;FD_ZERO(&r);FD_ZERO(&w);FD_ZERO(&e);int maximum=-1;
    slirp_select_fill(s,&maximum,&r,&w,&e);
    int found=listed(s,fd);errno=0;int status=fcntl(fd,F_GETFD),error=errno;
    return found==retained && (retained?(status>=0):(status==-1&&error==EBADF));
}
static struct socket *attached(Slirp *s)
{
    struct socket*so=socreate(s);assert(so);assert(udp_attach(so)>=0);so->so_type=IPPROTO_UDP;return so;
}
static void clean(Slirp*s)
{
    while(s->udb.so_next!=&s->udb)udp_detach(s->udb.so_next);
    slirp_cleanup(s);
}
static unsigned failures;
static void result(const char*name,int passed,uint64_t start,uint64_t check,uint32_t expiry)
{
    printf("{\"case\":\"%s\",\"passed\":%s,\"startMs\":%llu,\"checkMs\":%llu,\"legacyDeadlineLow32\":%u,\"actualUdpFd\":true,\"clockReadsPerPoll\":1}\n",name,passed?"true":"false",(unsigned long long)start,(unsigned long long)check,expiry);
    failures+=!passed;
}
static void attach_cases(void)
{
    const struct{const char*name;uint64_t start,elapsed;int retained;} cases[]={
        {"ordinary-new",1000,0,1},{"ordinary-before-expiry",1000,SO_EXPIRE-1,1},{"ordinary-exact-expiry",1000,SO_EXPIRE,0},
        {"wrap-new",UINT32_MAX-1000ULL,0,1},{"wrap-before-expiry",UINT32_MAX-1000ULL,SO_EXPIRE-1,1},{"wrap-exact-expiry",UINT32_MAX-1000ULL,SO_EXPIRE,0},
        {"deadline-zero-new",UINT64_C(0x100000000)-SO_EXPIRE,0,1},{"deadline-zero-before",UINT64_C(0x100000000)-SO_EXPIRE,SO_EXPIRE-1,1},
        {"deadline-zero-at-zero",UINT64_C(0x100000000)-SO_EXPIRE,SO_EXPIRE,0},
        {"deadline-zero-after",UINT64_C(0x100000000)-SO_EXPIRE,SO_EXPIRE+1,0},
        {"now-zero-after-wrap",UINT64_C(0x100000000),SO_EXPIRE,0},
        {"pause-over-signed-half-cycle",1000,UINT64_C(0x80000000)+500000,0},
        {"pause-over-full32-cycle",1000,UINT64_C(0x100000000)+100,0},
        {"two-full32-cycles",UINT32_MAX-1000ULL,UINT64_C(0x200000000)+10,0}
    };
    for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++){
        Slirp*s=new_slirp();at(s,cases[i].start);struct socket*so=attached(s);int fd=so->s;uint32_t expiry=so->so_expire;
        at(s,cases[i].start+cases[i].elapsed);int passed=check_fd(s,fd,cases[i].retained);
        result(cases[i].name,passed,cases[i].start,cases[i].start+cases[i].elapsed,expiry);clean(s);
    }
}
static void listener_cases(void)
{
    const uint64_t starts[]={1000,UINT32_MAX-1000ULL,UINT64_C(0x100000000)-SO_EXPIRE};
    for(unsigned i=0;i<3;i++)for(unsigned permanent=0;permanent<2;permanent++){
        Slirp*s=new_slirp();at(s,starts[i]);struct socket*so=udp_listen(s,htonl(INADDR_LOOPBACK),0,htonl(0x0a00020f),htons(30000),permanent?SS_HOSTFWD:SS_FACCEPTONCE);assert(so);int fd=so->s;uint32_t expiry=so->so_expire;
        at(s,starts[i]+SO_EXPIRE);int passed=check_fd(s,fd,permanent);
        if(permanent){at(s,starts[i]+UINT64_C(0x200000000)+SO_EXPIRE);passed &= check_fd(s,fd,1);}
        char name[64];snprintf(name,sizeof(name),"listener-%s-%u",permanent?"permanent":"accept-once",i);result(name,passed,starts[i],starts[i]+SO_EXPIRE,expiry);clean(s);
    }
}
static void renew_send(void)
{
    for(unsigned zero=0;zero<3;zero++){
        uint64_t start=zero==2?UINT64_C(0x100000000)-SO_EXPIRE-100:(zero?UINT64_C(0x100000000)-SO_EXPIRE:UINT32_MAX-1000ULL);
        Slirp*s=new_slirp();at(s,start);struct socket*so=attached(s);int fd=so->s;
        int peer=socket(AF_INET,SOCK_DGRAM,0);assert(peer>=0);struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr={htonl(INADDR_LOOPBACK)},.sin_port=0};assert(bind(peer,(void*)&addr,sizeof(addr))==0);socklen_t length=sizeof(addr);assert(getsockname(peer,(void*)&addr,&length)==0);
        so->so_faddr=addr.sin_addr;so->so_fport=addr.sin_port;
        uint64_t renewal=zero==2?start+100:start+SO_EXPIRE-1;at(s,renewal);struct mbuf*m=m_get(s);assert(m);m->m_len=4;memcpy(m->m_data,"ping",4);assert(sosendto(so,m)==0);m_free(m);
        char buf[8];assert(recv(peer,buf,sizeof(buf),0)==4&&!memcmp(buf,"ping",4));uint32_t expiry=so->so_expire;
        at(s,renewal+SO_EXPIRE-1);int passed=check_fd(s,fd,1);
        at(s,renewal+SO_EXPIRE);passed &= check_fd(s,fd,0);
        result(zero==2?"send-creates-zero-deadline":(zero?"send-renews-zero-deadline":"send-renews-across-wrap"),passed,start,renewal+SO_EXPIRE,expiry);close(peer);clean(s);
    }
}
static void renew_receive(void)
{
    for(unsigned dns=0;dns<2;dns++)for(unsigned zero=0;zero<3;zero++){
        uint64_t duration=dns?SO_EXPIREFAST:SO_EXPIRE;
        uint64_t start=zero==2?UINT64_C(0x100000000)-duration-100:(zero?UINT64_C(0x100000000)-SO_EXPIRE:UINT32_MAX-1000ULL);
        Slirp*s=new_slirp();at(s,start);struct socket*so=attached(s);int fd=so->s;
        struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr={htonl(INADDR_LOOPBACK)},.sin_port=0};
        assert(bind(fd,(void*)&addr,sizeof(addr))==0);socklen_t len=sizeof(addr);assert(getsockname(fd,(void*)&addr,&len)==0);
        int peer=socket(AF_INET,SOCK_DGRAM,0);assert(peer>=0);
        /* The foreign-port metadata selects the real DNS/normal renewal branch;
         * payload delivery uses an ephemeral loopback peer, not a DNS service. */
        so->so_fport=htons(dns?53:30001);so->so_faddr.s_addr=htonl(INADDR_LOOPBACK);
        so->so_laddr.s_addr=htonl(0x0a00020f);so->so_lport=htons(30002);
        uint64_t renewal=zero==2?start+100:start+SO_EXPIRE-1;at(s,renewal);
        assert(sendto(peer,"reply",5,0,(void*)&addr,sizeof(addr))==5);
        sorecvfrom(so);uint32_t expiry=so->so_expire;
        at(s,renewal+duration-1);int passed=check_fd(s,fd,1);
        at(s,renewal+duration);passed &= check_fd(s,fd,0);
        char name[80];snprintf(name,sizeof(name),"recv-%s-renews-%s",dns?"DNS10s":"normal240s",zero==2?"creates-zero":(zero?"zero-deadline":"wrap"));
        result(name,passed,start,renewal+duration,expiry);close(peer);clean(s);
    }
}
static void permanent_traffic(void)
{
    Slirp*s=new_slirp();uint64_t start=UINT64_C(0x100000000)-SO_EXPIRE;at(s,start);
    struct socket*so=udp_listen(s,htonl(INADDR_LOOPBACK),0,htonl(0x0a00020f),htons(30000),SS_HOSTFWD);assert(so);int fd=so->s;
    struct sockaddr_in target; socklen_t length=sizeof(target);assert(getsockname(fd,(void*)&target,&length)==0);
    int peer=socket(AF_INET,SOCK_DGRAM,0);assert(peer>=0);struct sockaddr_in addr={.sin_family=AF_INET,.sin_addr={htonl(INADDR_LOOPBACK)},.sin_port=0};
    assert(bind(peer,(void*)&addr,sizeof(addr))==0);assert(getsockname(peer,(void*)&addr,&length)==0);
    so->so_faddr=addr.sin_addr;so->so_fport=addr.sin_port;
    at(s,start+100);struct mbuf*m=m_get(s);assert(m);m->m_len=4;memcpy(m->m_data,"ping",4);assert(sosendto(so,m)==0);m_free(m);char payload[8];assert(recv(peer,payload,sizeof(payload),0)==4);
    so->so_fport=htons(53);assert(sendto(peer,"reply",5,0,(void*)&target,sizeof(target))==5);sorecvfrom(so);
    uint32_t expiry=so->so_expire;uint64_t after=start+UINT64_C(0x200000000)+SO_EXPIRE;at(s,after);
    int passed=expiry==0 && check_fd(s,fd,1);result("permanent-listener-send-recv-stays-permanent",passed,start,after,expiry);close(peer);clean(s);
}
static void failed_send(void)
{
    Slirp*s=new_slirp();uint64_t start=1000;at(s,start);struct socket*so=attached(s);int fd=so->s;
    so->so_faddr.s_addr=htonl(INADDR_LOOPBACK);so->so_fport=0;at(s,start+SO_EXPIRE-1);
    struct mbuf*m=m_get(s);assert(m);m->m_len=4;memcpy(m->m_data,"ping",4);assert(sosendto(so,m)==-1);m_free(m);
    uint32_t expiry=so->so_expire;at(s,start+SO_EXPIRE);int passed=check_fd(s,fd,0);result("failed-send-does-not-renew",passed,start,start+SO_EXPIRE,expiry);clean(s);
}
int main(void)
{
    attach_cases();listener_cases();renew_send();renew_receive();permanent_traffic();failed_send();
    return failures?1:0;
}
