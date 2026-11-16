#pragma once
#include <cstdint>
#include <limits>
#include <mutex>
#include <time.h>
#include "../../../../../../runtime/ohos/host/lifecycle_snapshot.h"

namespace dsh {
// BOOTTIME includes suspend. Failure never falls back to wall/active/process time.
inline int64_t LifecycleBootTimeMs() noexcept {
  timespec value{};
  if (clock_gettime(CLOCK_BOOTTIME, &value) != 0 || value.tv_sec < 0 ||
      value.tv_nsec < 0 || value.tv_nsec >= 1000000000 ||
      value.tv_sec > (9007199254740991LL - 999) / 1000) return -1;
  return value.tv_sec * 1000LL + value.tv_nsec / 1000000;
}
class LifecycleState {
 public:
  enum Phase : uint32_t { Idle, Requesting, Granted, Draining, Released, Expired, Unavailable, Continuous };
  using Clock = int64_t (*)() noexcept;
  explicit LifecycleState(Clock clock = LifecycleBootTimeMs) : clock_(clock) {}
  void BeginEngine() {
    std::lock_guard<std::mutex> lock(mutex_);
    ++engine_; active_ = true; retired_ = true; foreground_ = false;
    pending_ = 0; phase_ = Idle; deadline_ = drain_ = 0; ++revision_;
  }
  uint64_t BeginOwner(bool foreground) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!active_) return 0;
    ++owner_; ++revision_; retired_ = false; foreground_ = foreground;
    pending_ = 0; phase_ = Idle; deadline_ = drain_ = 0;
    return owner_;
  }
  bool Foreground(uint64_t owner, bool foreground) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Current(owner)) return false;
    if (foreground_ == foreground) return true;
    foreground_ = foreground; pending_ = 0; phase_ = Released;
    deadline_ = drain_ = 0; ++revision_; return true;
  }
  uint64_t BeginGrant(uint64_t owner) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Current(owner) || foreground_ || pending_ || (phase_ != Idle && phase_ != Released)) return 0;
    const auto now = Now(); if (now < 0) return 0;
    pending_ = ++grant_; requested_at_ = now; deadline_ = drain_ = 0;
    phase_ = Requesting; ++revision_; return pending_;
  }
  bool Activate(uint64_t owner, uint64_t pending, int64_t duration) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Current(owner) || foreground_ || pending == 0 || pending_ != pending ||
        phase_ != Requesting || duration <= 0 || duration > 180000) return false;
    // Consume once, even when too little time remains. Duplicate activation cannot renew it.
    pending_ = 0;
    const auto now = Now(); if (now < 0) return false;
    if (requested_at_ > 9007199254740991LL - duration) { clock_failed_ = true; return false; }
    deadline_ = requested_at_ + duration; drain_ = deadline_ > 6000 ? deadline_ - 6000 : 0;
    phase_ = now < drain_ ? Granted : Draining; ++revision_;
    return phase_ == Granted;
  }
  bool Drain(uint64_t owner, uint64_t grant) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Current(owner) || grant_ != grant || grant == 0) return false;
    pending_ = 0; phase_ = Draining; ++revision_; return true;
  }
  bool Release(uint64_t owner, uint64_t grant) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Current(owner) || grant_ != grant || grant == 0) return false;
    pending_ = 0; phase_ = Released; deadline_ = drain_ = 0; ++revision_; return true;
  }
  bool SetContinuous(uint64_t owner, bool active) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Current(owner) || (active && foreground_)) return false;
    pending_ = 0; deadline_ = drain_ = 0;
    phase_ = active ? Continuous : Released; ++revision_; return true;
  }
  bool Retire(uint64_t owner) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Current(owner)) return false;
    retired_ = true; foreground_ = false; pending_ = 0; phase_ = Released;
    deadline_ = drain_ = 0; ++revision_; return true;
  }
  void Stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    active_ = false; retired_ = true; foreground_ = false; pending_ = 0;
    phase_ = Released; deadline_ = drain_ = 0; ++revision_;
  }
  int Snapshot(DshHostLifecycleSnapshotV1* output, uint32_t size) {
    if (!output || size != sizeof(*output)) return -1;
    std::lock_guard<std::mutex> lock(mutex_);
    return SnapshotLocked(output);
  }
  template<typename F> auto WithSnapshot(F&& fn) {
    std::lock_guard<std::mutex> lock(mutex_);
    DshHostLifecycleSnapshotV1 snapshot{};
    SnapshotLocked(&snapshot);
    return fn(snapshot);
  }
 private:
  int SnapshotLocked(DshHostLifecycleSnapshotV1* output) {
    const auto now = Now();
    auto phase = phase_;
    if (now < 0) phase = Unavailable;
    else if ((phase == Granted || phase == Draining) && deadline_ > 0 && now >= deadline_) phase = Expired;
    else if (phase == Granted && now >= drain_) phase = Draining;
    *output = {sizeof(*output), 1, engine_, owner_, revision_, grant_, now,
      deadline_, drain_, static_cast<uint32_t>(Current(owner_) && now >= 0),
      static_cast<uint32_t>(foreground_), phase, static_cast<uint32_t>(clock_failed_)};
    return 0;
  }
  bool Current(uint64_t owner) const { return active_ && !retired_ && owner != 0 && owner == owner_; }
  int64_t Now() {
    const auto now = clock_();
    if (now < 0 || now > 9007199254740991LL || (last_now_ >= 0 && now < last_now_)) clock_failed_ = true;
    if (clock_failed_) return -1;
    last_now_ = now; return now;
  }
  std::mutex mutex_;
  Clock clock_;
  uint64_t engine_ = 0, owner_ = 0, revision_ = 0, grant_ = 0, pending_ = 0;
  int64_t requested_at_ = 0, deadline_ = 0, drain_ = 0, last_now_ = -1;
  Phase phase_ = Idle;
  bool active_ = false, retired_ = true, foreground_ = false, clock_failed_ = false;
};
}  // namespace dsh
