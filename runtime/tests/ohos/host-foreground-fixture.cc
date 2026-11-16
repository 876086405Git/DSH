// TEST ONLY, never in a HAP. Stands in for libdsh_host.so in a Linux CLI engine, which
// has no Ark module around it: one engine, one owner, always in the foreground. The
// lifecycle and phone state classes are the product's. Admission itself is tested in
// background-native-contract and phone-native-state; this only lets a full round start.
#include "lifecycle_state.h"
#include "phone_contract.h"
#include "phone_state.h"
#include <cstring>

namespace {
struct Foreground {
  dsh::LifecycleState lifecycle;
  dsh::PhoneState phone{lifecycle};
  Foreground() { lifecycle.BeginEngine(); lifecycle.BeginOwner(true); }
};
Foreground& State() { static Foreground state; return state; }
}  // namespace

extern "C" __attribute__((visibility("default")))
int dsh_host_lifecycle_snapshot_v1(DshHostLifecycleSnapshotV1* output, uint32_t size) noexcept {
  return State().lifecycle.Snapshot(output, size);
}

extern "C" __attribute__((visibility("default")))
int dsh_host_phone_v1(const DshPhoneInputV1* in, DshPhoneSnapshotV1* out) noexcept {
  auto& phone = State().phone;
  if (in->operation == DshPhoneBind) return phone.Bind(in->engine_id) ? 1 : 0;
  if (in->operation != DshPhoneSnapshot || !out) return -1;
  const auto state = phone.Snapshot();
  *out = {}; out->size = sizeof(*out); out->version = 1;
  out->available = state.available; out->foreground = state.foreground;
  out->generation = state.generation; out->now_ms = state.now;
  memcpy(out->engine_id, state.engine_id.data(), state.engine_id.size());
  memcpy(out->owner_hash, state.owner_hash.data(), state.owner_hash.size());
  return 1;
}
