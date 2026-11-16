#include "workspace_fids.h"
#include "workspace_grants_abi.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <thread>
std::mutex m;std::condition_variable cv;bool entered=false,proceed=false;std::atomic<bool> block_write{false},fail_close{false};
extern "C" ssize_t __real_pwrite(int,const void*,size_t,off_t);
extern "C" int __real_close(int);
extern "C" ssize_t __wrap_pwrite(int fd,const void* data,size_t size,off_t offset){if(block_write.exchange(false)){std::unique_lock<std::mutex> lock(m);entered=true;cv.notify_all();cv.wait(lock,[]{return proceed;});}return __real_pwrite(fd,data,size,offset);}
extern "C" int __wrap_close(int fd){int result=__real_close(fd);if(fail_close.exchange(false)){errno=EIO;return -1;}return result;}
void check(bool yes,const char* label){printf("%s %s\n",yes?"PASS":"FAIL",label);if(!yes)exit(1);}
int main(int argc,char** argv){if(argc!=2)return 2;auto& owner=dsh::WorkspaceGrantOwner();int rootfd=open(argv[1],O_RDONLY|O_DIRECTORY);owner.Publish("barrier",1,rootfd,true);std::string ticket(64,'b');check(dsh_workspace_ticket_issue(ticket.c_str(),"barrier",1,1)==0,"ticket");auto lease=std::shared_ptr<dsh::WorkspaceLease>(static_cast<dsh::WorkspaceLease*>(dsh_workspace_ticket_consume(ticket.c_str())));auto root=dsh::WorkspaceFid::Root(lease);auto file=root->Create("during-write");block_write=true;std::atomic<bool> retired{false};int result=-2;std::thread writer([&]{file->Write(0,"completed-before-retire");});{std::unique_lock<std::mutex> lock(m);cv.wait(lock,[]{return entered;});}std::thread retirer([&]{result=dsh_workspace_ticket_retire(ticket.c_str());retired=true;});std::this_thread::sleep_for(std::chrono::milliseconds(30));check(!retired,"retire waits for actual in-flight pwrite");{std::lock_guard<std::mutex> lock(m);proceed=true;}cv.notify_all();writer.join();retirer.join();check(result==0,"retired task retains FID debt");int fd=openat(rootfd,"during-write",O_RDONLY);char data[64]{};auto n=read(fd,data,sizeof(data));close(fd);check(n==23&&std::string(data,n)=="completed-before-retire","pre-barrier write exists in actual host file");try{file->Write(0,"forbidden");check(false,"post-retire write");}catch(const dsh::GrantError&e){check(e.code=="ERR_WORKSPACE_TASK_RETIRED","post-retire write denied");}lease.reset();root.reset();fail_close=true;file.reset();check(dsh_workspace_ticket_retire(ticket.c_str())==0,"close failure retains task debt");try{owner.Acquire("barrier",1,true);check(false,"close quarantine");}catch(const dsh::GrantError&e){check(e.code=="ERR_WORKSPACE_CLOSE_FAILED","close debt rejects new admission");}auto status=owner.Retire("barrier",1);check(!status.drained&&status.leases==0,"close failure quarantines grant despite zero leases");close(rootfd);}
