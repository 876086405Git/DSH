#pragma once
#include <node.h>
#include <node_api.h>
#include <mutex>
#include <string>
namespace dsh_ios::guest_config {
inline std::mutex mutex;
inline bool enabled = false;
inline bool Enabled() { std::lock_guard<std::mutex> lock(mutex); return enabled; }
inline std::string snapshot = "{\"installed\":false}";
inline napi_value Read(napi_env env, napi_callback_info) {
  std::string copy;
  { std::lock_guard<std::mutex> lock(mutex); copy = snapshot; }
  napi_value result;
  if (napi_create_string_utf8(env, copy.data(), copy.size(), &result) != napi_ok) return nullptr;
  return result;
}
inline napi_value Initialize(napi_env env, napi_value exports) {
  napi_value read;
  if (napi_create_function(env, "read", NAPI_AUTO_LENGTH, Read, nullptr, &read) != napi_ok ||
      napi_set_named_property(env, exports, "read", read) != napi_ok) return nullptr;
  return exports;
}
inline napi_module module = {NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
  "runtime/ios/host/guest_config_binding.h", Initialize, "dsh_ios_guest_config", nullptr,
  {nullptr, nullptr, nullptr, nullptr}};
inline void Register() { napi_module_register(&module); }
} // namespace dsh_ios::guest_config
