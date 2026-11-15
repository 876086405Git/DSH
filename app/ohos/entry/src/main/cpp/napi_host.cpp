// 未编译 OpenHarmony SDK、未在真机核实。
// This translation unit uses genuine Ark N-API; never force-include the Node
// rename header here. The runner inside libnode crosses only a C ABI.
#include "host_core.h"
#include "file_access.h"
#include <napi/native_api.h>
#include <hilog/log.h>

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
  options.runtime_root = String(env, Property(env, value, "runtimeRoot"));
  options.guest_root = String(env, Property(env, value, "guestRoot"));
  options.dsh_home = String(env, Property(env, value, "dshHome"));
  options.cache_dir = String(env, Property(env, value, "cacheDir"));
  options.native_library_dir = String(env, Property(env, value, "nativeLibraryDir"));
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

napi_value Initialize(napi_env env, napi_value exports) {
  const napi_property_descriptor properties[] = {
    {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"getState", nullptr, GetState, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"drainEvents", nullptr, Drain, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"openUserFile", nullptr, OpenUserFile, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  if (napi_define_properties(env, exports, 5, properties) != napi_ok) return nullptr;
  return exports;
}

napi_module module = {1, 0, nullptr, Initialize, "dsh_host", nullptr, {nullptr, nullptr, nullptr, nullptr}};
__attribute__((constructor)) void Register() { napi_module_register(&module); }
}  // namespace
