#include "workspace_grants.h"
namespace dsh {
WorkspaceGrants& WorkspaceGrantOwner() { static auto* registry=new WorkspaceGrants();return *registry; }
}
#include "workspace_grants_abi.h"
#include <cstring>
namespace {
thread_local std::string last_error;
thread_local int last_errno=0;
template<class F> int64_t Call(F work){try{last_error.clear();last_errno=0;return work();}
 catch(const dsh::GrantError& error){last_error=error.code;}
 catch(const std::system_error& error){last_error="ERR_WORKSPACE_IO";last_errno=error.code().value();}
 catch(...){last_error="ERR_WORKSPACE_INTERNAL";}return -1;}
dsh::WorkspaceLease& Lease(void* lease){if(!lease)throw dsh::GrantError("ERR_WORKSPACE_LEASE");return *static_cast<dsh::WorkspaceLease*>(lease);}
const char* Path(const char* path){if(!path)throw dsh::GrantError("ERR_WORKSPACE_PATH");return path;}
}
void* dsh_workspace_acquire(const char* id,uint64_t generation,int write){void* result=nullptr;
 Call([&]()->int64_t{if(write!=0&&write!=1)throw dsh::GrantError("ERR_WORKSPACE_MODE");result=dsh::WorkspaceGrantOwner().Acquire(Path(id),generation,write).release();return 0;});return result;}
void dsh_workspace_release(void* lease){delete static_cast<dsh::WorkspaceLease*>(lease);}
const char* dsh_workspace_error(){return last_error.c_str();}
int64_t dsh_workspace_read(void* lease,const char* path,uint64_t offset,void* buffer,size_t length){return Call([&]()->int64_t{
 if(!buffer&&length)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 auto bytes=Lease(lease).Read(Path(path),offset,length);if(!bytes.empty())memcpy(buffer,bytes.data(),bytes.size());return bytes.size();});}
int64_t dsh_workspace_write(void* lease,const char* path,uint64_t offset,const void* buffer,size_t length,int create,int truncate){return Call([&]()->int64_t{
 if((!buffer&&length)||length>1024*1024)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 return Lease(lease).Write(Path(path),std::string(buffer?static_cast<const char*>(buffer):"",length),offset,create,truncate);});}
int dsh_workspace_rename(void* lease,const char* a,const char* b){return Call([&]()->int64_t{Lease(lease).Rename(Path(a),Path(b));return 0;});}
int dsh_workspace_remove(void* lease,const char* path,int directory){return Call([&]()->int64_t{Lease(lease).Remove(Path(path),directory);return 0;});}
int dsh_workspace_mkdir(void* lease,const char* path){return Call([&]()->int64_t{Lease(lease).Mkdir(Path(path));return 0;});}
int dsh_workspace_stat(void* lease,const char* path,DshWorkspaceStat* out){return Call([&]()->int64_t{
 if(!out)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 const auto st=Lease(lease).Stat(Path(path));
 *out={static_cast<uint64_t>(st.st_size),static_cast<uint64_t>(st.st_ino),static_cast<uint64_t>(st.st_dev),static_cast<uint32_t>(st.st_mode),
  S_ISREG(st.st_mode)?1u:S_ISDIR(st.st_mode)?2u:S_ISLNK(st.st_mode)?3u:4u,st.st_mtim.tv_sec*1000.0+st.st_mtim.tv_nsec/1000000.0};return 0;});}
namespace {
template<class Integer> int64_t StatSeconds(Integer value){
 static_assert(std::numeric_limits<Integer>::is_integer&&std::numeric_limits<Integer>::digits<=64,"seconds exceed exact stat ABI");
 if constexpr(!std::numeric_limits<Integer>::is_signed){
  if(value>static_cast<uint64_t>(INT64_MAX))throw dsh::GrantError("ERR_WORKSPACE_LIMIT");
 }else{static_assert(std::numeric_limits<Integer>::digits<=63,"signed seconds exceed exact stat ABI");}
 return static_cast<int64_t>(value);
}
DshWorkspaceStatExactV1 ExactStat(const struct stat& st){
 const auto mn=dsh::grant_detail::StatUnsigned(st.st_mtim.tv_nsec),cn=dsh::grant_detail::StatUnsigned(st.st_ctim.tv_nsec);
 if(mn>999999999||cn>999999999)throw dsh::GrantError("ERR_WORKSPACE_LIMIT");
 const auto mode=dsh::grant_detail::StatUnsigned(st.st_mode);
 if(mode>UINT32_MAX)throw dsh::GrantError("ERR_WORKSPACE_LIMIT");
 return {1,0,dsh::grant_detail::StatUnsigned(st.st_dev),dsh::grant_detail::StatUnsigned(st.st_ino),dsh::grant_detail::StatUnsigned(st.st_size),
  StatSeconds(st.st_mtim.tv_sec),StatSeconds(st.st_ctim.tv_sec),static_cast<uint32_t>(mn),static_cast<uint32_t>(cn),static_cast<uint32_t>(mode),
  S_ISREG(st.st_mode)?1u:S_ISDIR(st.st_mode)?2u:S_ISLNK(st.st_mode)?3u:4u};
}
}
int dsh_workspace_stat_exact_v1(void* lease,const char* path,DshWorkspaceStatExactV1* out,size_t out_size){return Call([&]()->int64_t{
 if(!out||out_size!=sizeof(*out))throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 *out=ExactStat(Lease(lease).StatExact(Path(path)));return 0;});}
int dsh_workspace_edit_input_open_v1(void* lease,const char* path,uint64_t* size){return Call([&]()->int64_t{
 if(!size)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 *size=Lease(lease).OpenEditInput(Path(path));return 0;});}
int64_t dsh_workspace_edit_input_read_v1(void* lease,void* data,size_t count){return Call([&]()->int64_t{
 return Lease(lease).ReadEditInput(data,count);});}
int dsh_workspace_edit_input_close_v1(void* lease){return Call([&]()->int64_t{Lease(lease).CloseEditInput();return 0;});}
int dsh_workspace_edit_begin_v1(void* lease,const char* path,uint32_t prior_mode){return Call([&]()->int64_t{Lease(lease).BeginEdit(Path(path),prior_mode);return 0;});}
int64_t dsh_workspace_edit_write_v1(void* lease,const void* data,size_t count){return Call([&]()->int64_t{return Lease(lease).WriteEdit(data,count);});}
int dsh_workspace_edit_close_v1(void* lease){return Call([&]()->int64_t{Lease(lease).CloseEdit();return 0;});}
int dsh_workspace_edit_publish_v1(void* lease){return Call([&]()->int64_t{return Lease(lease).PublishEdit()?1:0;});}
int dsh_workspace_edit_abort_v1(void* lease){return Call([&]()->int64_t{Lease(lease).AbortEdit();return 0;});}
int dsh_workspace_move_output_begin_v1(void* lease,const char* path,uint32_t mode,int create_if_absent){return Call([&]()->int64_t{
 if(create_if_absent!=0&&create_if_absent!=1)throw dsh::GrantError("ERR_WORKSPACE_MODE");
 Lease(lease).BeginMoveOutput(Path(path),mode,create_if_absent!=0);return 0;});}
int dsh_workspace_move_output_publish_v1(void* lease,DshWorkspaceMovePublishV1* out,size_t out_size){return Call([&]()->int64_t{
 if(!out||out_size!=sizeof(*out))throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 *out={1,0,0,0};out->staging_removed=Lease(lease).PublishMoveOutput(out->effect)?1:0;return 0;});}

int dsh_workspace_whole_output_begin_v1(void* lease,const char* path,uint32_t policy,uint32_t mode,int absent){return Call([&]()->int64_t{
 if(absent!=0&&absent!=1)throw dsh::GrantError("ERR_WORKSPACE_MODE");
 Lease(lease).BeginWholeOutput(Path(path),policy,mode,absent!=0);return 0;});}
int64_t dsh_workspace_whole_output_write_v1(void* lease,const void* bytes,size_t length){return Call([&]()->int64_t{
 return Lease(lease).WriteWholeOutput(bytes,length);});}
int dsh_workspace_whole_output_close_v1(void* lease){return Call([&]()->int64_t{Lease(lease).CloseWholeOutput();return 0;});}
int dsh_workspace_whole_output_publish_step_v1(void* lease,DshWorkspaceWholePublishV1* out,size_t size){return Call([&]()->int64_t{
 if(!out||size!=sizeof(*out))throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 *out={1,0,0,0,0,0};
 auto& owner=Lease(lease);
 const auto snapshot=[&]{const auto facts=owner.WholeOutputFacts();
  *out={1,0,facts.known?1u:0u,facts.effect,facts.continuation,facts.staging_removed?1u:0u};};
 try{owner.StepWholeOutput();}catch(...){snapshot();throw;}
 snapshot();return 0;});}
int dsh_workspace_whole_output_abort_v1(void* lease){return Call([&]()->int64_t{Lease(lease).AbortWholeOutput();return 0;});}
int dsh_workspace_readdir(void* lease,const char* path,DshWorkspaceEntry callback,void* data){return Call([&]()->int64_t{
 if(!callback)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 Lease(lease).Readdir(Path(path),[&](const std::string& name){if(callback(name.data(),name.size(),data)!=0)throw dsh::GrantError("ERR_WORKSPACE_LIST_LIMIT");});return 0;});}
int64_t dsh_workspace_write_flags(void* lease,const char* path,uint64_t offset,const void* data,size_t size,int flags){return Call([&]()->int64_t{
 if((!data&&size)||size>1024*1024||flags<0||flags>15)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 return Lease(lease).Write(Path(path),std::string(data?static_cast<const char*>(data):"",size),offset,flags&1,flags&2,flags&4,flags&8);});}
namespace {
struct Ticket {std::unique_ptr<dsh::WorkspaceLease> waiting;std::shared_ptr<dsh::grant_detail::TaskScope> scope;bool consumed=false;};
std::mutex tickets_mutex;std::map<std::string,Ticket> tickets;
std::string Token(const char* text){const std::string token=Path(text);if(token.size()!=64||token.find_first_not_of("0123456789abcdef")!=std::string::npos)throw dsh::GrantError("ERR_WORKSPACE_TICKET");return token;}
}
int dsh_workspace_ticket_issue(const char* text,const char* id,uint64_t generation,int write){return Call([&]()->int64_t{
 const auto token=Token(text);std::lock_guard<std::mutex> guard(tickets_mutex);
 if(tickets.count(token)||tickets.size()>=256)throw dsh::GrantError("ERR_WORKSPACE_TICKET_LIMIT");
 auto lease=dsh::WorkspaceGrantOwner().Acquire(Path(id),generation,write!=0);auto scope=lease->Task();
 tickets.emplace(token,Ticket{std::move(lease),scope,false});return 0;});}
void* dsh_workspace_ticket_consume(const char* text){void* result=nullptr;Call([&]()->int64_t{
 const auto token=Token(text);std::lock_guard<std::mutex> guard(tickets_mutex);auto it=tickets.find(token);
 if(it==tickets.end()||it->second.consumed||!it->second.waiting)throw dsh::GrantError("ERR_WORKSPACE_TICKET");
 auto& ticket=it->second;{std::lock_guard<std::mutex> lock(ticket.scope->state->mutex);
  ticket.scope->state->CheckActive(false);if(!ticket.scope->active)throw dsh::GrantError("ERR_WORKSPACE_TICKET");}
 result=ticket.waiting.release();ticket.consumed=true;return 0;});return result;}
int dsh_workspace_ticket_retire(const char* text){return Call([&]()->int64_t{
 const auto token=Token(text);std::lock_guard<std::mutex> guard(tickets_mutex);auto it=tickets.find(token);if(it==tickets.end())return 1;
 auto& ticket=it->second;{std::lock_guard<std::mutex> lock(ticket.scope->state->mutex);ticket.scope->active=false;}
 ticket.waiting.reset();bool drained;
 {std::lock_guard<std::mutex> lock(ticket.scope->state->mutex);drained=!ticket.scope->live&&!ticket.scope->state->close_failed;}
 if(drained)tickets.erase(it);
 return drained?1:0;});}

int dsh_workspace_snapshot(DshWorkspaceSnapshotEntry emit,void* data){return Call([&]()->int64_t{
 if(!emit)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 // Copy under registry/state locks; callback cannot reenter a held owner lock.
 auto records=dsh::WorkspaceGrantOwner().SnapshotActive();
 for(const auto& row:records)if(emit(row.id.data(),row.id.size(),row.generation,row.writable,data))throw dsh::GrantError("ERR_WORKSPACE_SNAPSHOT");
 return 0;});}
int dsh_workspace_errno(){return last_errno;}

#include "workspace_fids.h"
#include "workspace_fids_abi.h"
namespace {
using FidPtr=std::shared_ptr<dsh::WorkspaceFid>;
dsh::WorkspaceFid& Fid(void* p){if(!p||!*static_cast<FidPtr*>(p))throw dsh::GrantError("ERR_WORKSPACE_FID");return **static_cast<FidPtr*>(p);}
template<class F> void* NewFid(F make){void* out=nullptr;Call([&]()->int64_t{auto result=std::make_unique<FidPtr>();*result=make();out=result.release();return 0;});return out;}
void StatOut(const struct stat& st,DshWorkspaceStat* out){if(!out)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");
 *out={static_cast<uint64_t>(st.st_size),static_cast<uint64_t>(st.st_ino),static_cast<uint64_t>(st.st_dev),static_cast<uint32_t>(st.st_mode),S_ISREG(st.st_mode)?1u:S_ISDIR(st.st_mode)?2u:4u,st.st_mtim.tv_sec*1000.0+st.st_mtim.tv_nsec/1000000.0};}
}
void* dsh_workspace_fid_attach(const char* token){return NewFid([&]{
 auto* raw=static_cast<dsh::WorkspaceLease*>(dsh_workspace_ticket_consume(token));
 if(!raw)throw dsh::GrantError("ERR_WORKSPACE_TICKET");
 return dsh::WorkspaceFid::Root(std::shared_ptr<dsh::WorkspaceLease>(raw));});}
void* dsh_workspace_fid_clone(void* f){return NewFid([&]{return Fid(f).Clone();});}
void* dsh_workspace_fid_walk(void* f,const char* name){return NewFid([&]{return Fid(f).Walk(Path(name))->Clone();});}
void dsh_workspace_fid_clunk(void* f){delete static_cast<FidPtr*>(f);}
int dsh_workspace_fid_open(void* f,int write,int truncate){return Call([&]()->int64_t{if((write!=0&&write!=1)||(truncate!=0&&truncate!=1))throw dsh::GrantError("ERR_WORKSPACE_MODE");Fid(f).Open(write,truncate);return 0;});}
int dsh_workspace_fid_stat(void* f,DshWorkspaceStat* out){return Call([&]()->int64_t{StatOut(Fid(f).Stat(),out);return 0;});}
int64_t dsh_workspace_fid_read(void* f,uint64_t offset,void* data,size_t count){return Call([&]()->int64_t{if(!data&&count)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");auto bytes=Fid(f).Read(offset,count);if(!bytes.empty())memcpy(data,bytes.data(),bytes.size());return bytes.size();});}
int64_t dsh_workspace_fid_write(void* f,uint64_t offset,const void* data,size_t count){return Call([&]()->int64_t{if((!data&&count)||count>1024*1024)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");return Fid(f).Write(offset,std::string(data?static_cast<const char*>(data):"",count));});}
void* dsh_workspace_fid_create(void* f,const char* name){return NewFid([&]{return Fid(f).Create(Path(name));});}
int dsh_workspace_fid_mkdir(void* f,const char* name){return Call([&]()->int64_t{Fid(f).Mkdir(Path(name));return 0;});}
int dsh_workspace_fid_remove(void* f,const char* name,int directory){return Call([&]()->int64_t{if(directory!=0&&directory!=1)throw dsh::GrantError("ERR_WORKSPACE_MODE");Fid(f).Remove(Path(name),directory);return 0;});}
int dsh_workspace_fid_rename(void* f,const char* name,void* to,const char* newname){return Call([&]()->int64_t{Fid(f).Rename(Path(name),Fid(to),Path(newname));return 0;});}
int dsh_workspace_fid_list(void* f,DshWorkspaceEntry emit,void* data){return Call([&]()->int64_t{if(!emit)throw dsh::GrantError("ERR_WORKSPACE_BUFFER");auto names=Fid(f).List();for(auto& name:names)if(emit(name.data(),name.size(),data))throw dsh::GrantError("ERR_WORKSPACE_LIST_LIMIT");return 0;});}
