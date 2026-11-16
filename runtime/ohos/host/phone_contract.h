#pragma once
#include <stdint.h>
// Borrowed input buffers are valid only for this synchronous call. No allocation
// or C++ object ownership crosses the DSO boundary.
struct DshPhoneInputV1 {
  uint32_t size, version, operation, reserved;
  uint64_t generation;
  int64_t deadline_ms;
  char engine_id[129], request_id[65], nonce[65], tool[65];
  const char* data;
  uint32_t data_size;
};
struct DshPhoneSnapshotV1 {
  uint32_t size, version, available, foreground;
  uint64_t generation;
  int64_t now_ms;
  char engine_id[129], owner_hash[65];
};
enum DshPhoneOperationV1 : uint32_t { DshPhoneBind = 1, DshPhoneSnapshot = 2,
  DshPhoneClaim = 3, DshPhoneRevoke = 4, DshPhoneComplete = 5 };
// Boolean operations return 0/1. Revoke: 0 never consumed, 1 consumed, 2 unknown.
// Snapshot returns 1 with a complete POD. Negative means malformed/unavailable.
using DshHostPhoneV1 = int (*)(const DshPhoneInputV1*, DshPhoneSnapshotV1*) noexcept;
