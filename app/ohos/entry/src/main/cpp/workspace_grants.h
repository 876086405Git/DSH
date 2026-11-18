#ifndef DSH_WORKSPACE_GRANTS_H
#define DSH_WORKSPACE_GRANTS_H
// Trusted owner API, not a path permission API. No descriptor escapes a lease.
// Directory OBJECT leases: a host rename does not revoke the pinned object.
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <dirent.h>
#include <functional>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <limits>
#include <random>
#include <utility>
#include <stdexcept>
#include <string>
#include <system_error>
#include <vector>
namespace dsh {
class GrantError : public std::runtime_error {
 public: const std::string code;
  GrantError(const char* c):std::runtime_error(c),code(c){}
};
namespace grant_detail {
inline void Check(bool ok) { if(!ok) throw std::system_error(errno,std::generic_category(),"Workspace operation failed"); }
struct Fd {
 int fd; explicit Fd(int n):fd(n){Check(n>=0);} ~Fd(){if(fd>=0)close(fd);}
 Fd(const Fd&)=delete; Fd& operator=(const Fd&)=delete;
};
inline std::vector<std::string> Parts(const std::string& path){
 if(path.empty()||path.front()=='/'||path.find('\0')!=std::string::npos)throw GrantError("ERR_WORKSPACE_PATH");
 std::vector<std::string> out;size_t start=0;
 for(;;){auto end=path.find('/',start);auto part=path.substr(start,end==std::string::npos?end:end-start);
  if(part.empty()||part=="."||part=="..")throw GrantError("ERR_WORKSPACE_PATH");
  out.push_back(part);if(end==std::string::npos)return out;start=end+1;
 }
}
struct State {
 std::mutex mutex; int root=-1; uint64_t generation=0;bool writable=false,active=true,close_failed=false;size_t leases=0;
 ~State(){if(root>=0)close(root);}
 void CheckActive(bool write){if(!active)throw GrantError("ERR_WORKSPACE_RETIRED");if(close_failed)throw GrantError("ERR_WORKSPACE_CLOSE_FAILED");if(write&&!writable)throw GrantError("ERR_WORKSPACE_READ_ONLY");}
};
inline int Parent(int root,const std::vector<std::string>& parts){
 Fd cursor(fcntl(root,F_DUPFD_CLOEXEC,0));
 for(size_t i=0;i+1<parts.size();++i){Fd next(openat(cursor.fd,parts[i].c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));
  const int old=cursor.fd;cursor.fd=next.fd;next.fd=old;}
 const int result=cursor.fd;cursor.fd=-1;return result;
}
inline void Regular(int fd){struct stat st{};Check(fstat(fd,&st)==0);if(!S_ISREG(st.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");}
// New edit resources use checked, one-attempt closes. The legacy Fd and old
// ABI methods retain their existing behavior. All callers hold State::mutex.
struct EditFd {
 State& state;
 int fd=-1;
 int close_error=0;
 explicit EditFd(State& value):state(value){}
 EditFd(State& value,int descriptor):state(value),fd(descriptor){Check(fd>=0);}
 EditFd(const EditFd&)=delete;EditFd& operator=(const EditFd&)=delete;
 ~EditFd(){Close();}
 int Close() noexcept {
  if(fd>=0){
   const int descriptor=fd;fd=-1; // Never retry an ambiguously closed number.
   if(::close(descriptor)!=0){close_error=errno?errno:EIO;state.close_failed=true;}
  }
  return close_error;
 }
 void CloseChecked(){const int error=Close();if(error)throw std::system_error(error,std::generic_category(),"Workspace close failed");}
 int Release() noexcept {const int descriptor=fd;fd=-1;return descriptor;}
};
inline int EditParent(State& state,const std::vector<std::string>& parts){
 EditFd cursor(state,fcntl(state.root,F_DUPFD_CLOEXEC,0));
 for(size_t i=0;i+1<parts.size();++i){
  EditFd next(state,openat(cursor.fd,parts[i].c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));
  cursor.CloseChecked();cursor.fd=next.Release();
 }
 return cursor.Release();
}
// Move preserves writeFileAtomic's recursive parent creation, anchored to
// the existing lease. Only directories missing below that root are created.
inline int MoveParent(State& state,const std::vector<std::string>& parts){
 EditFd cursor(state,fcntl(state.root,F_DUPFD_CLOEXEC,0));
 for(size_t i=0;i+1<parts.size();++i){
  int next_fd=openat(cursor.fd,parts[i].c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(next_fd<0&&errno==ENOENT){
   if(mkdirat(cursor.fd,parts[i].c_str(),0777)!=0&&errno!=EEXIST)Check(false);
   next_fd=openat(cursor.fd,parts[i].c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  }
  EditFd next(state,next_fd);cursor.CloseChecked();cursor.fd=next.Release();
 }
 return cursor.Release();
}
template<class Integer> inline uint64_t StatUnsigned(Integer value){
 static_assert(std::numeric_limits<Integer>::is_integer&&std::numeric_limits<Integer>::digits<=64,"integer exceeds exact stat ABI");
 if constexpr(std::numeric_limits<Integer>::is_signed){if(value<0)throw GrantError("ERR_WORKSPACE_LIMIT");}
 return static_cast<uint64_t>(value);
}
struct EditInput {
 EditFd file;
 uint64_t size=0;
 explicit EditInput(State& state):file(state){}
 void Open(int parent,const char* name){
  file.fd=openat(parent,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);Check(file.fd>=0);
  struct stat st{};Check(fstat(file.fd,&st)==0);
  if(!S_ISREG(st.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  size=StatUnsigned(st.st_size);
 }
};
struct EditCleanup {int entry_error=0;int close_error=0;};
struct EditOutput {
 enum class Phase {writing,ready,failed,published};
 State& state;
 EditFd parent,directory,file;
 std::string target,staging;
 mode_t prior_mode;
 bool move_output=false,create_if_absent=false;
 struct stat directory_identity{},file_identity{};
 bool owns_directory=false,owns_file=false;
 bool has_directory_identity=false,has_file_identity=false;
 bool cleaned=false;
 EditCleanup cleanup;
 Phase phase=Phase::writing;
 EditOutput(State& value,std::string name,mode_t mode):state(value),parent(value),directory(value),file(value),target(std::move(name)),prior_mode(mode){}
 EditOutput(const EditOutput&)=delete;EditOutput& operator=(const EditOutput&)=delete;
 ~EditOutput(){Cleanup();}
 static bool Same(const struct stat& a,const struct stat& b) noexcept {return a.st_dev==b.st_dev&&a.st_ino==b.st_ino;}
 static void Remember(int value,int& destination) noexcept {if(value&&!destination)destination=value;}
 void CheckMoveTarget(bool publishing=false){
  struct stat target_stat{};
  if(fstatat(parent.fd,target.c_str(),&target_stat,AT_SYMLINK_NOFOLLOW)!=0){if(errno==ENOENT)return;Check(false);}
  if(!S_ISREG(target_stat.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  if(publishing&&create_if_absent)throw std::system_error(EEXIST,std::generic_category(),"Workspace destination already exists");
 }
 void Create(){
  if(move_output)CheckMoveTarget();
  else {
   struct stat target_stat{};Check(fstatat(parent.fd,target.c_str(),&target_stat,AT_SYMLINK_NOFOLLOW)==0);
   if(!S_ISREG(target_stat.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  }
  std::random_device random;
  static const char hex[]="0123456789abcdef";
  for(unsigned attempt=0;attempt<16&&!owns_directory;++attempt){
   staging=".dsh-edit-";
   for(unsigned word=0;word<4;++word){uint32_t value=static_cast<uint32_t>(random());
    for(unsigned digit=0;digit<8;++digit){staging.push_back(hex[value&15]);value>>=4;}}
   if(mkdirat(parent.fd,staging.c_str(),0700)==0)owns_directory=true;
   else if(errno!=EEXIST)Check(false);
  }
  if(!owns_directory)throw std::system_error(EEXIST,std::generic_category(),"Workspace staging collision");
  Check(fstatat(parent.fd,staging.c_str(),&directory_identity,AT_SYMLINK_NOFOLLOW)==0);
  has_directory_identity=true;
  if(!S_ISDIR(directory_identity.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  directory.fd=openat(parent.fd,staging.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  Check(directory.fd>=0);
  struct stat opened{};Check(fstat(directory.fd,&opened)==0);
  if(!Same(opened,directory_identity))throw std::system_error(ESTALE,std::generic_category(),"Workspace staging changed");
  // Set actual modes on the opened objects; creation mode alone is insufficient.
  Check(fchmod(directory.fd,0700)==0);
  file.fd=openat(directory.fd,"content",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  Check(file.fd>=0);owns_file=true;
  Check(fstat(file.fd,&file_identity)==0);has_file_identity=true;
  if(!S_ISREG(file_identity.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  Check(fchmod(file.fd,0600)==0);
 }
 size_t Write(const void* bytes,size_t length){
  if(phase!=Phase::writing||file.fd<0)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  const auto count=::write(file.fd,bytes,length);
  if(count<0){phase=Phase::failed;Check(false);}
  if(length&&count==0){phase=Phase::failed;throw std::system_error(EIO,std::generic_category(),"Workspace write made no progress");}
  return static_cast<size_t>(count);
 }
 void CloseOutput(){
  if(phase!=Phase::writing||file.fd<0)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  phase=Phase::failed;
  Check(fsync(file.fd)==0);
  Check(fchmod(file.fd,prior_mode)==0);
  file.CloseChecked();
  phase=Phase::ready;
 }
 int RemoveOwnFile() noexcept {
  if(!owns_file)return 0;
  if(directory.fd<0||!has_file_identity)return ESTALE;
  struct stat found{};
  if(fstatat(directory.fd,"content",&found,AT_SYMLINK_NOFOLLOW)!=0){
   if(errno==ENOENT){owns_file=false;return 0;}return errno?errno:EIO;
  }
  if(!Same(found,file_identity))return ESTALE;
  if(unlinkat(directory.fd,"content",0)!=0)return errno?errno:EIO;
  owns_file=false;return 0;
 }
 int RemoveOwnDirectory() noexcept {
  if(!owns_directory)return 0;
  if(parent.fd<0||!has_directory_identity)return ESTALE;
  struct stat found{};
  if(fstatat(parent.fd,staging.c_str(),&found,AT_SYMLINK_NOFOLLOW)!=0){
   if(errno==ENOENT){owns_directory=false;return 0;}return errno?errno:EIO;
  }
  if(!S_ISDIR(found.st_mode)||!Same(found,directory_identity))return ESTALE;
  if(unlinkat(parent.fd,staging.c_str(),AT_REMOVEDIR)!=0)return errno?errno:EIO;
  owns_directory=false;return 0;
 }
 bool Publish(){
  if(phase!=Phase::ready||file.fd>=0)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  phase=Phase::failed;
  struct stat target_stat{};Check(fstatat(parent.fd,target.c_str(),&target_stat,AT_SYMLINK_NOFOLLOW)==0);
  if(!S_ISREG(target_stat.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  Check(renameat(directory.fd,"content",parent.fd,target.c_str())==0);
  // No throwing work or descriptor closes after commit. The bool is only the
  // best-effort removal of our staging directory, never a retirement claim.
  phase=Phase::published;owns_file=false;
  cleanup.entry_error=RemoveOwnDirectory();
  return cleanup.entry_error==0;
 }
 // Separate Move publication. effect is written immediately after each
 // visible effect: 0 unchanged, 1 exclusive final may be incomplete, 2 complete.
 // No renameat2 call bypasses the existing publication crash-fuse service.
 bool PublishMove(uint32_t& effect){
  if(!move_output||phase!=Phase::ready||file.fd>=0)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  phase=Phase::failed;
  CheckMoveTarget(true);
  if(!create_if_absent){
   Check(renameat(directory.fd,"content",parent.fd,target.c_str())==0);
   effect=2;owns_file=false;
  }else if(linkat(directory.fd,"content",parent.fd,target.c_str(),0)==0){
   effect=2;
  }else{
   const int link_error=errno;
   // These are exactly the OH Local provider's existing link -> wx cases.
   if(link_error!=EPERM&&link_error!=EXDEV&&link_error!=ENOTSUP&&link_error!=EMLINK&&link_error!=EACCES){errno=link_error;Check(false);}
   file.fd=openat(parent.fd,target.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
   Check(file.fd>=0);effect=1;
   // Never unlink this final pathname after an error: original Local behavior
   // leaves a possible incomplete file rather than remove a replacement.
   Check(fchmod(file.fd,0600)==0);
   EditFd input(state,openat(directory.fd,"content",O_RDONLY|O_NOFOLLOW|O_CLOEXEC));
   struct stat input_stat{};Check(fstat(input.fd,&input_stat)==0);
   if(!S_ISREG(input_stat.st_mode)||!Same(input_stat,file_identity))throw std::system_error(ESTALE,std::generic_category(),"Workspace staging changed");
   char buffer[65536];
   for(;;){
    ssize_t n;do{n=::read(input.fd,buffer,sizeof(buffer));}while(n<0&&errno==EINTR);Check(n>=0);if(!n)break;
    size_t offset=0;
    while(offset<static_cast<size_t>(n)){
     ssize_t count;do{count=::write(file.fd,buffer+offset,static_cast<size_t>(n)-offset);}while(count<0&&errno==EINTR);
     Check(count>=0);if(!count)throw std::system_error(EIO,std::generic_category(),"Workspace write made no progress");
     offset+=static_cast<size_t>(count);
    }
   }
   input.CloseChecked();Check(fsync(file.fd)==0);Check(fchmod(file.fd,prior_mode)==0);file.CloseChecked();
   effect=2;
  }
  phase=Phase::published;
  // Both removals are best-effort owned staging entries. Auxiliary descriptor
  // closure remains separate and checked by AbortEdit/lease retirement.
  Remember(RemoveOwnFile(),cleanup.entry_error);
  Remember(RemoveOwnDirectory(),cleanup.entry_error);
  return cleanup.entry_error==0;
 }
 EditCleanup Cleanup() noexcept {
  if(cleaned)return cleanup;
  cleaned=true;
  Remember(file.Close(),cleanup.close_error);
  if(phase!=Phase::published){
   Remember(RemoveOwnFile(),cleanup.entry_error);
   Remember(RemoveOwnDirectory(),cleanup.entry_error);
  }
  // After publication do not retry directory removal or touch the target.
  // Checked auxiliary closes are separate from Publish's directory bool.
  Remember(directory.Close(),cleanup.close_error);
  Remember(parent.Close(),cleanup.close_error);
  return cleanup;
 }
};

// Separate whole-write output. Old EditOutput and Move V1 retain their exact
// publication contracts; no descriptor or host path is exposed to JavaScript.
struct WholePublication {
 bool known=false;
 uint32_t effect=0,continuation=0;
 bool staging_removed=false;
};
struct WholeOutput {
 enum class Phase {writing,ready,exclusive,copying,finishing,failed,published};
 State& state;
 EditOutput stage;
 EditFd input,final;
 bool directory_default;
 uint32_t effect=0;
 uint64_t written=0,remaining=0;
 char buffer[65536];
 size_t pending=0,offset=0;
 Phase phase=Phase::writing;
 bool cleaned=false;
 EditCleanup cleanup;
 WholeOutput(State& value,std::string target,mode_t mode,bool defaults,bool absent):
  state(value),stage(value,std::move(target),mode),input(value),final(value),directory_default(defaults){
  stage.move_output=true;stage.create_if_absent=absent;
 }
 ~WholeOutput(){Cleanup();}
 void Create(){
  stage.CheckMoveTarget();
  struct stat parent_defaults{};
  if(directory_default)Check(fstat(stage.parent.fd,&parent_defaults)==0);
  std::random_device random;static const char hex[]="0123456789abcdef";
  for(unsigned attempt=0;attempt<16&&!stage.owns_directory;++attempt){
   stage.staging=".dsh-edit-";
   for(unsigned word=0;word<4;++word){uint32_t value=static_cast<uint32_t>(random());
    for(unsigned digit=0;digit<8;++digit){stage.staging.push_back(hex[value&15]);value>>=4;}}
   if(mkdirat(stage.parent.fd,stage.staging.c_str(),0700)==0)stage.owns_directory=true;
   else if(errno!=EEXIST)Check(false);
  }
  if(!stage.owns_directory)throw std::system_error(EEXIST,std::generic_category(),"Workspace staging collision");
  Check(fstatat(stage.parent.fd,stage.staging.c_str(),&stage.directory_identity,AT_SYMLINK_NOFOLLOW)==0);
  stage.has_directory_identity=true;
  if(!S_ISDIR(stage.directory_identity.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  stage.directory.fd=openat(stage.parent.fd,stage.staging.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  Check(stage.directory.fd>=0);
  struct stat opened{};Check(fstat(stage.directory.fd,&opened)==0);
  if(!EditOutput::Same(opened,stage.directory_identity))throw std::system_error(ESTALE,std::generic_category(),"Workspace staging changed");
  if(directory_default){
   const mode_t sgid=opened.st_mode&S_ISGID;
   if((parent_defaults.st_mode&S_ISGID)&&(!sgid||opened.st_gid!=parent_defaults.st_gid))
    throw GrantError("ERR_WORKSPACE_DIRECTORY_DEFAULTS");
   // Keep inherited SGID/default ACL; normalize only private access bits.
   Check(fchmod(stage.directory.fd,0700|sgid)==0);
   struct stat secured{};Check(fstat(stage.directory.fd,&secured)==0);
   if((secured.st_mode&07777)!=(0700|sgid)||secured.st_gid!=opened.st_gid)
    throw GrantError("ERR_WORKSPACE_DIRECTORY_DEFAULTS");
  }else Check(fchmod(stage.directory.fd,0700)==0);
  // Private whole-write staging is readable through its original open object,
  // even when the actual creation default or preserved prior mode is zero.
  stage.file.fd=openat(stage.directory.fd,"content",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,directory_default?0666:0600);
  Check(stage.file.fd>=0);stage.owns_file=true;
  Check(fstat(stage.file.fd,&stage.file_identity)==0);stage.has_file_identity=true;
  if(!S_ISREG(stage.file_identity.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");
  if(!directory_default)Check(fchmod(stage.file.fd,0600)==0);
 }
 size_t Write(const void* bytes,size_t length){
  if(phase!=Phase::writing)throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
  if(written>UINT64_MAX-length)throw GrantError("ERR_WORKSPACE_LIMIT");
  try{const auto count=stage.Write(bytes,length);written+=count;return count;}
  catch(...){phase=Phase::failed;throw;}
 }
 void CloseStage(){
  if(phase!=Phase::writing||stage.file.fd<0)throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
  phase=Phase::failed;
  struct stat sealed{};Check(fstat(stage.file.fd,&sealed)==0);
  if(!S_ISREG(sealed.st_mode)||!EditOutput::Same(sealed,stage.file_identity)||StatUnsigned(sealed.st_size)!=written)
   throw std::system_error(ESTALE,std::generic_category(),"Workspace staging changed");
  // The private duplicate shares the same open file description. Preserve it
  // before the checked output close; never reopen a mode-0 staging pathname.
  input.fd=fcntl(stage.file.fd,F_DUPFD_CLOEXEC,0);Check(input.fd>=0);
  struct stat copying{};Check(fstat(input.fd,&copying)==0);
  if(!S_ISREG(copying.st_mode)||!EditOutput::Same(copying,stage.file_identity)||StatUnsigned(copying.st_size)!=written)
   throw std::system_error(ESTALE,std::generic_category(),"Workspace staging changed");
  Check(lseek(input.fd,0,SEEK_SET)==0);
  if(directory_default){
   stage.phase=EditOutput::Phase::failed;Check(fsync(stage.file.fd)==0);stage.file.CloseChecked();
   stage.phase=EditOutput::Phase::ready;
  }else stage.CloseOutput();
  phase=Phase::ready;
 }
 WholePublication Facts() const noexcept {
  const uint32_t next=phase==Phase::exclusive?1u:phase==Phase::copying?2u:phase==Phase::finishing?3u:0u;
  return {true,effect,next,phase==Phase::published&&stage.cleanup.entry_error==0};
 }
 void Complete() noexcept {
  phase=Phase::published;stage.phase=EditOutput::Phase::published;
  EditOutput::Remember(stage.RemoveOwnFile(),stage.cleanup.entry_error);
  EditOutput::Remember(stage.RemoveOwnDirectory(),stage.cleanup.entry_error);
 }
 WholePublication Step(){
  try{
   if(phase==Phase::ready){
    stage.phase=EditOutput::Phase::failed;stage.CheckMoveTarget(true);
    if(!stage.create_if_absent){
     Check(renameat(stage.directory.fd,"content",stage.parent.fd,stage.target.c_str())==0);
     effect=2;stage.owns_file=false;Complete();return Facts();
    }
    if(linkat(stage.directory.fd,"content",stage.parent.fd,stage.target.c_str(),0)==0){effect=2;Complete();return Facts();}
    const int code=errno;
    if(code!=EPERM&&code!=EXDEV&&code!=ENOTSUP&&code!=EMLINK&&code!=EACCES){errno=code;Check(false);}
    // Return before exclusive create so JS can perform the original signal
    // check after a supported link failure. This is not a committed result.
    phase=Phase::exclusive;return Facts();
   }
   if(phase==Phase::exclusive){
    if(input.fd<0)throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
    final.fd=openat(stage.parent.fd,stage.target.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,directory_default?0666:0600);
    Check(final.fd>=0);effect=1;
    if(!directory_default)Check(fchmod(final.fd,0600)==0);
    remaining=written;phase=remaining?Phase::copying:Phase::finishing;return Facts();
   }
   if(phase==Phase::copying){
    if(pending==0){
     const size_t length=remaining<sizeof(buffer)?static_cast<size_t>(remaining):sizeof(buffer);
     if(!length)throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
     const auto count=::read(input.fd,buffer,length);
     if(count<0&&errno==EINTR)return Facts(); // bounded syscall count, no busy retry
     Check(count>=0);
     if(count==0||static_cast<uint64_t>(count)>remaining)throw std::system_error(EIO,std::generic_category(),"Workspace staging ended early");
     remaining-=static_cast<uint64_t>(count);pending=static_cast<size_t>(count);offset=0;
    }
    const auto count=::write(final.fd,buffer+offset,pending-offset);
    if(count<0&&errno==EINTR)return Facts();
    Check(count>=0);
    if(!count||static_cast<size_t>(count)>pending-offset)throw std::system_error(EIO,std::generic_category(),"Workspace copy made invalid progress");
    offset+=static_cast<size_t>(count);
    if(offset==pending){pending=0;offset=0;if(!remaining)phase=Phase::finishing;}
    return Facts();
   }
   if(phase==Phase::finishing){
    // Caller does not insert another signal check after all body bytes have
    // been copied. Checked close/sync failures still retain effect1.
    input.CloseChecked();Check(fsync(final.fd)==0);
    if(!directory_default)Check(fchmod(final.fd,stage.prior_mode)==0);
    final.CloseChecked();effect=2;Complete();return Facts();
   }
   throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
  }catch(...){if(phase!=Phase::published)phase=Phase::failed;throw;}
 }
 EditCleanup Cleanup() noexcept {
  if(cleaned)return cleanup;
  cleaned=true;
  EditOutput::Remember(input.Close(),cleanup.close_error);
  EditOutput::Remember(final.Close(),cleanup.close_error);
  const auto staged=stage.Cleanup();
  EditOutput::Remember(staged.close_error,cleanup.close_error);
  EditOutput::Remember(staged.entry_error,cleanup.entry_error);
  return cleanup; // final is never an owned staging pathname and is never unlinked
 }
};

struct TaskScope { std::shared_ptr<State> state;bool active=true;bool live=true; };
}
struct WorkspaceGrantStatus { bool active;bool drained;bool writable;size_t leases;uint64_t generation; };
class WorkspaceLease {
 std::shared_ptr<grant_detail::State> state_;bool write_;
 std::shared_ptr<grant_detail::TaskScope> task_;
 std::unique_ptr<grant_detail::EditInput> edit_input_;
 std::unique_ptr<grant_detail::EditOutput> edit_output_;
 std::unique_ptr<grant_detail::WholeOutput> whole_output_;
 friend class WorkspaceGrants;
 friend class WorkspaceFid;
 WorkspaceLease(std::shared_ptr<grant_detail::State> state,bool write):state_(std::move(state)),write_(write){++state_->leases;}
 void Access(bool write){state_->CheckActive(write);if(task_&&!task_->active)throw GrantError("ERR_WORKSPACE_TASK_RETIRED");if(write&&!write_)throw GrantError("ERR_WORKSPACE_READ_ONLY");}
 public:
 WorkspaceLease(const WorkspaceLease&)=delete;WorkspaceLease& operator=(const WorkspaceLease&)=delete;
 ~WorkspaceLease(){std::lock_guard<std::mutex> lock(state_->mutex);edit_input_.reset();edit_output_.reset();whole_output_.reset();--state_->leases;if(task_)task_->live=false;}
 std::shared_ptr<grant_detail::TaskScope> Task(){std::lock_guard<std::mutex> lock(state_->mutex);
  if(!task_)task_=std::make_shared<grant_detail::TaskScope>(grant_detail::TaskScope{state_,true,true});
  return task_;}
 struct stat Stat(const std::string& path){std::lock_guard<std::mutex> lock(state_->mutex);Access(false);struct stat st{};
  if(path.empty()){grant_detail::Check(fstat(state_->root,&st)==0);return st;}
  auto parts=grant_detail::Parts(path);grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
  grant_detail::Check(fstatat(parent.fd,parts.back().c_str(),&st,AT_SYMLINK_NOFOLLOW)==0);return st;
 }
 void Readdir(const std::string& path,const std::function<void(const std::string&)>& emit){
  std::lock_guard<std::mutex> lock(state_->mutex);Access(false);
  int fd;
  if(path.empty())fd=openat(state_->root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  else {auto parts=grant_detail::Parts(path);grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
    fd=openat(parent.fd,parts.back().c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);}
  grant_detail::Fd owned(fd);DIR* raw=fdopendir(fd);grant_detail::Check(raw!=nullptr);owned.fd=-1;
  std::unique_ptr<DIR,int(*)(DIR*)> directory(raw,closedir);size_t count=0;
  for(;;){errno=0;auto* entry=readdir(raw);if(!entry){grant_detail::Check(errno==0);break;}
    std::string name=entry->d_name;if(name=="."||name=="..")continue;
    if(++count>10000)throw GrantError("ERR_WORKSPACE_LIMIT");
    emit(name);}
 }
 std::string Read(const std::string& path,uint64_t offset,size_t maximum){
  if(maximum>1024*1024||offset>INT64_MAX)throw GrantError("ERR_WORKSPACE_LIMIT");
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(false);
  grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
  grant_detail::Fd file(openat(parent.fd,parts.back().c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));grant_detail::Regular(file.fd);
  std::string result(maximum,'\0');auto count=pread(file.fd,result.data(),maximum,static_cast<off_t>(offset));grant_detail::Check(count>=0);result.resize(count);return result;
 }
 // New exact observations use checked temporary parent descriptors. The old
 // Stat method/layout remain unchanged for existing consumers.
 struct stat StatExact(const std::string& path){
  std::lock_guard<std::mutex> lock(state_->mutex);Access(false);struct stat st{};
  if(path.empty()){grant_detail::Check(fstat(state_->root,&st)==0);return st;}
  auto parts=grant_detail::Parts(path);
  grant_detail::EditFd parent(*state_,grant_detail::EditParent(*state_,parts));
  grant_detail::Check(fstatat(parent.fd,parts.back().c_str(),&st,AT_SYMLINK_NOFOLLOW)==0);
  parent.CloseChecked();return st;
 }
 uint64_t OpenEditInput(const std::string& path){
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(false);
  if(edit_input_||edit_output_||whole_output_)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  grant_detail::EditFd parent(*state_,grant_detail::EditParent(*state_,parts));
  // Allocate the owning slot before openat: allocation failure cannot strand
  // a raw descriptor evaluated as a make_unique argument.
  auto input=std::make_unique<grant_detail::EditInput>(*state_);
  input->Open(parent.fd,parts.back().c_str());
  parent.CloseChecked();
  const auto size=input->size;edit_input_=std::move(input);return size;
 }
 size_t ReadEditInput(void* buffer,size_t length){
  if((!buffer&&length)||length>1024*1024)throw GrantError("ERR_WORKSPACE_BUFFER");
  std::lock_guard<std::mutex> lock(state_->mutex);Access(false);
  if(!edit_input_||edit_input_->file.fd<0)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  const auto count=::read(edit_input_->file.fd,buffer,length);
  grant_detail::Check(count>=0);return static_cast<size_t>(count);
 }
 void CloseEditInput(){
  std::lock_guard<std::mutex> lock(state_->mutex);
  // Cleanup remains available after cancellation/retirement of this lease.
  if(!edit_input_)return;
  edit_input_->file.CloseChecked();edit_input_.reset();
 }
 void BeginEdit(const std::string& path,uint32_t prior_mode){
  if(prior_mode>0777)throw GrantError("ERR_WORKSPACE_MODE");
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(edit_input_||edit_output_||whole_output_)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  auto output=std::make_unique<grant_detail::EditOutput>(*state_,parts.back(),static_cast<mode_t>(prior_mode));
  try{output->parent.fd=grant_detail::EditParent(*state_,parts);output->Create();}
  catch(...){
   const auto result=output->Cleanup();
   if(result.close_error)throw std::system_error(result.close_error,std::generic_category(),"Workspace edit close failed");
   if(result.entry_error)throw std::system_error(result.entry_error,std::generic_category(),"Workspace staging cleanup failed");
   throw;
  }
  edit_output_=std::move(output);
 }
 void BeginMoveOutput(const std::string& path,uint32_t source_mode,bool create_if_absent){
  if(source_mode>0777)throw GrantError("ERR_WORKSPACE_MODE");
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(edit_input_||edit_output_||whole_output_)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  auto output=std::make_unique<grant_detail::EditOutput>(*state_,parts.back(),static_cast<mode_t>(source_mode));
  output->move_output=true;output->create_if_absent=create_if_absent;
  try{output->parent.fd=grant_detail::MoveParent(*state_,parts);output->Create();}
  catch(...){
   const auto result=output->Cleanup();
   if(result.close_error)throw std::system_error(result.close_error,std::generic_category(),"Workspace move close failed");
   if(result.entry_error)throw std::system_error(result.entry_error,std::generic_category(),"Workspace staging cleanup failed");
   throw;
  }
  edit_output_=std::move(output);
 }
 bool PublishMoveOutput(uint32_t& effect){
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(!edit_output_||!edit_output_->move_output)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  return edit_output_->PublishMove(effect);
 }
 size_t WriteEdit(const void* buffer,size_t length){
  if((!buffer&&length)||length>1024*1024)throw GrantError("ERR_WORKSPACE_BUFFER");
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(!edit_output_)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  return edit_output_->Write(buffer,length);
 }
 void CloseEdit(){
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(!edit_output_)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  edit_output_->CloseOutput();
 }
 bool PublishEdit(){
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(!edit_output_)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  if(edit_output_->move_output)throw GrantError("ERR_WORKSPACE_EDIT_STATE");
  return edit_output_->Publish();
 }
 void AbortEdit(){
  std::lock_guard<std::mutex> lock(state_->mutex);
  if(!edit_output_)return;
  const bool published=edit_output_->phase==grant_detail::EditOutput::Phase::published;
  const auto result=edit_output_->Cleanup();
  if(result.close_error)throw std::system_error(result.close_error,std::generic_category(),"Workspace edit close failed");
  if(!published&&result.entry_error)throw std::system_error(result.entry_error,std::generic_category(),"Workspace staging cleanup failed");
  edit_output_.reset();
 }

 void BeginWholeOutput(const std::string& path,uint32_t policy,uint32_t prior_mode,bool absent){
  if(policy>1||prior_mode>0777||(policy==1&&prior_mode!=0))throw GrantError("ERR_WORKSPACE_MODE");
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(edit_input_||edit_output_||whole_output_)throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
  auto output=std::make_unique<grant_detail::WholeOutput>(*state_,parts.back(),static_cast<mode_t>(prior_mode),policy==1,absent);
  try{output->stage.parent.fd=grant_detail::MoveParent(*state_,parts);output->Create();}
  catch(...){const auto result=output->Cleanup();
   if(result.close_error)throw std::system_error(result.close_error,std::generic_category(),"Workspace whole output close failed");
   if(result.entry_error)throw std::system_error(result.entry_error,std::generic_category(),"Workspace staging cleanup failed");
   throw;
  }
  whole_output_=std::move(output);
 }
 size_t WriteWholeOutput(const void* bytes,size_t length){
  if((!bytes&&length)||length>1024*1024)throw GrantError("ERR_WORKSPACE_BUFFER");
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(!whole_output_)throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
  return whole_output_->Write(bytes,length);
 }
 void CloseWholeOutput(){
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(!whole_output_)throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
  whole_output_->CloseStage();
 }
 grant_detail::WholePublication StepWholeOutput(){
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  if(!whole_output_)throw GrantError("ERR_WORKSPACE_WHOLE_STATE");
  return whole_output_->Step();
 }
 grant_detail::WholePublication WholeOutputFacts(){
  std::lock_guard<std::mutex> lock(state_->mutex);
  return whole_output_?whole_output_->Facts():grant_detail::WholePublication{};
 }
 void AbortWholeOutput(){
  std::lock_guard<std::mutex> lock(state_->mutex);
  if(!whole_output_)return;
  const bool committed=whole_output_->effect==2;
  const auto result=whole_output_->Cleanup();
  if(result.close_error)throw std::system_error(result.close_error,std::generic_category(),"Workspace whole output close failed");
  if(!committed&&result.entry_error)throw std::system_error(result.entry_error,std::generic_category(),"Workspace staging cleanup failed");
  whole_output_.reset();
 }
 size_t Write(const std::string& path,const std::string& bytes,uint64_t offset,bool create=false,bool truncate=false,bool append=false,bool exclusive=false){
  if(bytes.size()>1024*1024||offset>INT64_MAX)throw GrantError("ERR_WORKSPACE_LIMIT");
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
  // Never truncate before checking the opened object's type.
  grant_detail::Fd file(openat(parent.fd,parts.back().c_str(),O_WRONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK|(create?O_CREAT:0)|(append?O_APPEND:0)|(exclusive?O_EXCL:0),0600));
  grant_detail::Regular(file.fd);if(truncate)grant_detail::Check(ftruncate(file.fd,0)==0);
  auto count=append?write(file.fd,bytes.data(),bytes.size()):pwrite(file.fd,bytes.data(),bytes.size(),static_cast<off_t>(offset));grant_detail::Check(count>=0);return count;
 }
 void Rename(const std::string& source,const std::string& destination){
  auto from=grant_detail::Parts(source),to=grant_detail::Parts(destination);
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  grant_detail::Fd a(grant_detail::Parent(state_->root,from)),b(grant_detail::Parent(state_->root,to));
  grant_detail::Check(renameat(a.fd,from.back().c_str(),b.fd,to.back().c_str())==0);
 }
 void Remove(const std::string& path,bool directory=false){
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
  grant_detail::Check(unlinkat(parent.fd,parts.back().c_str(),directory?AT_REMOVEDIR:0)==0);
 }
 void Mkdir(const std::string& path){
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));grant_detail::Check(mkdirat(parent.fd,parts.back().c_str(),0700)==0);
 }
};
class WorkspaceGrants {
 std::mutex mutex_;std::map<std::string,std::shared_ptr<grant_detail::State>> grants_;
 static WorkspaceGrantStatus Snapshot(const grant_detail::State& s){return {s.active,!s.active&&s.root<0&&s.leases==0&&!s.close_failed,s.writable,s.leases,s.generation};}
 std::shared_ptr<grant_detail::State> Find(const std::string& id,uint64_t generation){auto found=grants_.find(id);
  if(found==grants_.end()||found->second->generation!=generation)throw GrantError("ERR_WORKSPACE_GENERATION");
  return found->second;}
 public:
 // Ark alone calls this after opening the actual picker/activated URI. The fd
 // is borrowed and duplicated; URI conversion and Dart input never reach here.
 void Publish(const std::string& id,uint64_t generation,int descriptor,bool writable){
  if(id.empty()||id.size()>128||id.find('\0')!=std::string::npos||generation==0)throw GrantError("ERR_WORKSPACE_ID");
  struct stat st{};grant_detail::Check(fstat(descriptor,&st)==0);if(!S_ISDIR(st.st_mode))throw GrantError("ERR_WORKSPACE_DIRECTORY");
  std::lock_guard<std::mutex> owner(mutex_);auto prior=grants_.find(id);
  if(prior!=grants_.end()){std::lock_guard<std::mutex> lock(prior->second->mutex);
   if(generation<=prior->second->generation)throw GrantError("ERR_WORKSPACE_GENERATION");
   if(!Snapshot(*prior->second).drained)throw GrantError("ERR_WORKSPACE_DRAINING");}
  if(prior==grants_.end()&&grants_.size()>=128)throw GrantError("ERR_WORKSPACE_LIMIT");
  auto state=std::make_shared<grant_detail::State>();state->root=fcntl(descriptor,F_DUPFD_CLOEXEC,0);grant_detail::Check(state->root>=0);
  state->generation=generation;state->writable=writable;grants_[id]=state;
 }
 std::unique_ptr<WorkspaceLease> Acquire(const std::string& id,uint64_t generation,bool write){
  std::lock_guard<std::mutex> owner(mutex_);auto state=Find(id,generation);std::lock_guard<std::mutex> lock(state->mutex);state->CheckActive(write);
  return std::unique_ptr<WorkspaceLease>(new WorkspaceLease(state,write));
 }
 WorkspaceGrantStatus Retire(const std::string& id,uint64_t generation){
  std::lock_guard<std::mutex> owner(mutex_);auto state=Find(id,generation);std::lock_guard<std::mutex> lock(state->mutex);
  state->active=false;if(state->root>=0){int descriptor=state->root;state->root=-1;if(close(descriptor)!=0)state->close_failed=true;}
  return Snapshot(*state);
 }
 struct Record {std::string id;uint64_t generation;bool writable;};
 std::vector<Record> SnapshotActive(){std::vector<Record> records;std::lock_guard<std::mutex> owner(mutex_);
  for(auto& pair:grants_){auto& state=*pair.second;std::lock_guard<std::mutex> lock(state.mutex);
   if(state.active)records.push_back({pair.first,state.generation,state.writable});}
  return records;
 }
 WorkspaceGrantStatus Status(const std::string& id,uint64_t generation){std::lock_guard<std::mutex> owner(mutex_);auto state=Find(id,generation);
  std::lock_guard<std::mutex> lock(state->mutex);return Snapshot(*state);}
};
// One owner instance in libdsh_host; consumers must link this symbol, never instantiate another registry.
WorkspaceGrants& WorkspaceGrantOwner();
}
#endif
