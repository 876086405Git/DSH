#ifndef DSH_IMAGE_NDK_HOST_OPAQUE_NAPI_SHIM_H
#define DSH_IMAGE_NDK_HOST_OPAQUE_NAPI_SHIM_H
#ifndef DSH_IMAGE_NDK_HOST_FIXTURE
#error "Host-only opaque types, not Node or Ark N-API"
#endif
typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;
#endif
