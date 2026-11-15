// Explicit Linux-only test provider. No environment variable can change it.
// Compile-time mutations are used only by publication-system-build.py.
#include <deviceinfo.h>
#include <string>

#ifndef DSH_TEST_BUILD_FIELD
#define DSH_TEST_BUILD_FIELD -1
#endif
#ifndef DSH_TEST_BUILD_CASE
#define DSH_TEST_BUILD_CASE 0
#endif

namespace {
const char* Value(int field, const char* normal) {
  if (field != DSH_TEST_BUILD_FIELD) return normal;
  if (DSH_TEST_BUILD_CASE == 1) return nullptr;
  if (DSH_TEST_BUILD_CASE == 2) return "";
  static const std::string oversized(1025, 'x');
  static const std::string boundary(1024, 'x');
  if (DSH_TEST_BUILD_CASE == 3) return oversized.c_str();
  if (DSH_TEST_BUILD_CASE == 4) return boundary.c_str();
  return normal;
}
}  // namespace

extern "C" const char* OH_GetOSFullName(void) {
  return Value(0, "DSH-Linux-Test-OS-1");
}
extern "C" const char* OH_GetDisplayVersion(void) {
  return Value(1, "DSH-Linux-Test-Display-1");
}
extern "C" const char* OH_GetIncrementalVersion(void) {
  return Value(2, "DSH-Linux-Test-Incremental-1");
}
extern "C" const char* OH_GetSecurityPatchTag(void) {
  return Value(3, "DSH-Linux-Test-Security-1");
}
