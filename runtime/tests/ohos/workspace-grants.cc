#include "../../../app/ohos/entry/src/main/cpp/workspace_grants.h"
#include "../../../app/ohos/entry/src/main/cpp/file_access.h"
#include <fstream>
#include <iostream>
#include <functional>
#include <filesystem>
#include <thread>
#include <atomic>
#include <future>
#include <condition_variable>
#include "../../../app/ohos/entry/src/main/cpp/workspace_grants_abi.h"
std::mutex pause_mutex;std::condition_variable pause_cv;bool pause_read=false,read_entered=false,read_resume=false;
extern "C" ssize_t __real_pread(int,void*,size_t,off_t);
extern "C" ssize_t __wrap_pread(int fd,void* data,size_t size,off_t offset){
 {std::unique_lock<std::mutex> lock(pause_mutex);if(pause_read){read_entered=true;pause_cv.notify_all();pause_cv.wait(lock,[]{return read_resume;});}}
 return __real_pread(fd,data,size,offset);
}
using namespace dsh;
int passed=0;
void ok(bool value,const char* name){if(!value)throw std::runtime_error(name);++passed;std::cout<<"PASS "<<name<<"\n";}
void denied(std::function<void()> work,const char* name){bool rejected=false;try{work();}catch(const std::exception&){rejected=true;}ok(rejected,name);}
int main(int argc,char**argv){try{
 if(argc!=2)throw std::runtime_error("private fixture root required");
 std::string root=argv[1];if(std::filesystem::exists(root))throw std::runtime_error("fixture root must be fresh");std::filesystem::create_directories(root+"/inside/sub");
 std::ofstream(root+"/outside")<<"OUTSIDE";std::ofstream(root+"/inside/file")<<"ORIGINAL";
 symlink("../outside",(root+"/inside/link").c_str());symlink("../..",(root+"/inside/sub/out").c_str());
 grant_detail::Fd directory(open((root+"/inside").c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC));
 WorkspaceGrants registry;registry.Publish("owner:grant",1,directory.fd,true);
 auto rw=registry.Acquire("owner:grant",1,true),ro=registry.Acquire("owner:grant",1,false);
 ok(ro->Read("file",0,100)=="ORIGINAL","read actual pinned root");
 denied([&]{ro->Write("file","bad",0);},"task RO intersects grant RW");
 ok(rw->Write("file","NEW",0,false,true)==3&&ro->Read("file",0,10)=="NEW","truncate after regular-file validation");
 rw->Mkdir("newdir");rw->Write("newdir/a","CREATE",0,true);rw->Rename("newdir/a","sub/moved");
 ok(ro->Read("sub/moved",0,100)=="CREATE","create rename read same owner");
 rw->Remove("sub/moved");rw->Remove("newdir",true);ok(!std::filesystem::exists(root+"/inside/sub/moved"),"delete real file and directory");
 for(const std::string bad:{"../outside","sub/out/outside","link","/etc/passwd","sub//x","sub/../file","file/"})denied([&]{ro->Read(bad,0,8);},bad.c_str());
 denied([&]{rw->Write("link","bad",0,false,true);},"link write cannot truncate outside");
 std::ifstream out(root+"/outside");std::string text;out>>text;ok(text=="OUTSIDE","outside bytes unchanged");
 rw->Rename("link","renamed-link");ok(std::filesystem::is_symlink(root+"/inside/renamed-link"),"rename moves final link rather than target");
 rw->Remove("renamed-link");ok(std::filesystem::exists(root+"/outside"),"unlink removes link rather than target");
 // Actual legacy descriptor demonstrates why retiring strings is insufficient.
 int legacy=OpenUserFile(root+"/inside","file");auto state=registry.Retire("owner:grant",1);
 char bytes[3];ok(pread(legacy,bytes,3,0)==3,"legacy open fd survives grant retirement (red witness)");close(legacy);
 ok(!state.active&&!state.drained&&state.leases==2,"retire closes admission but reports live leases");
 denied([&]{rw->Write("file","bad",0);},"held write lease rejected after retirement");
 denied([&]{ro->Read("file",0,3);},"held read lease rejected after retirement");
 denied([&]{registry.Acquire("owner:grant",1,false);},"queued old generation rejected");
 denied([&]{registry.Publish("owner:grant",2,directory.fd,true);},"replacement waits for leases");
 rw.reset();ro.reset();ok(registry.Status("owner:grant",1).drained,"D only after actual lease release");
 registry.Publish("owner:grant",2,directory.fd,false);denied([&]{registry.Acquire("owner:grant",1,false);},"same directory cannot revive old generation");
 denied([&]{registry.Acquire("owner:grant",2,true);},"OS RO cannot grant writable task");
 auto next=registry.Acquire("owner:grant",2,false);
 std::filesystem::rename(root+"/inside",root+"/moved-root");std::filesystem::create_directory(root+"/inside");std::ofstream(root+"/inside/file")<<"REPLACED";
 ok(next->Read("file",0,10)=="NEW","directory object survives root rename without aliasing replacement");
 next.reset();registry.Retire("owner:grant",2);ok(registry.Status("owner:grant",2).drained,"final root actually closed");
 // True concurrent syscall barrier: the wrapper delays but ultimately invokes
 // the real pread; retire must wait for this accepted I/O before returning R.
 WorkspaceGrantOwner().Publish("abi",1,directory.fd,true);
 void* abi=dsh_workspace_acquire("abi",1,1);ok(abi!=nullptr,"C ABI acquires same singleton owner");
 ok(dsh_workspace_write(abi,"file",0,"ABI",3,0,1)==3,"C ABI writes real file");
 {std::lock_guard<std::mutex> lock(pause_mutex);pause_read=true;}
 auto reading=std::async(std::launch::async,[&]{char data[3];return dsh_workspace_read(abi,"file",0,data,3);});
 {std::unique_lock<std::mutex> lock(pause_mutex);pause_cv.wait(lock,[]{return read_entered;});}
 std::promise<void> retiring;auto ready=retiring.get_future();
 auto retirement=std::async(std::launch::async,[&]{retiring.set_value();return WorkspaceGrantOwner().Retire("abi",1);});ready.wait();
 ok(retirement.wait_for(std::chrono::milliseconds(50))==std::future_status::timeout,"retire waits for actual in-flight read");
 {std::lock_guard<std::mutex> lock(pause_mutex);read_resume=true;pause_cv.notify_all();}
 ok(reading.get()==3,"admitted read completes before R");ok(!retirement.get().active,"R returned only after in-flight operation");
 ok(dsh_workspace_write(abi,"file",0,"BAD",3,0,0)==-1&&std::string(dsh_workspace_error())=="ERR_WORKSPACE_RETIRED","C ABI old handle cannot write after R");
 dsh_workspace_release(abi);ok(WorkspaceGrantOwner().Status("abi",1).drained,"C ABI release closes D barrier");
 std::cout<<passed<<" PASS\n";return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 1;}}
