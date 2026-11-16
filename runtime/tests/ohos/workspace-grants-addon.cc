// Test bridge only: real production native owner, genuine Node N-API. This is
// not the Ark production module nor a declaration that SDK linkage passed.
#include <node_api.h>
#include "../../../app/ohos/entry/src/main/cpp/workspace_grants.h"
#include "../../../app/ohos/entry/src/main/cpp/workspace_grants_abi.h"
#include <vector>
void check(napi_status s){if(s!=napi_ok)throw std::runtime_error("addon argument");}
std::string str(napi_env e,napi_value v){size_t n;check(napi_get_value_string_utf8(e,v,nullptr,0,&n));std::vector<char>b(n+1);check(napi_get_value_string_utf8(e,v,b.data(),b.size(),&n));return {b.data(),n};}
napi_value call(napi_env e,napi_callback_info info){try{
 size_t n=5;napi_value a[5],out,v;check(napi_get_cb_info(e,info,&n,a,nullptr,nullptr));
 auto op=str(e,a[0]),id=str(e,a[1]);double g;check(napi_get_value_double(e,a[2],&g));auto& owner=dsh::WorkspaceGrantOwner();
 if(op=="publish"){int32_t fd;bool write;check(napi_get_value_int32(e,a[3],&fd));check(napi_get_value_bool(e,a[4],&write));owner.Publish(id,g,fd,write);}
 auto s=op=="retire"?owner.Retire(id,g):owner.Status(id,g);check(napi_create_object(e,&out));
 for(auto name:{"active","drained","writable"}){bool b=std::string(name)=="active"?s.active:std::string(name)=="drained"?s.drained:s.writable;
  check(napi_get_boolean(e,b,&v));check(napi_set_named_property(e,out,name,v));}
 check(napi_create_double(e,s.generation,&v));check(napi_set_named_property(e,out,"generation",v));
 check(napi_create_double(e,s.leases,&v));check(napi_set_named_property(e,out,"leases",v));return out;
 }catch(const std::exception&x){napi_throw_error(e,"native",x.what());return nullptr;}}
napi_value init(napi_env e,napi_value out){napi_value f;check(napi_create_function(e,"workspaceGrant",NAPI_AUTO_LENGTH,call,nullptr,&f));check(napi_set_named_property(e,out,"workspaceGrant",f));return out;}
NAPI_MODULE(NODE_GYP_MODULE_NAME,init)
