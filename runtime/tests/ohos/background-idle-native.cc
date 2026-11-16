// Host-test adapter only. The actual product LifecycleState is unchanged.
// Deterministic time replaces CLOCK_BOOTTIME; this is not an OH SDK build.
#include <node_api.h>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include "lifecycle_state.h"

namespace {
int64_t now_ms = 10000;
int64_t Clock() noexcept { return now_ms; }
std::unique_ptr<dsh::LifecycleState> state;
napi_value Fail(napi_env env, const char* message) {
  napi_throw_error(env, "ERR_BACKGROUND_TEST_ARGUMENT", message); return nullptr;
}
bool Number(napi_env env, napi_value value, double* out) {
  return napi_get_value_double(env, value, out) == napi_ok && std::isfinite(*out)
    && *out >= 0 && *out <= 9007199254740991.0 && std::floor(*out) == *out;
}
napi_value Num(napi_env env, double value) {
  napi_value out; if (napi_create_double(env, value, &out) != napi_ok) return nullptr; return out;
}
napi_value Reset(napi_env env, napi_callback_info info) {
  size_t count = 1; napi_value args[1]; double value;
  if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 1 || !Number(env, args[0], &value)) return Fail(env, "reset(now)");
  now_ms = static_cast<int64_t>(value); state = std::make_unique<dsh::LifecycleState>(Clock); state->BeginEngine();
  return Num(env, now_ms);
}
napi_value SetNow(napi_env env, napi_callback_info info) {
  size_t count = 1; napi_value args[1]; double value;
  if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 1 || !Number(env, args[0], &value)) return Fail(env, "setNow(now)");
  now_ms = static_cast<int64_t>(value); return Num(env, now_ms);
}
napi_value Snapshot(napi_env env, napi_callback_info) {
  if (!state) return Fail(env, "reset is required");
  DshHostLifecycleSnapshotV1 s{};
  if (state->Snapshot(&s, sizeof(s)) != 0) return Fail(env, "Snapshot failed");
  napi_value out; if (napi_create_object(env, &out) != napi_ok) return nullptr;
  const auto put = [&](const char* key, double value) { return napi_set_named_property(env, out, key, Num(env, value)) == napi_ok; };
  if (!put("version", s.version) || !put("engineGeneration", s.engine_generation) || !put("ownerGeneration", s.owner_generation)
      || !put("revision", s.revision) || !put("grantGeneration", s.grant_generation) || !put("nowMs", s.now_ms)
      || !put("deadlineMs", s.deadline_ms) || !put("drainAtMs", s.drain_at_ms) || !put("phase", s.phase)
      || !put("available", s.available) || !put("foreground", s.foreground) || !put("clockFailed", s.clock_failed)) return nullptr;
  return out;
}
napi_value Update(napi_env env, napi_callback_info info) {
  if (!state) return Fail(env, "reset is required");
  size_t count = 4; napi_value args[4]; double owner_number, grant_number, value_number; char operation[32]; size_t size = 0;
  if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 4
      || napi_get_value_string_utf8(env, args[0], operation, sizeof(operation), &size) != napi_ok || size >= sizeof(operation) - 1
      || !Number(env, args[1], &owner_number) || !Number(env, args[2], &grant_number) || !Number(env, args[3], &value_number)) return Fail(env, "update(operation,owner,grant,value)");
  const std::string op(operation, size); const auto owner = static_cast<uint64_t>(owner_number);
  const auto grant = static_cast<uint64_t>(grant_number); const auto value = static_cast<int64_t>(value_number); uint64_t answer = 0;
  // Same operation-to-product-method mapping as napi_host.cpp LifecycleUpdate.
  if (op == "owner" && value <= 1 && owner == 0 && grant == 0) answer = state->BeginOwner(value == 1);
  else if (op == "foreground" && value <= 1) answer = state->Foreground(owner, value == 1);
  else if (op == "continuous" && value <= 1) answer = state->SetContinuous(owner, value == 1);
  else if (op == "begin") answer = state->BeginGrant(owner);
  else if (op == "activate") answer = state->Activate(owner, grant, value);
  else if (op == "drain") answer = state->Drain(owner, grant);
  else if (op == "release") answer = state->Release(owner, grant);
  else if (op == "retire") answer = state->Retire(owner);
  else return Fail(env, "unknown operation");
  return Num(env, static_cast<double>(answer));
}
napi_value Init(napi_env env, napi_value exports) {
  const napi_property_descriptor methods[] = {
    {"reset", nullptr, Reset, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"setNow", nullptr, SetNow, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"lifecycleUpdate", nullptr, Update, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"lifecycleSnapshot", nullptr, Snapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  return napi_define_properties(env, exports, 4, methods) == napi_ok ? exports : nullptr;
}
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
