#pragma once

#include <node.h>
#include <node_api.h>
#include <memory>
#include <mutex>

#include "activity_clock.h"
#include "activity_clock_api.h"
#include <cerrno>
#include <new>

namespace dsh_ios {
namespace activity_binding {
inline std::mutex mutex;
inline std::shared_ptr<ActivityClock> current;

inline void Release(void* value) { delete static_cast<std::shared_ptr<ActivityClock>*>(value); }

inline napi_value Now(napi_env env, napi_callback_info info) {
  void* data = nullptr;
  if (napi_get_cb_info(env, info, nullptr, nullptr, nullptr, &data) != napi_ok) return nullptr;
  const double now = (*static_cast<std::shared_ptr<ActivityClock>*>(data))->Now();
  napi_value result;
  if (napi_create_double(env, now, &result) != napi_ok) return nullptr;
  return result;
}

inline napi_value Initialize(napi_env env, napi_value exports) {
  std::shared_ptr<ActivityClock> clock;
  { std::lock_guard<std::mutex> lock(mutex); clock = current; }
  if (!clock) {
    napi_throw_error(env, "ERR_IOS_ACTIVITY_CLOCK", "No active engine clock");
    return nullptr;
  }
  auto* owner = new std::shared_ptr<ActivityClock>(std::move(clock));
  if (napi_add_env_cleanup_hook(env, Release, owner) != napi_ok) { delete owner; return nullptr; }
  napi_value now;
  if (napi_create_function(env, "now", NAPI_AUTO_LENGTH, Now, owner, &now) != napi_ok ||
      napi_set_named_property(env, exports, "now", now) != napi_ok) return nullptr;
  return exports;
}

inline napi_module module = {NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
  "runtime/ios/host/activity_clock_binding.h", Initialize, "dsh_ios_activity_clock", nullptr,
  {nullptr, nullptr, nullptr, nullptr}};
}  // namespace activity_binding

inline void RegisterActivityClockBinding() { napi_module_register(&activity_binding::module); }

class RunActivityClock {
 public:
  const std::shared_ptr<ActivityClock> clock = std::make_shared<ActivityClock>();
  RunActivityClock() {
    std::lock_guard<std::mutex> lock(activity_binding::mutex);
    activity_binding::current = clock;
  }
  ~RunActivityClock() {
    clock->Retire();
    std::lock_guard<std::mutex> lock(activity_binding::mutex);
    if (activity_binding::current == clock) activity_binding::current.reset();
  }
};
}  // namespace dsh_ios

// No Node callback is involved: the native coordinator may read this after Env
// teardown. Retire preserves the epoch and charges ordinary elapsed time.
extern "C" __attribute__((visibility("default")))
int dsh_host_activity_clock_acquire_v1(struct dsh_activity_clock_v1 *out) {
  if (!out || out->size != sizeof(*out) || out->version != 1) return EINVAL;
  std::shared_ptr<dsh_ios::ActivityClock> clock;
  { std::lock_guard<std::mutex> lock(dsh_ios::activity_binding::mutex);
    clock = dsh_ios::activity_binding::current; }
  if (!clock) return ENOENT;
  auto *owner = new (std::nothrow) std::shared_ptr<dsh_ios::ActivityClock>(std::move(clock));
  if (!owner) return ENOMEM;
  out->context = owner;
  out->now_ms = [](void *p) { return (*static_cast<std::shared_ptr<dsh_ios::ActivityClock> *>(p))->Now(); };
  out->release = [](void *p) { delete static_cast<std::shared_ptr<dsh_ios::ActivityClock> *>(p); };
  return 0;
}
