#include "phone_binding.h"
#include <node.h>
#include <node_api.h>
#include <array>
#include <cstring>
#include <mutex>
#include <string>

namespace {
// Never destroyed: an engine thread can still retire its environment (RetireEnvironment) while
// the process exits and runs static destructors.
std::mutex& mutex = *new std::mutex();
std::string& generation = *new std::string();
std::array<char, 65> secret{};
bool available = false;
void Wipe() {
  volatile char* bytes = secret.data();
  for (size_t i = 0; i < secret.size(); ++i) bytes[i] = 0;
  available = false;
}
bool Hex(char value) {
  return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f');
}
void RetireEnvironment(void* value) {
  auto* run = static_cast<std::string*>(value);
  dsh_ios_phone_clear(run->c_str());
  delete run;
}
napi_value Consume(napi_env env, napi_callback_info info) {
  napi_value argument;
  size_t count = 1, size = 0;
  std::array<char, 37> run{};
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok || count != 1 ||
      napi_get_value_string_utf8(env, argument, nullptr, 0, &size) != napi_ok || size != 36 ||
      napi_get_value_string_utf8(env, argument, run.data(), run.size(), &size) != napi_ok) {
    napi_throw_error(env, "ERR_IOS_PHONE_GENERATION", "Invalid phone generation"); return nullptr;
  }
  std::lock_guard<std::mutex> lock(mutex);
  if (!available || generation != run.data()) {
    napi_throw_error(env, "ERR_IOS_PHONE_RETIRED", "Phone bootstrap absent, consumed or retired"); return nullptr;
  }
  napi_value token;
  if (napi_create_string_utf8(env, secret.data(), 64, &token) != napi_ok) return nullptr;
  auto* owner = new std::string(generation);
  if (napi_add_env_cleanup_hook(env, RetireEnvironment, owner) != napi_ok) { delete owner; return nullptr; }
  Wipe(); // one-shot native copy; V8/Swift keep only their in-memory copies
  return token;
}
napi_value Initialize(napi_env env, napi_value exports) {
  napi_value consume;
  if (napi_create_function(env, "consume", NAPI_AUTO_LENGTH, Consume, nullptr, &consume) != napi_ok ||
      napi_set_named_property(env, exports, "consume", consume) != napi_ok) return nullptr;
  return exports;
}
napi_module module = {NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
  "runtime/ios/host/phone_binding.cc", Initialize, "dsh_ios_phone", nullptr, {nullptr, nullptr, nullptr, nullptr}};
} // namespace

extern "C" __attribute__((visibility("default")))
int dsh_ios_phone_arm(const char* run_id, const char* token) {
  if (run_id == nullptr || token == nullptr || strnlen(run_id, 37) != 36 || strnlen(token, 65) != 64) return 1;
  for (size_t i = 0; i < 36; ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) { if (run_id[i] != '-') return 1; }
    else if (!Hex(run_id[i])) return 1;
  }
  for (size_t i = 0; i < 64; ++i) if (!Hex(token[i])) return 1;
  std::lock_guard<std::mutex> lock(mutex);
  if (!generation.empty()) return 1;
  generation = run_id;
  std::memcpy(secret.data(), token, 64);
  available = true;
  return 0;
}
extern "C" __attribute__((visibility("default")))
void dsh_ios_phone_clear(const char* run_id) {
  if (run_id == nullptr) return;
  std::lock_guard<std::mutex> lock(mutex);
  if (generation != run_id) return; // delayed old owner cannot clear a new generation
  Wipe(); generation.clear();
}
void RegisterPhoneBinding() { napi_module_register(&module); }
