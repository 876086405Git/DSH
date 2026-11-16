#ifndef DSH_IMAGE_NDK_HOST_COMPAT_H
#define DSH_IMAGE_NDK_HOST_COMPAT_H
#ifndef DSH_IMAGE_NDK_HOST_FIXTURE
#error "This shim is exclusively for the selected host SDK fixture"
#endif
#if defined(__OHOS__) || defined(__ANDROID__)
#error "Host annotation shim must never enter an OH/Android product build"
#endif
/* Keep SDK declarations unchanged. GCC cannot check OH API availability;
 * erase only this annotation, never a function type, enum, or declaration. */
#define __availability__(...)
#endif
