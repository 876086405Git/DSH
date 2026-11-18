#pragma once

#include <chrono>
#include <cstdint>
#include <mutex>

namespace dsh_ios {

// An independent scheduling-gap heuristic, not an OS suspension counter.
// The existing host parent thread supplies Tick; JS reads never certify health.
class ActivityClock {
 public:
  static constexpr auto kPeriod = std::chrono::milliseconds(250);
  static constexpr double kGapMs = 2000;
  static constexpr double kConfirmMs = 1500;

  double Now() {
    std::lock_guard<std::mutex> lock(mutex_);
    Sample(Raw(), false);
    return active_;
  }

  void Tick() {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto now = Raw();
    const bool regular = native_seen_ && now > native_last_ && now - native_last_ <= kGapMs;
    native_seen_ = true;
    native_last_ = now;
    ++native_sequence_;
    Sample(now, true);
    if (state_ == State::warming || (state_ == State::pending && native_sequence_ > pending_sequence_)) {
      regular_ticks_ = regular ? regular_ticks_ + 1 : 0;
      if (regular_ticks_ >= 2) state_ = State::healthy;
    }
  }

  // Old binding instances keep this clock, never a later engine's epoch. Retire
  // preserves the adjusted anchor and subsequently charges ordinary elapsed time.
  void Retire() {
    std::lock_guard<std::mutex> lock(mutex_);
    state_ = State::retired;
    Sample(Raw(), false);
  }

 private:
  using Steady = std::chrono::steady_clock;
  enum class State { warming, healthy, pending, degraded, retired };
  const Steady::time_point origin_ = Steady::now();
  std::mutex mutex_;
  State state_ = State::warming;
  double last_ = 0, active_ = 0, native_last_ = 0, confirmation_end_ = 0;
  std::uint64_t native_sequence_ = 0, pending_sequence_ = 0;
  unsigned regular_ticks_ = 0;
  bool native_seen_ = false;

  double Raw() const {
    return std::chrono::duration<double, std::milli>(Steady::now() - origin_).count();
  }

  void Sample(double now, bool tick) {
    const double elapsed = now - last_;
    if (state_ == State::pending && now >= confirmation_end_) state_ = State::degraded;
    if (state_ == State::healthy && elapsed > kGapMs) {
      // One observed gap is provisionally excluded (q=0), then every interval
      // is charged until fresh independent ticks confirm health. No read can
      // renew this permission, and a failed confirmation is permanent this run.
      state_ = State::pending;
      pending_sequence_ = native_sequence_;
      confirmation_end_ = now + kConfirmMs;
      regular_ticks_ = 0;
    } else {
      active_ += elapsed;
      if (state_ == State::healthy && !tick && native_seen_ && now - native_last_ > kGapMs) {
        state_ = State::degraded;
      }
    }
    last_ = now;
  }
};

}  // namespace dsh_ios
