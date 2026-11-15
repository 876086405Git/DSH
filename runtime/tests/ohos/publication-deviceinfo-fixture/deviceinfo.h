// Linux test declarations for four public OpenHarmony C APIs (API 10+).
// This directory is never an include directory of the product CMake target.
#ifndef DSH_TEST_DEVICEINFO_H
#define DSH_TEST_DEVICEINFO_H
#ifdef __cplusplus
extern "C" {
#endif
const char* OH_GetOSFullName(void);
const char* OH_GetDisplayVersion(void);
const char* OH_GetIncrementalVersion(void);
const char* OH_GetSecurityPatchTag(void);
#ifdef __cplusplus
}
#endif
#endif
