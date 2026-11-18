#ifndef DSH_WORKSPACE_FIDS_H
#define DSH_WORKSPACE_FIDS_H
#include "workspace_grants.h"
// Internal native object consumer. No descriptor is exposed to guest or Node.
// One shared admission lease remains live until the last FID disappears.
namespace dsh {
class WorkspaceFid : public std::enable_shared_from_this<WorkspaceFid> {
 std::shared_ptr<WorkspaceLease> lease_;
 std::shared_ptr<WorkspaceFid> parent_;
 std::string name_;int pin_=-1,io_=-1;bool writable_=false,opened_=false;unsigned depth_=0;
 public:
 WorkspaceFid(std::shared_ptr<WorkspaceLease> lease,std::shared_ptr<WorkspaceFid> parent,std::string name,int fd)
 :lease_(std::move(lease)),parent_(std::move(parent)),name_(std::move(name)),pin_(fd),depth_(parent_?parent_->depth_+1:0){}
 private:
 struct TemporaryFd {
  grant_detail::State& state;int fd;
  TemporaryFd(grant_detail::State& s,int descriptor):state(s),fd(descriptor){grant_detail::Check(fd>=0);}
  ~TemporaryFd(){if(fd>=0&&close(fd)!=0)state.close_failed=true;}
  TemporaryFd(const TemporaryFd&)=delete;TemporaryFd& operator=(const TemporaryFd&)=delete;
 };
 static void Name(const std::string& name){if(name.empty()||name=="."||name==".."||name.size()>255||name.find('/')!=std::string::npos||name.find('\0')!=std::string::npos)throw GrantError("ERR_WORKSPACE_PATH");}
 struct stat StatLocked(){struct stat st{};grant_detail::Check(fstat(pin_,&st)==0);return st;}
 void Directory(){if(!S_ISDIR(StatLocked().st_mode))throw GrantError("ERR_WORKSPACE_DIRECTORY");}
 void CloseFd(int& fd){if(fd>=0){int old=fd;fd=-1;if(close(old)!=0)lease_->state_->close_failed=true;}}
 public:
 ~WorkspaceFid(){std::lock_guard<std::mutex> lock(lease_->state_->mutex);CloseFd(io_);CloseFd(pin_);}
 static std::shared_ptr<WorkspaceFid> Root(std::shared_ptr<WorkspaceLease> lease){
  std::lock_guard<std::mutex> lock(lease->state_->mutex);lease->Access(false);
  TemporaryFd fd(*lease->state_,fcntl(lease->state_->root,F_DUPFD_CLOEXEC,0));
  auto result=std::make_shared<WorkspaceFid>(lease,nullptr,"",fd.fd);fd.fd=-1;return result;
 }
 std::shared_ptr<WorkspaceFid> Clone(){
  std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(false);
  TemporaryFd fd(*lease_->state_,fcntl(pin_,F_DUPFD_CLOEXEC,0));
  auto result=std::make_shared<WorkspaceFid>(lease_,parent_,name_,fd.fd);fd.fd=-1;return result;
 }
 std::shared_ptr<WorkspaceFid> Walk(const std::string& name){
  std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(false);Directory();
  if(name==".")return shared_from_this();
  if(name=="..")return parent_?parent_:shared_from_this();
  Name(name);if(depth_>=64)throw GrantError("ERR_WORKSPACE_LIMIT");
  TemporaryFd fd(*lease_->state_,openat(pin_,name.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
  struct stat st{};grant_detail::Check(fstat(fd.fd,&st)==0);
  if(!S_ISREG(st.st_mode)&&!S_ISDIR(st.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  auto result=std::make_shared<WorkspaceFid>(lease_,shared_from_this(),name,fd.fd);fd.fd=-1;return result;
 }
 struct stat Stat(){std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(false);return StatLocked();}
 void Open(bool write,bool truncate=false){
  std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(write||truncate);
  if(opened_)throw GrantError("ERR_WORKSPACE_ALREADY_OPEN");
  auto st=StatLocked();if(!S_ISREG(st.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  if(truncate&&!write)throw GrantError("ERR_WORKSPACE_MODE");
  if(write){if(!parent_)throw GrantError("ERR_WORKSPACE_PATH");
   TemporaryFd fd(*lease_->state_,openat(parent_->pin_,name_.c_str(),O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
   struct stat now{};grant_detail::Check(fstat(fd.fd,&now)==0);
   if(st.st_dev!=now.st_dev||st.st_ino!=now.st_ino)throw GrantError("ERR_WORKSPACE_OBJECT_REPLACED");
   if(truncate)grant_detail::Check(ftruncate(fd.fd,0)==0);
   io_=fd.fd;fd.fd=-1;
  }else{io_=fcntl(pin_,F_DUPFD_CLOEXEC,0);grant_detail::Check(io_>=0);}
  writable_=write;opened_=true;
 }
 std::string Read(uint64_t offset,size_t count){
  if(count>1024*1024||offset>INT64_MAX)throw GrantError("ERR_WORKSPACE_LIMIT");
  std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(false);
  if(!opened_)throw GrantError("ERR_WORKSPACE_NOT_OPEN");
  std::string result(count,'\0');auto n=pread(io_,result.data(),count,offset);grant_detail::Check(n>=0);result.resize(n);return result;
 }
 size_t Write(uint64_t offset,const std::string& bytes){
  if(bytes.size()>1024*1024||offset>INT64_MAX)throw GrantError("ERR_WORKSPACE_LIMIT");
  std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(true);
  if(!opened_||!writable_)throw GrantError("ERR_WORKSPACE_READ_ONLY");
  auto n=pwrite(io_,bytes.data(),bytes.size(),offset);grant_detail::Check(n>=0);return n;
 }
 std::shared_ptr<WorkspaceFid> Create(const std::string& name){
  Name(name);std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(true);Directory();
  if(depth_>=64)throw GrantError("ERR_WORKSPACE_LIMIT");
  TemporaryFd fd(*lease_->state_,openat(pin_,name.c_str(),O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600));
  TemporaryFd io(*lease_->state_,fcntl(fd.fd,F_DUPFD_CLOEXEC,0));
  auto result=std::make_shared<WorkspaceFid>(lease_,shared_from_this(),name,fd.fd);fd.fd=-1;
  result->io_=io.fd;io.fd=-1;
  result->opened_=result->writable_=true;return result;
 }
 void Mkdir(const std::string& name){Name(name);std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(true);Directory();grant_detail::Check(mkdirat(pin_,name.c_str(),0700)==0);}
 void Remove(const std::string& name,bool directory){Name(name);std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(true);Directory();grant_detail::Check(unlinkat(pin_,name.c_str(),directory?AT_REMOVEDIR:0)==0);}
 void Rename(const std::string& name,WorkspaceFid& destination,const std::string& newname){
  Name(name);Name(newname);if(lease_!=destination.lease_)throw GrantError("ERR_WORKSPACE_CROSS_LEASE");
  std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(true);Directory();destination.Directory();
  grant_detail::Check(renameat(pin_,name.c_str(),destination.pin_,newname.c_str())==0);
 }
 std::vector<std::string> List(){std::lock_guard<std::mutex> lock(lease_->state_->mutex);lease_->Access(false);Directory();
  TemporaryFd fd(*lease_->state_,openat(pin_,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));DIR* dir=fdopendir(fd.fd);grant_detail::Check(dir!=nullptr);fd.fd=-1;
  std::vector<std::string> result;int failure=0;
  try{for(;;){errno=0;auto* e=readdir(dir);if(!e){failure=errno;break;}std::string name=e->d_name;if(name=="."||name=="..")continue;
   if(result.size()>=10000)throw GrantError("ERR_WORKSPACE_LIMIT");
   result.push_back(name);}}
  catch(...){if(closedir(dir)!=0)lease_->state_->close_failed=true;throw;}
  if(closedir(dir)!=0){lease_->state_->close_failed=true;grant_detail::Check(false);}if(failure)throw std::system_error(failure,std::generic_category());return result;
 }
};
}
#endif
