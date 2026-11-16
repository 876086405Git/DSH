// Pure Node N-API. OH build force-includes the pinned Node rename header.
// No Ark N-API, no global built-in overrides, no path-based grant acquisition.
#include <node_api.h>
#include <dlfcn.h>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include "../../../../app/ohos/entry/src/main/cpp/workspace_grants_abi.h"
namespace {
#define METHODS(X) X(release) X(error) X(errno) X(read) X(write_flags) X(stat) X(readdir) X(rename) X(remove) X(mkdir) X(ticket_issue) X(ticket_consume) X(ticket_retire) X(snapshot)
#define EDIT_METHODS(X) X(stat_exact_v1) X(edit_input_open_v1) X(edit_input_read_v1) X(edit_input_close_v1) X(edit_begin_v1) X(edit_write_v1) X(edit_close_v1) X(edit_publish_v1) X(edit_abort_v1)
#define MOVE_METHODS(X) X(move_output_begin_v1) X(move_output_publish_v1)
#define WHOLE_METHODS(X) X(whole_output_begin_v1) X(whole_output_write_v1) X(whole_output_close_v1) X(whole_output_publish_step_v1) X(whole_output_abort_v1)
struct Api {
#define FIELD(name) decltype(&dsh_workspace_##name) fn_##name=nullptr;
 METHODS(FIELD)
 EDIT_METHODS(FIELD)
 MOVE_METHODS(FIELD)
 WHOLE_METHODS(FIELD)
#undef FIELD
 void* library=nullptr;bool edit_ready=false,move_ready=false,whole_ready=false;
} api;
std::mutex owner_mutex;napi_env owner=nullptr;bool owner_dead=false;
struct State;
struct Handle {void* lease;std::shared_ptr<State> state;};
struct State:std::enable_shared_from_this<State>{napi_env env;std::set<Handle*> handles;std::set<std::string> tickets;bool active=true;explicit State(napi_env e):env(e){}};
void Check(napi_status status){if(status!=napi_ok)throw std::runtime_error("ERR_WORKSPACE_NAPI");}
std::string Text(napi_env env,napi_value value){size_t size;Check(napi_get_value_string_utf8(env,value,nullptr,0,&size));if(size>4096)throw std::runtime_error("ERR_WORKSPACE_ARGUMENT");std::vector<char> data(size+1);Check(napi_get_value_string_utf8(env,value,data.data(),data.size(),&size));std::string result(data.data(),size);if(result.find('\0')!=std::string::npos)throw std::runtime_error("ERR_WORKSPACE_ARGUMENT");return result;}
double Number(napi_env env,napi_value value){double number;Check(napi_get_value_double(env,value,&number));if(!std::isfinite(number)||number<0||number>9007199254740991.0||number!=std::floor(number))throw std::runtime_error("ERR_WORKSPACE_ARGUMENT");return number;}
napi_value Num(napi_env env,double number){napi_value out;Check(napi_create_double(env,number,&out));return out;}
napi_value String(napi_env env,const char* text,size_t size=NAPI_AUTO_LENGTH){napi_value out;Check(napi_create_string_utf8(env,text,size,&out));return out;}
void Owner(napi_env env){std::lock_guard<std::mutex> lock(owner_mutex);if(owner!=env||owner_dead||!api.library)throw std::runtime_error("ERR_WORKSPACE_OWNER");}
void Connected(){std::lock_guard<std::mutex> lock(owner_mutex);if(!owner||owner_dead||!api.library)throw std::runtime_error("ERR_WORKSPACE_OWNER_UNINITIALIZED");}
void EditApi(){if(!api.edit_ready)throw std::runtime_error("ERR_WORKSPACE_EDIT_ABI");}
void MoveApi(){EditApi();if(!api.move_ready)throw std::runtime_error("ERR_WORKSPACE_MOVE_ABI");}
void WholeApi(){EditApi();if(!api.whole_ready)throw std::runtime_error("ERR_WORKSPACE_WHOLE_ABI");}
struct Args {napi_env env;size_t count=7;napi_value values[7];State* state;
 Args(napi_env e,napi_callback_info info):env(e){void* data;Check(napi_get_cb_info(env,info,&count,values,nullptr,&data));state=static_cast<State*>(data);}
 napi_value operator[](size_t i){if(i>=count)throw std::runtime_error("ERR_WORKSPACE_ARGUMENT");return values[i];}
};
const char* ErrnoCode(int value){switch(value){case ENOENT:return "ENOENT";case EEXIST:return "EEXIST";case ENOTDIR:return "ENOTDIR";case EISDIR:return "EISDIR";case ENOTEMPTY:return "ENOTEMPTY";case ELOOP:return "ELOOP";case EACCES:return "EACCES";case EPERM:return "EPERM";default:return "EIO";}}
void Native(int64_t result){if(result<0){int code=api.fn_errno();throw std::runtime_error(code?ErrnoCode(code):api.fn_error());}}
template<class F> napi_value Run(napi_env env,F work){try{return work();}catch(const std::exception& error){napi_throw_error(env,error.what(),error.what());return nullptr;}}
Handle* Get(Args& args){void* raw;Check(napi_get_value_external(args.env,args[0],&raw));auto* handle=static_cast<Handle*>(raw);if(!handle||!args.state->handles.count(handle)||!handle->lease)throw std::runtime_error("ERR_WORKSPACE_LEASE");return handle;}
void Finalize(napi_env,void* data,void*){auto* h=static_cast<Handle*>(data);if(h->lease)api.fn_release(h->lease);h->state->handles.erase(h);delete h;}
void Cleanup(void* data){auto* holder=static_cast<std::shared_ptr<State>*>(data);auto state=*holder;state->active=false;
 bool main;{std::lock_guard<std::mutex> lock(owner_mutex);main=owner==state->env;if(main)owner_dead=true;}
 if(main)for(const auto& token:state->tickets)api.fn_ticket_retire(token.c_str());
 for(auto* handle:state->handles){if(handle->lease){api.fn_release(handle->lease);handle->lease=nullptr;}}
 delete holder;
}
napi_value Bind(napi_env env,napi_callback_info info){return Run(env,[&]{Args args(env,info);auto path=Text(env,args[0]);std::lock_guard<std::mutex> lock(owner_mutex);
 if(owner||owner_dead)throw std::runtime_error("ERR_WORKSPACE_OWNER_ALREADY_BOUND");
 if(path.empty()||path[0]!='/'||path.size()<16||path.substr(path.size()-15)!="/libdsh_host.so")throw std::runtime_error("ERR_WORKSPACE_HOST_PATH");
 void* lib=dlopen(path.c_str(),RTLD_NOW|RTLD_NOLOAD|RTLD_LOCAL);if(!lib)throw std::runtime_error("ERR_WORKSPACE_HOST_NOT_LOADED");
 Api candidate;candidate.library=lib;
#define LOAD(name) candidate.fn_##name=reinterpret_cast<decltype(candidate.fn_##name)>(dlsym(lib,"dsh_workspace_" #name));if(!candidate.fn_##name){dlclose(lib);throw std::runtime_error("ERR_WORKSPACE_HOST_ABI");}
 METHODS(LOAD)
#undef LOAD
 // Optional as a complete group: old host libraries retain legacy read APIs,
 // but no new edit call can silently fall back to those older operations.
 candidate.edit_ready=true;
#define LOAD_EDIT(name) candidate.fn_##name=reinterpret_cast<decltype(candidate.fn_##name)>(dlsym(lib,"dsh_workspace_" #name));candidate.edit_ready=candidate.edit_ready&&candidate.fn_##name;
 EDIT_METHODS(LOAD_EDIT)
#undef LOAD_EDIT
 candidate.move_ready=candidate.edit_ready;
#define LOAD_MOVE(name) candidate.fn_##name=reinterpret_cast<decltype(candidate.fn_##name)>(dlsym(lib,"dsh_workspace_" #name));candidate.move_ready=candidate.move_ready&&candidate.fn_##name;
 MOVE_METHODS(LOAD_MOVE)
#undef LOAD_MOVE
 candidate.whole_ready=candidate.edit_ready;
#define LOAD_WHOLE(name) candidate.fn_##name=reinterpret_cast<decltype(candidate.fn_##name)>(dlsym(lib,"dsh_workspace_" #name));candidate.whole_ready=candidate.whole_ready&&candidate.fn_##name;
 WHOLE_METHODS(LOAD_WHOLE)
#undef LOAD_WHOLE
 api=candidate;owner=env;return Num(env,1);});}
struct SnapshotRow {std::string id;uint64_t generation;bool writable;};
int SnapshotEntry(const char* id,size_t size,uint64_t generation,int writable,void* data){try{
 static_cast<std::vector<SnapshotRow>*>(data)->push_back({std::string(id,size),generation,writable!=0});return 0;
 }catch(...){return -1;}}
napi_value Snapshot(napi_env env,napi_callback_info info){return Run(env,[&]{Owner(env);Args args(env,info);(void)args;
 std::vector<SnapshotRow> rows;Native(api.fn_snapshot(SnapshotEntry,&rows));napi_value out;Check(napi_create_array_with_length(env,rows.size(),&out));uint32_t index=0;
 for(const auto& row:rows){if(row.generation>9007199254740991ULL)throw std::runtime_error("ERR_WORKSPACE_GENERATION");
  napi_value item,write;Check(napi_create_object(env,&item));Check(napi_get_boolean(env,row.writable,&write));
  Check(napi_set_named_property(env,item,"id",String(env,row.id.data(),row.id.size())));
  Check(napi_set_named_property(env,item,"generation",Num(env,row.generation)));Check(napi_set_named_property(env,item,"writable",write));Check(napi_set_element(env,out,index++,item));}
 return out;});}
napi_value Issue(napi_env env,napi_callback_info info){return Run(env,[&]{Owner(env);Args a(env,info);auto token=Text(env,a[0]),id=Text(env,a[1]);bool write;Check(napi_get_value_bool(env,a[3],&write));
 // Prepare JS return before mutation. Owner tracks every issued token for teardown.
 napi_value result=Num(env,1);if(!a.state->tickets.insert(token).second)throw std::runtime_error("ERR_WORKSPACE_TICKET");
 try{Native(api.fn_ticket_issue(token.c_str(),id.c_str(),static_cast<uint64_t>(Number(env,a[2])),write));}catch(...){a.state->tickets.erase(token);throw;}
 return result;});}
napi_value Retire(napi_env env,napi_callback_info info){return Run(env,[&]{Owner(env);Args a(env,info);auto token=Text(env,a[0]);int result=api.fn_ticket_retire(token.c_str());Native(result);if(result==1)a.state->tickets.erase(token);return Num(env,result);});}
napi_value Consume(napi_env env,napi_callback_info info){return Run(env,[&]{Connected();Args a(env,info);auto token=Text(env,a[0]);auto allocated=std::make_unique<Handle>(Handle{nullptr,a.state->shared_from_this()});
 void* lease=api.fn_ticket_consume(token.c_str());if(!lease){Native(-1);}
 auto* handle=allocated.release();handle->lease=lease;napi_value out;
 try{a.state->handles.insert(handle);Check(napi_create_external(env,handle,Finalize,nullptr,&out));}catch(...){a.state->handles.erase(handle);api.fn_release(lease);delete handle;throw;}
 return out;});}
napi_value Close(napi_env env,napi_callback_info info){return Run(env,[&]{Args a(env,info);auto* handle=Get(a);api.fn_release(handle->lease);handle->lease=nullptr;return Num(env,1);});}
napi_value Read(napi_env env,napi_callback_info info){return Run(env,[&]{Args a(env,info);auto* handle=Get(a);auto path=Text(env,a[1]);auto size=Number(env,a[3]);if(size>1024*1024)throw std::runtime_error("ERR_WORKSPACE_LIMIT");
 std::vector<char> bytes(static_cast<size_t>(size));auto count=api.fn_read(handle->lease,path.c_str(),static_cast<uint64_t>(Number(env,a[2])),bytes.data(),bytes.size());Native(count);napi_value result;Check(napi_create_buffer_copy(env,count,bytes.data(),nullptr,&result));return result;});}
napi_value Write(napi_env env,napi_callback_info info){return Run(env,[&]{Args a(env,info);auto* handle=Get(a);auto path=Text(env,a[1]);void* bytes;size_t length;Check(napi_get_buffer_info(env,a[2],&bytes,&length));
 auto count=api.fn_write_flags(handle->lease,path.c_str(),static_cast<uint64_t>(Number(env,a[3])),bytes,length,static_cast<int>(Number(env,a[4])));Native(count);return Num(env,count);});}
napi_value Stat(napi_env env,napi_callback_info info){return Run(env,[&]{Args a(env,info);auto* handle=Get(a);auto path=Text(env,a[1]);DshWorkspaceStat st{};Native(api.fn_stat(handle->lease,path.c_str(),&st));napi_value out;Check(napi_create_object(env,&out));
 const std::map<std::string,double> values={{"size",static_cast<double>(st.size)},{"mode",st.mode},{"type",st.type},{"mtimeMs",st.mtime_ms},{"ino",static_cast<double>(st.ino)},{"dev",static_cast<double>(st.dev)}};
 for(const auto& pair:values)Check(napi_set_named_property(env,out,pair.first.c_str(),Num(env,pair.second)));
 return out;});}
napi_value StatExact(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();auto path=Text(env,a[1]);
 DshWorkspaceStatExactV1 st{};Native(api.fn_stat_exact_v1(handle->lease,path.c_str(),&st,sizeof(st)));
 if(st.version!=1||st.reserved||st.mtime_nsec>999999999||st.ctime_nsec>999999999||st.type<1||st.type>4)throw std::runtime_error("ERR_WORKSPACE_EDIT_ABI");
 napi_value out;Check(napi_create_object(env,&out));
 Check(napi_set_named_property(env,out,"schemaVersion",Num(env,1)));
 const std::map<std::string,std::string> values={{"dev",std::to_string(st.dev)},{"ino",std::to_string(st.ino)},{"size",std::to_string(st.size)},
  {"mtimeSec",std::to_string(st.mtime_sec)},{"mtimeNsec",std::to_string(st.mtime_nsec)},{"ctimeSec",std::to_string(st.ctime_sec)},{"ctimeNsec",std::to_string(st.ctime_nsec)}};
 for(const auto& pair:values)Check(napi_set_named_property(env,out,pair.first.c_str(),String(env,pair.second.c_str())));
 Check(napi_set_named_property(env,out,"mode",Num(env,st.mode)));
 Check(napi_set_named_property(env,out,"type",Num(env,st.type)));
 return out;});}
napi_value OpenEditInput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();auto path=Text(env,a[1]);uint64_t size=0;
 Native(api.fn_edit_input_open_v1(handle->lease,path.c_str(),&size));
 try{return String(env,std::to_string(size).c_str());}
 catch(...){
  // If constructing the JS size fails, do not strand a normally closeable
  // input slot. An uncertain close remains sticky for the existing retire API.
  api.fn_edit_input_close_v1(handle->lease);throw;
 }
 });}
napi_value ReadEditInput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();auto maximum=Number(env,a[1]);
 if(maximum>1024*1024)throw std::runtime_error("ERR_WORKSPACE_LIMIT");
 std::vector<char> bytes(static_cast<size_t>(maximum));
 const auto count=api.fn_edit_input_read_v1(handle->lease,bytes.data(),bytes.size());Native(count);
 if(static_cast<uint64_t>(count)>bytes.size())throw std::runtime_error("ERR_WORKSPACE_EDIT_ABI");
 napi_value result;Check(napi_create_buffer_copy(env,static_cast<size_t>(count),bytes.data(),nullptr,&result));return result;});}
napi_value CloseEditInput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();napi_value result=Num(env,1);
 Native(api.fn_edit_input_close_v1(handle->lease));return result;});}
napi_value BeginEdit(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();auto path=Text(env,a[1]);auto mode=Number(env,a[2]);
 if(mode>0777)throw std::runtime_error("ERR_WORKSPACE_ARGUMENT");
 napi_value result=Num(env,1);Native(api.fn_edit_begin_v1(handle->lease,path.c_str(),static_cast<uint32_t>(mode)));return result;});}
napi_value WriteEdit(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();void* bytes;size_t length;Check(napi_get_buffer_info(env,a[1],&bytes,&length));
 const auto count=api.fn_edit_write_v1(handle->lease,bytes,length);Native(count);
 if(static_cast<uint64_t>(count)>length)throw std::runtime_error("ERR_WORKSPACE_EDIT_ABI");
 return Num(env,count);});}
napi_value CloseEdit(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();napi_value result=Num(env,1);
 Native(api.fn_edit_close_v1(handle->lease));return result;});}
napi_value PublishEdit(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();
 // Prepare both results before mutation: no N-API allocation after rename.
 napi_value yes,no;Check(napi_get_boolean(env,true,&yes));Check(napi_get_boolean(env,false,&no));
 const int result=api.fn_edit_publish_v1(handle->lease);Native(result);
 return result==1?yes:no;});}
napi_value AbortEdit(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);EditApi();napi_value result=Num(env,1);
 Native(api.fn_edit_abort_v1(handle->lease));return result;});}
napi_value BeginMoveOutput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);MoveApi();auto path=Text(env,a[1]);auto mode=Number(env,a[2]);bool absent;
 Check(napi_get_value_bool(env,a[3],&absent));if(mode>0777)throw std::runtime_error("ERR_WORKSPACE_ARGUMENT");
 napi_value result=Num(env,1);Native(api.fn_move_output_begin_v1(handle->lease,path.c_str(),static_cast<uint32_t>(mode),absent));return result;});}
napi_value PublishMoveOutput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);MoveApi();
 napi_value yes,no,effects[3];Check(napi_get_boolean(env,true,&yes));Check(napi_get_boolean(env,false,&no));
 for(unsigned i=0;i<3;++i)effects[i]=Num(env,i);
 DshWorkspaceMovePublishV1 result{};const int status=api.fn_move_output_publish_v1(handle->lease,&result,sizeof(result));
 if(result.version!=1||result.reserved||result.effect>2||result.staging_removed>1)throw std::runtime_error("ERR_WORKSPACE_MOVE_ABI");
 if(status<0){
  const int number=api.fn_errno();const char* code=number?ErrnoCode(number):api.fn_error();
  napi_value error;Check(napi_create_error(env,String(env,code),String(env,code),&error));
  Check(napi_set_named_property(env,error,"workspaceMoveEffect",effects[result.effect]));Check(napi_throw(env,error));return static_cast<napi_value>(nullptr);
 }
 if(result.effect!=2)throw std::runtime_error("ERR_WORKSPACE_MOVE_ABI");
 return result.staging_removed?yes:no;
 });}

napi_value BeginWholeOutput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);WholeApi();auto path=Text(env,a[1]);
 const auto policy=Number(env,a[2]),mode=Number(env,a[3]);bool absent;Check(napi_get_value_bool(env,a[4],&absent));
 if(policy>1||mode>0777||(policy==1&&mode!=0))throw std::runtime_error("ERR_WORKSPACE_ARGUMENT");
 napi_value result=Num(env,1);Native(api.fn_whole_output_begin_v1(handle->lease,path.c_str(),static_cast<uint32_t>(policy),static_cast<uint32_t>(mode),absent));return result;});}
napi_value WriteWholeOutput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);WholeApi();void* bytes;size_t length;Check(napi_get_buffer_info(env,a[1],&bytes,&length));
 const auto count=api.fn_whole_output_write_v1(handle->lease,bytes,length);Native(count);
 if(static_cast<uint64_t>(count)>length)throw std::runtime_error("ERR_WORKSPACE_WHOLE_ABI");
 return Num(env,count);});}
napi_value CloseWholeOutput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);WholeApi();napi_value result=Num(env,1);Native(api.fn_whole_output_close_v1(handle->lease));return result;});}
napi_value WholeResult(napi_env env,uint32_t effect,uint32_t next,bool removed){
 napi_value result,yes,clean;Check(napi_create_object(env,&result));Check(napi_get_boolean(env,true,&yes));Check(napi_get_boolean(env,removed,&clean));
 Check(napi_set_named_property(env,result,"schemaVersion",Num(env,1)));
 Check(napi_set_named_property(env,result,"effectKnown",yes));Check(napi_set_named_property(env,result,"effect",Num(env,effect)));
 Check(napi_set_named_property(env,result,"continuation",Num(env,next)));Check(napi_set_named_property(env,result,"stagingRemoved",clean));return result;
}
napi_value StepWholeOutput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);WholeApi();
 // Allocate every normal result before the native mutation. A failed error
 // construction is still unknown to JS; it must not be guessed as effect0.
 napi_value results[5]={WholeResult(env,0,1,false),WholeResult(env,1,2,false),WholeResult(env,1,3,false),WholeResult(env,2,0,false),WholeResult(env,2,0,true)};
 napi_value effects[3]={Num(env,0),Num(env,1),Num(env,2)};
 DshWorkspaceWholePublishV1 out{};const int status=api.fn_whole_output_publish_step_v1(handle->lease,&out,sizeof(out));
 if(out.version!=1||out.reserved||out.effect_known>1||out.effect>2||out.continuation>3||out.staging_removed>1)throw std::runtime_error("ERR_WORKSPACE_WHOLE_ABI");
 if(status<0){
  const int number=api.fn_errno();const char* code=number?ErrnoCode(number):api.fn_error();napi_value error;
  Check(napi_create_error(env,String(env,code),String(env,code),&error));
  if(out.effect_known)Check(napi_set_named_property(env,error,"workspaceWholeEffect",effects[out.effect]));
  Check(napi_throw(env,error));return static_cast<napi_value>(nullptr);
 }
 if(!out.effect_known)throw std::runtime_error("ERR_WORKSPACE_WHOLE_ABI");
 if(out.effect==0&&out.continuation==1&&!out.staging_removed)return results[0];
 if(out.effect==1&&out.continuation==2&&!out.staging_removed)return results[1];
 if(out.effect==1&&out.continuation==3&&!out.staging_removed)return results[2];
 if(out.effect==2&&out.continuation==0)return results[out.staging_removed?4:3];
 throw std::runtime_error("ERR_WORKSPACE_WHOLE_ABI");});}
napi_value AbortWholeOutput(napi_env env,napi_callback_info info){return Run(env,[&]{
 Args a(env,info);auto* handle=Get(a);WholeApi();napi_value result=Num(env,1);Native(api.fn_whole_output_abort_v1(handle->lease));return result;});}
struct Entries {std::vector<std::string> names;};
int Entry(const char* name,size_t size,void* data){try{static_cast<Entries*>(data)->names.emplace_back(name,size);return 0;}catch(...){return -1;}}
napi_value Readdir(napi_env env,napi_callback_info info){return Run(env,[&]{Args a(env,info);auto* handle=Get(a);auto path=Text(env,a[1]);Entries entries;Native(api.fn_readdir(handle->lease,path.c_str(),Entry,&entries));napi_value out;Check(napi_create_array_with_length(env,entries.names.size(),&out));uint32_t i=0;for(const auto& name:entries.names)Check(napi_set_element(env,out,i++,String(env,name.data(),name.size())));return out;});}
napi_value Mutate(napi_env env,napi_callback_info info){return Run(env,[&]{Args a(env,info);auto* handle=Get(a);auto op=Text(env,a[1]),path=Text(env,a[2]);int result;
 if(op=="rename"){auto to=Text(env,a[3]);result=api.fn_rename(handle->lease,path.c_str(),to.c_str());}
 else if(op=="remove"){bool directory;Check(napi_get_value_bool(env,a[3],&directory));result=api.fn_remove(handle->lease,path.c_str(),directory);}
 else if(op=="mkdir")result=api.fn_mkdir(handle->lease,path.c_str());else throw std::runtime_error("ERR_WORKSPACE_OPERATION");
 Native(result);return Num(env,0);});}
napi_value Init(napi_env env,napi_value exports){return Run(env,[&]{auto state=std::make_shared<State>(env);auto* holder=new std::shared_ptr<State>(state);Check(napi_add_env_cleanup_hook(env,Cleanup,holder));
 const std::map<std::string,napi_callback> methods={{"bindOwner",Bind},{"snapshot",Snapshot},{"issue",Issue},{"retire",Retire},{"consume",Consume},{"close",Close},{"read",Read},{"write",Write},{"stat",Stat},{"readdir",Readdir},{"mutate",Mutate},{"statExact",StatExact},{"openEditInput",OpenEditInput},{"readEditInput",ReadEditInput},{"closeEditInput",CloseEditInput},{"beginEdit",BeginEdit},{"writeEdit",WriteEdit},{"closeEdit",CloseEdit},{"publishEdit",PublishEdit},{"abortEdit",AbortEdit},{"beginMoveOutput",BeginMoveOutput},{"publishMoveOutput",PublishMoveOutput},{"beginWholeOutput",BeginWholeOutput},{"writeWholeOutput",WriteWholeOutput},{"closeWholeOutput",CloseWholeOutput},{"stepWholeOutput",StepWholeOutput},{"abortWholeOutput",AbortWholeOutput}};
 for(const auto& pair:methods){napi_value method;Check(napi_create_function(env,pair.first.c_str(),NAPI_AUTO_LENGTH,pair.second,state.get(),&method));Check(napi_set_named_property(env,exports,pair.first.c_str(),method));}return exports;});}
}
NAPI_MODULE(NODE_GYP_MODULE_NAME,Init)
