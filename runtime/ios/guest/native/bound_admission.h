#ifndef DSH_IOS_BOUND_ADMISSION_H
#define DSH_IOS_BOUND_ADMISSION_H
#include "bound_file.h"
struct dsh_path_span {
  const char *bytes;
  size_t length;
};
// Protected paths come from the trusted App, never from the guest/model
// request. On success owns its root FD; all temporary descriptors are closed on
// failure. Error output is errno only, never path or secret-bearing
// configuration text.
dsh_root *dsh_admit_workspace(struct dsh_path_span requested,
                              const struct dsh_path_span *protected_paths,
                              size_t protected_count, bool readonly);
#endif
