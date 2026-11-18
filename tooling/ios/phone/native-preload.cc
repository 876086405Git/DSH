// Linux-only verification adapter. Never included by the product build script.
#include "phone_binding.h"
#include <node.h>
#include <node_api.h>
#include <array>
namespace {
napi_value Arm(napi_env env, napi_callback_info info) {
  napi_value args[2], result;
  size_t count = 2, size = 0;
  std::array<char, 128> run{}, token{};
  if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 2 ||
      napi_get_value_string_utf8(env, args[0], run.data(), run.size(), &size) != napi_ok ||
      napi_get_value_string_utf8(env, args[1], token.data(), token.size(), &size) != napi_ok) return nullptr;
  napi_create_int32(env, dsh_ios_phone_arm(run.data(), token.data()), &result);
  return result;
}
napi_value Clear(napi_env env, napi_callback_info info) {
  napi_value arg, result;
  size_t count = 1, size = 0;
  std::array<char, 128> run{};
  if (napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr) != napi_ok || count != 1 ||
      napi_get_value_string_utf8(env, arg, run.data(), run.size(), &size) != napi_ok) return nullptr;
  dsh_ios_phone_clear(run.data()); napi_get_undefined(env, &result); return result;
}
napi_value Initialize(napi_env env, napi_value exports) {
  napi_value arm, clear;
  napi_create_function(env, "arm", NAPI_AUTO_LENGTH, Arm, nullptr, &arm);
  napi_create_function(env, "clear", NAPI_AUTO_LENGTH, Clear, nullptr, &clear);
  napi_set_named_property(env, exports, "arm", arm); napi_set_named_property(env, exports, "clear", clear);
  return exports;
}
napi_module module = {NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
  "tooling/ios/phone/native-preload.cc", Initialize, "dsh_ios_phone_test", nullptr, {nullptr, nullptr, nullptr, nullptr}};
__attribute__((constructor)) void Register() { RegisterPhoneBinding(); napi_module_register(&module); }
}
