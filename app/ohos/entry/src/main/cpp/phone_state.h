#pragma once
#include "lifecycle_state.h"
#include <deque>
#include <optional>
#include <string>
#include <utility>

namespace dsh {
struct PhoneScope { std::string engine_id; uint64_t generation = 0; };
struct PhoneRequest {
  PhoneScope scope;
  std::string request_id, nonce, tool, json;
  int64_t deadline = 0;
};
struct PhoneCheck { bool pending = false, foreground = false; int64_t now = -1, deadline = 0; };
struct PhoneSnapshot {
  bool available = false, foreground = false;
  std::string engine_id, owner_hash;
  uint64_t generation = 0;
  int64_t now = -1;
};
// Only Ark can Attach/Inspect/Consume/Finish. The Node C ABI exposes the other
// methods. Every operation locks lifecycle -> phone; never the reverse.
class PhoneState {
 public:
  explicit PhoneState(LifecycleState& lifecycle) : lifecycle_(lifecycle) {}
  bool Bind(const std::string& id) {
    return Access([&](const auto& life) {
      if (!life.engine_generation || !Safe(id, 128)) return false;
      if (bound_engine_ != life.engine_generation) {
        bound_engine_ = life.engine_generation; engine_id_.clear(); Disable();
      }
      if (!engine_id_.empty()) return engine_id_ == id;
      engine_id_ = id; return true;
    });
  }
  uint64_t Attach(const std::string& hash, uint64_t engine, uint64_t owner) {
    return Access([&](const auto& life) -> uint64_t {
      if (!life.available || !life.foreground || engine != life.engine_generation ||
          owner != life.owner_generation || bound_engine_ != engine || engine_id_.empty() || !Hex(hash) || generation_ >= 9007199254740991ULL) return 0;
      // No caller-controlled generation, and no owner restoration after retirement.
      Disable(); owner_ = owner; owner_hash_ = hash; enabled_ = true; return ++generation_;
    });
  }
  bool Retire(uint64_t generation) {
    return Access([&](const auto&) { if (generation != generation_ || !enabled_) return false; Disable(); return true; });
  }
  PhoneSnapshot Snapshot() {
    return Access([&](const auto& life) { return PhoneSnapshot{Current(life), !!life.foreground,
      engine_id_, owner_hash_, generation_, life.now_ms}; });
  }
  bool Claim(const PhoneRequest& request) {
    return Access([&](const auto& life) {
      if (!Admitted(life, request) || slot_ || !Valid(request) || Seen(request)) return false;
      const int64_t budget = request.tool == "mcp__phone__handoff" ? 600000 : 30000;
      if (request.deadline - life.now_ms > budget) return false;
      slot_ = Entry{request, false, false, {}}; return true;
    });
  }
  std::optional<PhoneRequest> Inspect(const PhoneRequest& key) {
    return Access([&](const auto& life) -> std::optional<PhoneRequest> {
      if (!slot_ || !Match(slot_->request, key) || slot_->consumed || slot_->revoked ||
          !Admitted(life, slot_->request)) return std::nullopt;
      return slot_->request;
    });
  }
  PhoneCheck Check(const PhoneRequest& key) {
    return Access([&](const auto& life) {
      const bool match = slot_ && Match(slot_->request, key);
      const auto deadline = match ? slot_->request.deadline : 0;
      return PhoneCheck{match && Current(life) && !slot_->revoked && !slot_->consumed &&
        life.now_ms >= 0 && life.now_ms < deadline, !!life.foreground, life.now_ms, deadline};
    });
  }
  bool Consume(const PhoneRequest& key) {
    return Access([&](const auto& life) {
      if (!slot_ || !Match(slot_->request, key) || slot_->consumed || slot_->revoked ||
          !Admitted(life, slot_->request)) return false;
      slot_->consumed = true; return true;
    });
  }
  // -1 unknown; 0 definitely never consumed; 1 definitely consumed. Finished
  // receipts retain the consumed bit so a lost HTTP result cannot become "none".
  int Revoke(const PhoneRequest& key) {
    return Access([&](const auto&) {
      if (slot_ && Match(slot_->request, key)) {
        const bool consumed = slot_->consumed; slot_->revoked = true;
        if (!consumed) Archive();
        return consumed ? 1 : 0;
      }
      for (const auto& row : recent_) if (Match(row.request, key)) return row.consumed ? 1 : 0;
      return -1;
    });
  }
  bool Finish(const PhoneRequest& key, const std::string& result) {
    return Access([&](const auto&) {
      if (!slot_ || !Match(slot_->request, key) || result.empty() || result.size() > 16384) return false;
      // An unconsumed action may finish a permission/validation failure. Ark
      // validates the result's dispatched field against this stored state.
      slot_->result = result; Archive(); return true;
    });
  }
  std::optional<bool> Consumed(const PhoneRequest& key) {
    return Access([&](const auto&) -> std::optional<bool> {
      if (slot_ && Match(slot_->request, key)) return slot_->consumed;
      for (const auto& row : recent_) if (Match(row.request, key)) return row.consumed;
      return std::nullopt;
    });
  }
  bool Complete(const PhoneRequest& key, const std::string& result) {
    return Access([&](const auto&) {
      for (const auto& row : recent_) if (Match(row.request, key))
        return !row.result.empty() && row.result == result;
      return false;
    });
  }
 private:
  struct Entry { PhoneRequest request; bool consumed, revoked; std::string result; };
  template<typename F> auto Access(F&& fn) -> decltype(fn(std::declval<const DshHostLifecycleSnapshotV1&>())) {
    return lifecycle_.WithSnapshot([&](const DshHostLifecycleSnapshotV1& life) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (enabled_ && (life.engine_generation != bound_engine_ || life.owner_generation != owner_ || !life.available)) Disable();
      return fn(life);
    });
  }
  bool Current(const DshHostLifecycleSnapshotV1& life) const {
    return enabled_ && life.available && life.engine_generation == bound_engine_ && life.owner_generation == owner_;
  }
  bool Admitted(const DshHostLifecycleSnapshotV1& life, const PhoneRequest& r) const {
    return Current(life) && life.foreground && r.scope.engine_id == engine_id_ && r.scope.generation == generation_ &&
      life.now_ms >= 0 && life.now_ms < r.deadline;
  }
  static bool Safe(const std::string& s, size_t max) { return !s.empty() && s.size() <= max && s.find('\0') == std::string::npos; }
  static bool Hex(const std::string& s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
  static bool Valid(const PhoneRequest& r) {
    const bool known = r.tool == "mcp__phone__open" || r.tool == "mcp__phone__intent" ||
      r.tool == "mcp__phone__notify" || r.tool == "mcp__phone__clipboard" || r.tool == "mcp__phone__handoff";
    return known && Safe(r.request_id, 64) && Safe(r.nonce, 64) && Safe(r.tool, 64) &&
      Safe(r.json, 4 * 1024 * 1024) && r.deadline <= 9007199254740991LL;
  }
  static bool Match(const PhoneRequest& a, const PhoneRequest& b) {
    return a.scope.engine_id == b.scope.engine_id && a.scope.generation == b.scope.generation &&
      a.request_id == b.request_id && a.nonce == b.nonce;
  }
  bool Seen(const PhoneRequest& r) const {
    for (const auto& row : recent_) if (row.request.scope.engine_id == r.scope.engine_id &&
      row.request.scope.generation == r.scope.generation && row.request.request_id == r.request_id) return true;
    return false;
  }
  void Archive() {
    // Receipts need no original tool arguments, only identity/result/consumed.
    std::string().swap(slot_->request.json); recent_.push_back(std::move(*slot_)); slot_.reset();
    if (recent_.size() > 64) recent_.pop_front();
  }
  void Disable() {
    enabled_ = false; owner_hash_.clear();
    if (slot_) { slot_->revoked = true; if (!slot_->consumed) Archive(); }
  }
  LifecycleState& lifecycle_;
  std::mutex mutex_;
  uint64_t bound_engine_ = 0, owner_ = 0, generation_ = 0;
  std::string engine_id_, owner_hash_;
  bool enabled_ = false;
  std::optional<Entry> slot_;
  std::deque<Entry> recent_;
};
} // namespace dsh
