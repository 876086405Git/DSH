// M6-5 experiment only. This file is never part of the product host.
// The product callback below is included unchanged from the exact reviewed tree.
#include "publication_binding.cc"

#include <atomic>
#include <cstring>

namespace {
std::atomic<uint32_t> next_serial{0};

napi_value ExperimentalLinkedInitialize(napi_env env, napi_value exports) {
  napi_value serial;
  if (napi_create_uint32(env, next_serial.fetch_add(1) + 1, &serial) != napi_ok ||
      napi_set_named_property(env, exports, "initializationSerial", serial) != napi_ok) {
    return nullptr;
  }
  napi_value label;
  if (napi_create_string_utf8(env, "public-AddLinkedBinding", NAPI_AUTO_LENGTH, &label) != napi_ok ||
      napi_set_named_property(env, exports, "registration", label) != napi_ok) {
    return nullptr;
  }
  return exports;
}

napi_value RegisterModern(napi_env env, napi_callback_info info) {
  size_t count = 1;
  napi_value argument;
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok || count != 1) {
    napi_throw_type_error(env, "ERR_M6_ARGUMENT", "A fixed experiment binding name is required");
    return nullptr;
  }
  char input[80];
  size_t length = 0;
  if (napi_get_value_string_utf8(env, argument, input, sizeof(input), &length) != napi_ok ||
      length == 0 || length >= sizeof(input) - 1) {
    napi_throw_type_error(env, "ERR_M6_ARGUMENT", "Invalid experiment binding name");
    return nullptr;
  }
  const char* name = nullptr;
  for (const char* allowed : {"dsh_m6_main", "dsh_m6_late", "dsh_m6_worker", "dsh_ohos_publication"}) {
    if (std::strcmp(input, allowed) == 0) name = allowed;
  }
  if (name == nullptr) {
    napi_throw_type_error(env, "ERR_M6_ARGUMENT", "Unknown experiment binding name");
    return nullptr;
  }
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  node::Environment* current = isolate == nullptr ? nullptr :
      node::GetCurrentEnvironment(isolate->GetCurrentContext());
  if (current == nullptr) {
    napi_throw_error(env, "ERR_M6_NO_ENVIRONMENT", "No current Node environment");
    return nullptr;
  }
  // Names above are static literals and callbacks remain loaded for env lifetime.
  // No deprecated registration path is called by this experiment's modern API.
  node::AddLinkedBinding(current, name,
      std::strcmp(name, "dsh_ohos_publication") == 0 ? Initialize : ExperimentalLinkedInitialize,
      8);
  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

napi_module late_legacy = {
  NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
  "runtime/tests/ohos/linked-binding-evaluation/registration.cc",
  ExperimentalLinkedInitialize, "dsh_m6_legacy_late", nullptr,
  {nullptr, nullptr, nullptr, nullptr}
};

napi_value RegisterLegacyLate(napi_env env, napi_callback_info) {
  // Deliberate old-API counterexample, used only in an isolated test process.
  napi_module_register(&late_legacy);
  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

napi_value Bootstrap(napi_env env, napi_value exports) {
  napi_property_descriptor methods[] = {
    {"registerModern", nullptr, RegisterModern, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"registerLegacyLate", nullptr, RegisterLegacyLate, nullptr, nullptr, nullptr, napi_default, nullptr}
  };
  if (napi_define_properties(env, exports, 2, methods) != napi_ok) return nullptr;
  return exports;
}
}  // namespace

NAPI_MODULE(dsh_m6_registration_experiment, Bootstrap)
