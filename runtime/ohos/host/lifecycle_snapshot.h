#pragma once
#include <stdint.h>
// C-only shared contract. No JS/N-API values, pointers or allocator ownership cross DSOs.
struct DshHostLifecycleSnapshotV1 {
  uint32_t size;
  uint32_t version;
  uint64_t engine_generation;
  uint64_t owner_generation;
  uint64_t revision;
  uint64_t grant_generation;
  int64_t now_ms;
  int64_t deadline_ms;
  int64_t drain_at_ms;
  uint32_t available;
  uint32_t foreground;
  uint32_t phase;
  uint32_t clock_failed;
};
using DshReadHostLifecycleV1 = int (*)(DshHostLifecycleSnapshotV1*, uint32_t) noexcept;
