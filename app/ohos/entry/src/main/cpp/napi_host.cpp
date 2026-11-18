// 未编译 OpenHarmony SDK、未在真机核实。
// This translation unit uses genuine Ark N-API; never force-include the Node
// rename header here. The runner inside libnode crosses only a C ABI.
#include "host_core.h"
#include "file_access.h"
#include "workspace_grants.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <dlfcn.h>
#include <cmath>
#include <cstring>
#include "../../../../../../runtime/ohos/host/phone_contract.h"

extern "C" int dsh_node_start(int argc, char** argv);
extern "C" int dsh_node_stop();

namespace {
dsh::Host& Host() {
  static auto* host = new dsh::Host([](const std::string& stream, const std::string& line) {
    OH_LOG_Print(LOG_APP, stream == "stderr" ? LOG_ERROR : LOG_INFO, 0xD051, "DSHNode", "%{public}s", line.c_str());
  });
  return *host;
}

void Check(napi_status status) {
  if (status != napi_ok) throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT", "Invalid native host argument");
}

napi_value Undefined(napi_env env) { napi_value value; Check(napi_get_undefined(env, &value)); return value; }
napi_value Null(napi_env env) { napi_value value; Check(napi_get_null(env, &value)); return value; }
napi_value Text(napi_env env, const std::string& text) {
  napi_value value; Check(napi_create_string_utf8(env, text.data(), text.size(), &value)); return value;
}
void Put(napi_env env, napi_value object, const char* key, napi_value value) { Check(napi_set_named_property(env, object, key, value)); }
void OptionalText(napi_env env, napi_value object, const char* key, const std::string& text) { Put(env, object, key, text.empty() ? Null(env) : Text(env, text)); }
void Number(napi_env env, napi_value object, const char* key, const std::optional<int>& number) {
  napi_value value = Null(env);
  if (number) Check(napi_create_int32(env, *number, &value));
  Put(env, object, key, value);
}

std::string String(napi_env env, napi_value value) {
  size_t length;
  Check(napi_get_value_string_utf8(env, value, nullptr, 0, &length));
  std::vector<char> bytes(length + 1);
  Check(napi_get_value_string_utf8(env, value, bytes.data(), bytes.size(), &length));
  return std::string(bytes.data(), length);
}
napi_value Property(napi_env env, napi_value object, const char* key) {
  napi_value value; Check(napi_get_named_property(env, object, key, &value)); return value;
}

dsh::HostOptions Options(napi_env env, napi_value value) {
  dsh::HostOptions options;
  napi_value safe = Property(env, value, "safeMode");
  napi_valuetype safe_type;
  Check(napi_typeof(env, safe, &safe_type));
  if (safe_type != napi_undefined) Check(napi_get_value_bool(env, safe, &options.safe_mode));
  options.runtime_root = String(env, Property(env, value, "runtimeRoot"));
  options.guest_root = String(env, Property(env, value, "guestRoot"));
  options.dsh_home = String(env, Property(env, value, "dshHome"));
  options.cache_dir = String(env, Property(env, value, "cacheDir"));
  options.native_library_dir = String(env, Property(env, value, "nativeLibraryDir"));
  options.linux_directory = String(env, Property(env, value, "linuxDirectory"));
  napi_value roots = Property(env, value, "workspaceRoots");
  uint32_t count;
  Check(napi_get_array_length(env, roots, &count));
  for (uint32_t i = 0; i < count; ++i) {
    napi_value item; Check(napi_get_element(env, roots, i, &item));
    options.workspace_roots.push_back(String(env, item));
  }
  napi_value environment = Property(env, value, "env"), keys;
  Check(napi_get_property_names(env, environment, &keys));
  Check(napi_get_array_length(env, keys, &count));
  for (uint32_t i = 0; i < count; ++i) {
    napi_value key, item;
    Check(napi_get_element(env, keys, i, &key));
    Check(napi_get_property(env, environment, key, &item));
    options.env.emplace(String(env, key), String(env, item));
  }
  return options;
}

napi_value Throw(napi_env env, const std::exception& error) {
  const auto* host_error = dynamic_cast<const dsh::HostError*>(&error);
  napi_throw_error(env, host_error ? host_error->code.c_str() : "ERR_OHOS_HOST_NATIVE",
                   host_error ? error.what() : "The native host operation failed");
  return nullptr;
}

napi_value Start(napi_env env, napi_callback_info info) {
  try {
    size_t count = 1; napi_value argument;
    Check(napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr));
    if (count != 1) throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT", "Host options are required");
    auto options = Options(env, argument);
    // The require-builtin addon finds V8 with dlsym(RTLD_DEFAULT). libnode came in
    // as a local dependency of this library, so its symbols are global only after this.
    if (dlopen("libnode.so", RTLD_NOW | RTLD_NOLOAD | RTLD_GLOBAL) == nullptr) {
      throw dsh::HostError("ERR_OHOS_HOST_NODE_SYMBOLS", "The embedded Node library could not be made global");
    }
    Host().Start(std::move(options), dsh_node_start, dsh_node_stop);
    return Undefined(env);
  } catch (const std::exception& error) { return Throw(env, error); }
}

napi_value Stop(napi_env env, napi_callback_info) {
  try { Host().Stop(); return Undefined(env); }
  catch (const std::exception& error) { return Throw(env, error); }
}

napi_value GetState(napi_env env, napi_callback_info) {
  try {
    const auto state = Host().State();
    napi_value result, consumed;
    Check(napi_create_object(env, &result));
    Put(env, result, "phase", Text(env, state.phase));
    Check(napi_get_boolean(env, state.consumed, &consumed)); Put(env, result, "consumed", consumed);
    OptionalText(env, result, "baseUrl", state.base_url); OptionalText(env, result, "token", state.token);
    OptionalText(env, result, "errorCode", state.error_code); OptionalText(env, result, "errorMessage", state.error_message);
    Number(env, result, "exitCode", state.exit_code);
    return result;
  } catch (const std::exception& error) { return Throw(env, error); }
}

napi_value Drain(napi_env env, napi_callback_info) {
  try {
    const auto events = Host().Drain();
    napi_value result; Check(napi_create_array_with_length(env, events.size(), &result));
    for (size_t i = 0; i < events.size(); ++i) {
      const auto& event = events[i];
      napi_value item; Check(napi_create_object(env, &item));
      Put(env, item, "kind", Text(env, event.kind));
      if (event.kind == "log") { Put(env, item, "stream", Text(env, event.stream)); Put(env, item, "line", Text(env, event.line)); }
      else if (event.kind == "ready") { Put(env, item, "baseUrl", Text(env, event.base_url)); Put(env, item, "token", Text(env, event.token)); }
      else if (event.kind == "exit") Number(env, item, "exitCode", event.exit_code);
      else { Put(env, item, "errorCode", Text(env, event.error_code)); Put(env, item, "message", Text(env, event.message)); }
      Check(napi_set_element(env, result, i, item));
    }
    return result;
  } catch (const std::exception& error) { return Throw(env, error); }
}

napi_value OpenUserFile(napi_env env, napi_callback_info info) {
  try {
    size_t count = 2; napi_value arguments[2];
    Check(napi_get_cb_info(env, info, &count, arguments, nullptr, nullptr));
    if (count != 2) throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT", "Root and relative path are required");
    const int descriptor = dsh::OpenUserFile(String(env, arguments[0]), String(env, arguments[1]));
    napi_value value;
    const napi_status status = napi_create_int32(env, descriptor, &value);
    if (status != napi_ok) { close(descriptor); Check(status); }
    return value;
  } catch (const std::system_error&) {
    napi_throw_error(env, "ERR_OHOS_FILE_ACCESS", "Cannot open an authorized regular file");
    return nullptr;
  } catch (const std::exception& error) { return Throw(env, error); }
}

double SafeNumber(napi_env env, napi_value value) {
  double number; Check(napi_get_value_double(env, value, &number));
  if (!std::isfinite(number) || number < 0 || number > 9007199254740991.0 || std::floor(number) != number)
    throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT", "Lifecycle values must be safe nonnegative integers");
  return number;
}
napi_value WorkspaceStatus(napi_env env, const dsh::WorkspaceGrantStatus& status) {
  napi_value result, value; Check(napi_create_object(env, &result));
  Check(napi_get_boolean(env, status.active, &value)); Put(env,result,"active",value);
  Check(napi_get_boolean(env, status.drained, &value)); Put(env,result,"drained",value);
  Check(napi_get_boolean(env, status.writable, &value)); Put(env,result,"writable",value);
  Check(napi_create_double(env, status.generation, &value)); Put(env,result,"generation",value);
  Check(napi_create_double(env, status.leases, &value)); Put(env,result,"leases",value);
  return result;
}
napi_value WorkspaceCall(napi_env env, napi_callback_info info) {
  try {
    size_t count=5; napi_value args[5]; Check(napi_get_cb_info(env,info,&count,args,nullptr,nullptr));
    if(count<3) throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT","Workspace operation, identity and generation required");
    const auto operation=String(env,args[0]), id=String(env,args[1]);
    const auto generation=static_cast<uint64_t>(SafeNumber(env,args[2]));
    auto& grants=dsh::WorkspaceGrantOwner();
    if(operation=="publish") {
      if(count!=5) throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT","Borrowed directory descriptor and mode required");
      int32_t fd; bool writable; Check(napi_get_value_int32(env,args[3],&fd));Check(napi_get_value_bool(env,args[4],&writable));
      grants.Publish(id,generation,fd,writable);
      try { return WorkspaceStatus(env,grants.Status(id,generation)); }
      catch (...) { grants.Retire(id,generation); throw; }
    } else if(operation=="retire") return WorkspaceStatus(env,grants.Retire(id,generation));
    else if(operation!="status") throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT","Unknown workspace operation");
    return WorkspaceStatus(env,grants.Status(id,generation));
  } catch(const dsh::GrantError& error) { napi_throw_error(env,error.code.c_str(),"Workspace grant is unavailable");return nullptr;
  } catch(const std::system_error&) { napi_throw_error(env,"ERR_WORKSPACE_IO","Workspace descriptor operation failed");return nullptr;
  } catch(const std::exception& error) {return Throw(env,error);}
}

napi_value LifecycleUpdate(napi_env env, napi_callback_info info) {
  try {
    size_t count=4; napi_value args[4]; Check(napi_get_cb_info(env,info,&count,args,nullptr,nullptr));
    if(count!=4) throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT", "Lifecycle update needs four arguments");
    const auto operation=String(env,args[0]); const auto owner=static_cast<uint64_t>(SafeNumber(env,args[1]));
    const auto grant=static_cast<uint64_t>(SafeNumber(env,args[2])); const auto value=static_cast<int64_t>(SafeNumber(env,args[3]));
    auto& state=Host().Lifecycle(); uint64_t answer=0;
    if(operation=="owner" && value<=1 && owner==0 && grant==0) answer=state.BeginOwner(value==1);
    else if(operation=="foreground" && value<=1) answer=state.Foreground(owner,value==1);
    else if(operation=="continuous" && value<=1) answer=state.SetContinuous(owner,value==1);
    else if(operation=="begin") answer=state.BeginGrant(owner);
    else if(operation=="activate") answer=state.Activate(owner,grant,value);
    else if(operation=="drain") answer=state.Drain(owner,grant);
    else if(operation=="release") answer=state.Release(owner,grant);
    else if(operation=="retire") answer=state.Retire(owner);
    else throw dsh::HostError("ERR_OHOS_HOST_ARGUMENT", "Unknown lifecycle update");
    napi_value result;Check(napi_create_double(env,static_cast<double>(answer),&result));return result;
  } catch(const std::exception& error) { return Throw(env,error); }
}
napi_value LifecycleSnapshot(napi_env env,napi_callback_info) {
  try {
    DshHostLifecycleSnapshotV1 data{};
    if(Host().Lifecycle().Snapshot(&data,sizeof(data))!=0) throw dsh::HostError("ERR_OHOS_LIFECYCLE_NATIVE", "Lifecycle snapshot unavailable");
    napi_value result;Check(napi_create_object(env,&result));
    const auto put=[&](const char* key,double value){napi_value number;Check(napi_create_double(env,value,&number));Put(env,result,key,number);};
    put("version",data.version);put("engineGeneration",data.engine_generation);put("ownerGeneration",data.owner_generation);
    put("revision",data.revision);put("grantGeneration",data.grant_generation);put("nowMs",data.now_ms);
    put("deadlineMs",data.deadline_ms);put("drainAtMs",data.drain_at_ms);put("phase",data.phase);
    put("available",data.available);put("foreground",data.foreground);put("clockFailed",data.clock_failed);
    return result;
  } catch(const std::exception& error) { return Throw(env,error); }
}


napi_value PhoneAttach(napi_env env,napi_callback_info info) {
  try {
    size_t count=3;napi_value a[3];Check(napi_get_cb_info(env,info,&count,a,nullptr,nullptr));
    if(count!=3)throw dsh::HostError("ERR_OHOS_PHONE_ARGUMENT","Phone attach requires owner hash and native scope");
    auto hash=String(env,a[0]);auto engine=static_cast<uint64_t>(SafeNumber(env,a[1]));auto owner=static_cast<uint64_t>(SafeNumber(env,a[2]));
    auto generation=Host().Phone().Attach(hash,engine,owner);napi_value result;
    Check(napi_create_double(env,static_cast<double>(generation),&result));return result;
  }catch(const std::exception& error){return Throw(env,error);}
}
napi_value PhoneSnapshot(napi_env env,napi_callback_info) {
  try{auto state=Host().Phone().Snapshot();napi_value result,value;Check(napi_create_object(env,&result));
    Check(napi_get_boolean(env,state.available,&value));Put(env,result,"available",value);
    Check(napi_get_boolean(env,state.foreground,&value));Put(env,result,"foreground",value);
    Put(env,result,"engineId",Text(env,state.engine_id));Put(env,result,"ownerHash",Text(env,state.owner_hash));
    Check(napi_create_double(env,static_cast<double>(state.generation),&value));Put(env,result,"bridgeGeneration",value);
    Check(napi_create_double(env,static_cast<double>(state.now),&value));Put(env,result,"nowMs",value);return result;
  }catch(const std::exception& error){return Throw(env,error);}
}
napi_value PhoneRetire(napi_env env,napi_callback_info info) {
  try{size_t count=1;napi_value a;Check(napi_get_cb_info(env,info,&count,&a,nullptr,nullptr));
    if(count!=1)throw dsh::HostError("ERR_OHOS_PHONE_ARGUMENT","Phone generation required");
    auto generation=static_cast<uint64_t>(SafeNumber(env,a));napi_value yes,no;
    Check(napi_get_boolean(env,true,&yes));Check(napi_get_boolean(env,false,&no));
    return Host().Phone().Retire(generation)?yes:no;
  }catch(const std::exception& error){return Throw(env,error);}
}
dsh::PhoneRequest PhoneKey(napi_env env,napi_value value) {
  dsh::PhoneRequest key;key.scope.engine_id=String(env,Property(env,value,"engineId"));
  key.scope.generation=static_cast<uint64_t>(SafeNumber(env,Property(env,value,"bridgeGeneration")));
  key.request_id=String(env,Property(env,value,"requestId"));key.nonce=String(env,Property(env,value,"executionNonce"));return key;
}
napi_value PhoneOperation(napi_env env,napi_callback_info info) {
  try {
    size_t count=3;napi_value a[3];Check(napi_get_cb_info(env,info,&count,a,nullptr,nullptr));
    if(count<2)throw dsh::HostError("ERR_OHOS_PHONE_ARGUMENT","Phone operation and scope required");
    auto operation=String(env,a[0]);auto key=PhoneKey(env,a[1]);napi_value yes,no;
    // Allocate all boolean return handles before the irreversible consume.
    Check(napi_get_boolean(env,true,&yes));Check(napi_get_boolean(env,false,&no));
    if(operation=="check") {
      const auto state=Host().Phone().Check(key);
      return Text(env,std::string("{\"pending\":")+(state.pending?"true":"false")+",\"foreground\":"+(state.foreground?"true":"false")+
        ",\"nowMs\":"+std::to_string(state.now)+",\"deadlineMs\":"+std::to_string(state.deadline)+"}");
    }
    if(operation=="consume")return Host().Phone().Consume(key)?yes:no;
    if(operation=="inspect") {auto request=Host().Phone().Inspect(key);return request?Text(env,request->json):Null(env);}
    if(operation=="consumed") {auto consumed=Host().Phone().Consumed(key);return consumed?(*consumed?yes:no):Null(env);}
    if(operation=="finish" && count==3) {auto result=String(env,a[2]);return Host().Phone().Finish(key,result)?yes:no;}
    if(operation=="revoke") {auto answer=Host().Phone().Revoke(key);return answer<0?Null(env):(answer?yes:no);}
    throw dsh::HostError("ERR_OHOS_PHONE_ARGUMENT","Unknown private phone operation");
  }catch(const std::exception& error){return Throw(env,error);}
}

napi_value Initialize(napi_env env, napi_value exports) {
  const napi_property_descriptor properties[] = {
    {"phoneSnapshot", nullptr, PhoneSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"phoneAttach", nullptr, PhoneAttach, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"phoneRetire", nullptr, PhoneRetire, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"phoneOperation", nullptr, PhoneOperation, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"getState", nullptr, GetState, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"drainEvents", nullptr, Drain, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"openUserFile", nullptr, OpenUserFile, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"workspaceGrant", nullptr, WorkspaceCall, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"lifecycleUpdate", nullptr, LifecycleUpdate, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"lifecycleSnapshot", nullptr, LifecycleSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  if (napi_define_properties(env, exports, 12, properties) != napi_ok) return nullptr;
  return exports;
}

napi_module module = {1, 0, nullptr, Initialize, "dsh_host", nullptr, {nullptr, nullptr, nullptr, nullptr}};
__attribute__((constructor)) void Register() { napi_module_register(&module); }
}  // namespace

// The only cross-DSO lifecycle entry is read-only. Ark NAPI owns all mutations.
extern "C" __attribute__((visibility("default")))
int dsh_host_lifecycle_snapshot_v1(DshHostLifecycleSnapshotV1* output,uint32_t size) noexcept {
  try { return Host().Lifecycle().Snapshot(output,size); }
  catch (...) { return -2; }
}

extern "C" __attribute__((visibility("default")))
int dsh_host_phone_v1(const DshPhoneInputV1* in,DshPhoneSnapshotV1* out) noexcept {
  try {
    if(!in || in->size!=sizeof(*in) || in->version!=1 || in->reserved!=0 ||
       !memchr(in->engine_id,0,sizeof(in->engine_id)) || !memchr(in->request_id,0,sizeof(in->request_id)) ||
       !memchr(in->nonce,0,sizeof(in->nonce)) || !memchr(in->tool,0,sizeof(in->tool)) ||
       in->generation>9007199254740991ULL || in->data_size>4*1024*1024 || (in->data_size&&!in->data))return -1;
    auto& phone=Host().Phone();
    if(in->operation==DshPhoneBind)return phone.Bind(in->engine_id)?1:0;
    if(in->operation==DshPhoneSnapshot) {
      if(!out)return -1;
      auto state=phone.Snapshot();*out={};out->size=sizeof(*out);out->version=1;
      out->available=state.available;out->foreground=state.foreground;out->generation=state.generation;out->now_ms=state.now;
      memcpy(out->engine_id,state.engine_id.data(),state.engine_id.size());memcpy(out->owner_hash,state.owner_hash.data(),state.owner_hash.size());return 1;
    }
    dsh::PhoneRequest request{{in->engine_id,in->generation},in->request_id,in->nonce,in->tool,
      in->data_size?std::string(in->data,in->data_size):std::string(),in->deadline_ms};
    if(in->operation==DshPhoneClaim)return phone.Claim(request)?1:0;
    if(in->operation==DshPhoneRevoke){auto value=phone.Revoke(request);return value<0?2:value;}
    if(in->operation==DshPhoneComplete)return phone.Complete(request,request.json)?1:0;
    return -1;
  }catch(...){return -2;}
}
