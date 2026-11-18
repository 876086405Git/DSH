#pragma once
#include <stdint.h>
// Trusted native ABI. No JavaScript setter or configurable code pointer.
// A successful acquisition pins one engine run's clock until release(context).
struct dsh_activity_clock_v1 {
  uint32_t size, version;
  void *context;
  double (*now_ms)(void *);
  void (*release)(void *);
};
typedef int (*dsh_activity_clock_acquire_v1)(struct dsh_activity_clock_v1 *);
