/* Compile with -fsyntax-only. This fixture never links or starts an owner. */
#include "dsh_phone_self_runner.h"

int main(void) {
  uint64_t (*xctest_bytes)(const uint8_t *, size_t, const uint8_t *, size_t,
      dsh_phone_xctest_callback) = dsh_phone_xctest_start_bytes;
  int32_t (*core_bytes)(const uint8_t *, size_t, const uint8_t *, size_t,
      dsh_phone_core_event_callback, uint64_t *) = dsh_phone_core_start_bytes;
  uint64_t (*legacy_xctest)(const char *, dsh_phone_xctest_callback) = dsh_phone_xctest_start;
  int32_t (*legacy_core)(const uint8_t *, size_t,
      dsh_phone_core_event_callback, uint64_t *) = dsh_phone_core_start;
  (void)xctest_bytes;
  (void)core_bytes;
  (void)legacy_xctest;
  (void)legacy_core;
  return 0;
}
