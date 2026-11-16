#include "../../../app/ohos/entry/src/main/cpp/lifecycle_state.h"
#include <deque>
#include <optional>
#include <string>
#include <utility>
// White-box resource assertion only; do not add a product inspection API.
#define private public
#include "../../../app/ohos/entry/src/main/cpp/phone_state.h"
#undef private
#include <cassert>
#include <iostream>
static int64_t now = 1000;
static int64_t Clock() noexcept { return now; }
int main() {
  dsh::LifecycleState life(Clock); dsh::PhoneState phone(life);
  assert(!phone.Snapshot().available); assert(!phone.Bind("boot"));
  life.BeginEngine(); const auto owner = life.BeginOwner(true);
  assert(phone.Bind("boot")); assert(phone.Bind("boot")); assert(!phone.Bind("forged"));
  const auto generation = phone.Attach(std::string(64,'a'), 1, owner); assert(generation);
  dsh::PhoneRequest r{{"boot",generation},"request-1","nonce-1","mcp__phone__clipboard","{\"set\":\"original\"}",31000};
  r.json = std::string(1024 * 1024, 'x');
  assert(phone.Claim(r)); assert(!phone.Claim(r)); assert(!phone.Complete(r,"forged-success"));
  auto read = phone.Inspect(r); assert(read && read->json==r.json);
  assert(phone.Revoke(r)==0); assert(phone.recent_.back().request.json.capacity() < 1024); assert(!phone.Consume(r)); assert(!phone.Claim(r));
  r.request_id="request-2"; assert(phone.Claim(r));
  life.Foreground(owner,false); assert(!phone.Consume(r)); life.Foreground(owner,true);
  assert(phone.Consume(r)); assert(!phone.Consume(r)); assert(phone.Revoke(r)==1);
  auto next=r; next.request_id="request-3"; assert(!phone.Claim(next));
  assert(phone.Finish(r,"trusted-unknown")); assert(phone.Revoke(r)==1); // Lost HTTP receipt, still dispatched.
  assert(!phone.Complete(r,"forged-success")); assert(phone.Complete(r,"trusted-unknown"));
  assert(phone.Claim(next)); now=31000; assert(!phone.Consume(next)); assert(phone.Revoke(next)==0);
  now=32000; next.request_id="request-4";next.deadline=62000;assert(phone.Claim(next));assert(phone.Consume(next));
  assert(phone.Retire(generation)); assert(!phone.Snapshot().available);
  const auto replacement=phone.Attach(std::string(64,'b'),1,owner);assert(replacement>generation);
  auto fresh=next;fresh.scope.generation=replacement;fresh.request_id="request-new";
  assert(!phone.Claim(fresh)); // Retired consumed SDK still occupies slot.
  assert(phone.Finish(next,"old-settled"));assert(phone.Revoke(next)==1);assert(phone.Claim(fresh));
  auto wrong=fresh;wrong.nonce="forged";assert(!phone.Consume(wrong));assert(!phone.Finish(wrong,"x"));
  life.Retire(owner);assert(!phone.Consume(fresh));assert(!phone.Snapshot().available);
  const auto owner2=life.BeginOwner(true);const auto g3=phone.Attach(std::string(64,'c'),1,owner2);assert(g3);
  fresh.scope.generation=g3;fresh.request_id="rollback";assert(phone.Claim(fresh));now=1;
  assert(!phone.Consume(fresh));assert(!phone.Snapshot().available);
  std::cout << "phone native state assertions passed\n";
}
