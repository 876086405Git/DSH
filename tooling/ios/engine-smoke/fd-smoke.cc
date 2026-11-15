// Standalone Simulator fd smoke. Loads the prepared product framework; no Node rebuild.
// Expected behavior is f9d0bd3: raw fd retention is accepted, host fd loss is forbidden.
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <string>
#include <thread>
#include <vector>
#include <atomic>
using Start = int(*)(int,char**);
using Stop = int(*)();
struct Row {std::string state,kind; int fd; unsigned long long dev,ino;};
static bool Identity(int fd,unsigned long long dev,unsigned long long ino) {
 struct stat s{};return fstat(fd,&s)==0 && static_cast<unsigned long long>(s.st_dev)==dev && static_cast<unsigned long long>(s.st_ino)==ino;
}
// Reserve only a currently free number. Never replace an existing descriptor.
static int ReserveExact(int source,int target) {
 const int duplicate=fcntl(source,F_DUPFD_CLOEXEC,target);
 if(duplicate==target)return duplicate;
 if(duplicate>=0)close(duplicate);
 return -1;
}
static int RunProbe(const char* root,const char* preload,const char* script,int rounds,Start start,Stop stop) {
 if(!root||root[0]!='/'||!preload||!script||rounds<1||rounds>20)return 64;
 if(mkdir(root,0700)!=0 && errno!=EEXIST)return 65;
 const std::string dir(root),ready=dir+"/ready.txt";bool all=true;
 std::vector<Row> retained;
 for(int run=1;run<=rounds;run++) {
  unlink(ready.c_str());{std::ofstream f(dir+"/round.txt");f<<run;}
  std::atomic<bool> ended{false};int code=-1;
  std::vector<std::string> args={"node","--jitless","--import",preload,script,root};std::vector<char*> argv;
  for(auto& a:args)argv.push_back(a.data());
  std::thread engine([&]{code=start(static_cast<int>(argv.size()),argv.data());ended=true;});
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(90);
  while(access(ready.c_str(),F_OK)!=0 && !ended && std::chrono::steady_clock::now()<deadline)std::this_thread::sleep_for(std::chrono::milliseconds(10));
  std::vector<Row> rows;{std::ifstream f(ready);Row row;while(f>>row.state>>row.kind>>row.fd>>row.dev>>row.ino)rows.push_back(row);}
  bool prepared=rows.size()==26;std::vector<int> sentinels;
  // Keep the source well above every JS descriptor, without touching unrelated fds.
  int low=open((dir+"/host-sentinel-"+std::to_string(run)).c_str(),O_CREAT|O_RDWR|O_TRUNC,0600);
  int minimum=64;for(const auto& r:rows)if(r.fd+16>minimum)minimum=r.fd+16;
  int source=low<0?-1:fcntl(low,F_DUPFD_CLOEXEC,minimum);if(low>=0)close(low);
  struct stat sentinel{};if(source<0||fstat(source,&sentinel)!=0)prepared=false;
  for(const auto& r:rows)if(r.state=="OPEN" && !Identity(r.fd,r.dev,r.ino))prepared=false;
  for(const auto& r:rows)if(r.state=="CLOSED") {
   errno=0;
   // Only duplicate onto a descriptor proven absent while diagnostic JS is idle.
   if(fcntl(r.fd,F_GETFD)!=-1 || errno!=EBADF || source<0){prepared=false;continue;}
   // Atomically reserve a free number; never overwrite a racing native owner.
   const int duplicate=ReserveExact(source,r.fd);
   if(duplicate<0){prepared=false;continue;}
   sentinels.push_back(duplicate);
  }

  const int requested=stop();engine.join();
  int leaked=0,closed=0,reused=0,lost=0,rawOpen=0,handleOpen=0,handleClosed=0;
  for(const auto& r:rows)if(r.state=="OPEN") {
   errno=0;const int valid=fcntl(r.fd,F_GETFD);
   if(valid==-1&&errno==EBADF){closed++;if(r.kind=="handle")handleClosed++;}
   else if(Identity(r.fd,r.dev,r.ino)){leaked++;if(r.kind=="handle")handleOpen++;else rawOpen++;}
   else reused++;
  }
  for(int fd:sentinels)if(!Identity(fd,sentinel.st_dev,sentinel.st_ino))lost++;
  const bool hostSourceAlive=source>=0&&Identity(source,sentinel.st_dev,sentinel.st_ino);
  for(const auto& r:rows)if(r.state=="OPEN"&&r.kind!="handle"&&Identity(r.fd,r.dev,r.ino))retained.push_back(r);
  int retainedOpen=0;for(const auto& r:retained)if(Identity(r.fd,r.dev,r.ino))retainedOpen++;
  const bool pass=prepared&&requested==1&&code==0&&closed==2&&reused==0&&leaked==16&&rawOpen==16&&handleClosed==2&&handleOpen==0&&sentinels.size()==8&&lost==0&&hostSourceAlive&&retainedOpen==16*run;
  std::printf("{\"run\":%d,\"pid\":%ld,\"prepared\":%s,\"stopRequested\":%d,\"engineCode\":%d,\"ownedClosed\":%d,\"ownedStillOpen\":%d,\"ownedNumberReused\":%d,\"sentinels\":%zu,\"sentinelsLost\":%d,\"hostSourceAlive\":%s,\"rawOpenTotal\":%d,\"rawStillOpen\":%d,\"fileHandleClosed\":%d,\"fileHandleStillOpen\":%d,\"pass\":%s}\n",run,static_cast<long>(getpid()),prepared?"true":"false",requested,code,closed,leaked,reused,sentinels.size(),lost,hostSourceAlive?"true":"false",retainedOpen,rawOpen,handleClosed,handleOpen,pass?"true":"false");std::fflush(stdout);
  all&=pass;
  // Clean up only descriptors whose identity remains this fixture's file.
  for(int fd:sentinels)if(Identity(fd,sentinel.st_dev,sentinel.st_ino))close(fd);
  if(hostSourceAlive)close(source);
  // Retain raw fds across rounds to measure the accepted accumulation directly.
  if(!prepared||code!=0)break;
 }
 for(const auto& r:retained)if(Identity(r.fd,r.dev,r.ino))close(r.fd);
 return all?0:1;
}
#include <dlfcn.h>
#include <cstdlib>
static bool ReservationControl(const std::string& root) {
 mkdir(root.c_str(),0700);
 int source=open((root+"/source").c_str(),O_CREAT|O_RDWR|O_TRUNC,0600);
 int other=open((root+"/other").c_str(),O_CREAT|O_RDWR|O_TRUNC,0600);
 struct stat owner{};const bool ownerReady=other>=0&&fstat(other,&owner)==0;
 int target=source<0?-1:fcntl(source,F_DUPFD_CLOEXEC,64);if(target>=0)close(target);
 errno=0;const bool absent=target>=0&&fcntl(target,F_GETFD)==-1&&errno==EBADF;
 const int occupant=other<0?-1:fcntl(other,F_DUPFD_CLOEXEC,target);
 const int reserved=source<0?-1:ReserveExact(source,target);
 const bool preserved=ownerReady&&occupant==target&&Identity(target,owner.st_dev,owner.st_ino);
 const bool pass=absent&&reserved<0&&preserved;
 std::printf("{\"control\":\"occupied-target\",\"checkedAbsent\":%s,\"prepared\":%s,\"ownerPreserved\":%s,\"pass\":%s}\n",absent?"true":"false",reserved>=0?"true":"false",preserved?"true":"false",pass?"true":"false");
 if(reserved>=0)close(reserved);if(occupant>=0)close(occupant);if(other>=0)close(other);if(source>=0)close(source);
 return pass;
}
static int RunMain(int argc,char** argv) {
 if(argc!=6){std::fprintf(stderr,"usage: fd-smoke <host library> <new fixture directory> <preload> <main script> <rounds>\n");return 64;}
 char* end=nullptr;const long rounds=std::strtol(argv[5],&end,10);
 if(!end||*end||rounds<1||rounds>20)return 64;
 // Bound a stuck Stop inside the actual simulator process, not only its xcrun parent.
 std::thread([rounds]{std::this_thread::sleep_for(std::chrono::seconds(120*rounds+30));std::fprintf(stderr,"FD_SMOKE_DEADLINE\n");_exit(124);}).detach();
 if(mkdir(argv[2],0700)!=0){std::perror("new fixture directory");return 65;}
 if(!ReservationControl(std::string(argv[2])+"/reservation"))return 1;
 // Test process only: no inherited CLI options or DSH overlay is part of this probe.
 unsetenv("NODE_OPTIONS");unsetenv("DSH_IOS_SMOKE_PATCH");unsetenv("DSH_IOS_SMOKE_IMPORT");
 void* host=dlopen(argv[1],RTLD_NOW|RTLD_GLOBAL);
 if(!host){std::fprintf(stderr,"fd-smoke dlopen: %s\n",dlerror());return 70;}
 auto start=reinterpret_cast<Start>(dlsym(host,"dsh_node_start"));
 auto stop=reinterpret_cast<Stop>(dlsym(host,"dsh_node_stop"));
 if(!start||!stop){std::fprintf(stderr,"fd-smoke missing runner C API\n");return 70;}
 return RunProbe(argv[2],argv[3],argv[4],static_cast<int>(rounds),start,stop);
}
#ifdef DSH_FD_SMOKE_LINUX_PRELOAD
using Main=int(*)(int,char**,char**);
using LibcStart=int(*)(Main,int,char**,void(*)(),void(*)(),void(*)(),void*);
static int LinuxMain(int argc,char** argv,char**) {int code=RunMain(argc,argv);std::fflush(nullptr);_exit(code);}
extern "C" __attribute__((visibility("default"))) int __libc_start_main(Main,int argc,char** argv,void(*init)(),void(*fini)(),void(*rtld)(),void* stack) {
 auto start=reinterpret_cast<LibcStart>(dlsym(RTLD_NEXT,"__libc_start_main"));if(!start)std::abort();return start(LinuxMain,argc,argv,init,fini,rtld,stack);
}
#else
int main(int argc,char** argv) {int code=RunMain(argc,argv);std::fflush(nullptr);_exit(code);}
#endif
