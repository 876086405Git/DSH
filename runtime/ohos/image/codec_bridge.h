#ifndef DSH_OHOS_IMAGE_CODEC_BRIDGE_H
#define DSH_OHOS_IMAGE_CODEC_BRIDGE_H

/* Private, same-build C boundary. No Node/Ark N-API, C++ object, or exception
 * crosses this header. An NDK translation unit supplies exactly one backend.
 * This is not a general image or file-system API. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DSH_IMAGE_CODEC_ABI 1u
#define DSH_IMAGE_ENCODE_CAP ((size_t)52428800u)

/* Owner-selected build policy for the later NDK getter helper (ADD28).
 * Default Destroy is a requested implementation choice, not proof of getter
 * ownership. No runtime environment-variable switch. That TU must publish
 * its actual selection in color_getter_policy AND build_id. The fake backend
 * does not call the getter and reports NOT_USED regardless of this macro. */
#ifndef DSH_IMAGE_DESTROY_COLORSPACE_GETTER
#define DSH_IMAGE_DESTROY_COLORSPACE_GETTER 1
#endif
#if DSH_IMAGE_DESTROY_COLORSPACE_GETTER != 0 && DSH_IMAGE_DESTROY_COLORSPACE_GETTER != 1
#error "DSH_IMAGE_DESTROY_COLORSPACE_GETTER must be 0 or 1"
#endif

typedef enum {
  DSH_IMAGE_OK = 0,
  DSH_IMAGE_UNAVAILABLE = 1,
  DSH_IMAGE_INVALID = 2,
  DSH_IMAGE_EDGE_LIMIT = 3,
  DSH_IMAGE_PIXEL_LIMIT = 4,
  DSH_IMAGE_TRANSFORM_FAILED = 5,
  DSH_IMAGE_ENCODE_FAILED = 6,
  DSH_IMAGE_CLEANUP_UNCONFIRMED = 7,
  DSH_IMAGE_INTERNAL = 8
} DshImageStatus;

typedef enum {
  DSH_IMAGE_CODEC_FORMAT_UNKNOWN = 0,
  DSH_IMAGE_CODEC_FORMAT_PNG = 1,
  DSH_IMAGE_CODEC_FORMAT_JPEG = 2,
  DSH_IMAGE_CODEC_FORMAT_WEBP = 3,
  DSH_IMAGE_CODEC_FORMAT_GIF = 4
} DshImageCodecFormat;

typedef enum {
  DSH_IMAGE_COLOR_UNKNOWN = 0,
  DSH_IMAGE_COLOR_SRGB = 1,
  DSH_IMAGE_COLOR_OTHER = 2
} DshImageColor;

typedef enum {
  DSH_IMAGE_GETTER_NOT_USED = 0,
  DSH_IMAGE_GETTER_DESTROY = 1,
  DSH_IMAGE_GETTER_BORROW = 2
} DshImageColorGetterPolicy;

/* Known bits describe evidence, not requested encoder options. An unset bit
 * becomes JS null, never false/zero. SOURCE / WORKING / ENCODED stay separate. */
enum {
  DSH_IMAGE_FACT_DIMENSIONS = 1u << 0,
  DSH_IMAGE_FACT_FORMAT = 1u << 1,
  DSH_IMAGE_FACT_FRAMES = 1u << 2,
  DSH_IMAGE_FACT_ORIENTATION = 1u << 3,
  DSH_IMAGE_FACT_ALPHA = 1u << 4,
  DSH_IMAGE_FACT_DEPTH = 1u << 5,
  DSH_IMAGE_FACT_COLOR = 1u << 6,
  DSH_IMAGE_FACT_METADATA = 1u << 7,
  DSH_IMAGE_FACT_ALLOCATION = 1u << 8
};

typedef struct {
  uint32_t struct_size;
  uint32_t known;
  uint32_t width;
  uint32_t height;
  uint32_t format;
  uint32_t frame_count;
  uint32_t orientation;
  uint32_t has_alpha;
  uint32_t bit_depth;
  uint32_t color_space;
  uint32_t retained_metadata;
  uint64_t allocation_bytes;
} DshImageFacts;

typedef struct {
  uint32_t struct_size;
  uint32_t max_side;
  uint64_t max_pixels;
} DshImageLimits;

typedef struct {
  uint32_t struct_size;
  uint32_t width;
  uint32_t height;
  uint32_t format;          /* JPEG or WebP only. */
  uint64_t soft_max_bytes;  /* Independent of the hard allocation cap. */
} DshImageTarget;

typedef struct {
  int32_t native_status;   /* Raw platform status, not a guessed diagnosis. */
  const char* stage;       /* Static, non-image text with process lifetime. */
} DshImageError;

typedef struct DshImageFrame DshImageFrame;

typedef struct {
  uint8_t* data;
  size_t size;
  size_t capacity;
  uint32_t format;
  uint32_t quality;
  DshImageFacts facts;    /* Actual encoded-output verification facts. */
} DshImageEncoded;

typedef struct {
  uint32_t abi;
  uint32_t struct_size;
  const char* build_id;   /* Static, <= 255 UTF-8 bytes, includes real options. */
  uint32_t fixture_only;
  uint32_t color_getter_policy;

  /* Worker-thread calls. Backends may be used concurrently for different
   * frames. Same-frame calls are serialized by the Node adapter. inspect
   * consumes input only during the call and releases all temporary resources
   * before returning. open must check limits before full decode and may retain the adapter-owned
   * immutable input until close confirms *frame == NULL. No input ownership
   * transfer, no JS calls, and no exceptions may escape any function. On open
   * failure, *frame may be non-NULL solely to retain cleanup ownership: it is
   * not encodable and still requires close. Only confirmed close permits the
   * adapter to release the input snapshot. */
  DshImageStatus (*inspect)(const uint8_t*, size_t,
                            DshImageFacts*, DshImageError*);
  DshImageStatus (*open)(const uint8_t*, size_t, const DshImageLimits*,
                       DshImageFrame**, DshImageFacts* source,
                       DshImageFacts* working, DshImageError*);
  /* Implements the agreed finite quality ladder, not repeated bridge calls.
   * out is initially empty. On failure it must be empty; release_encoded
   * nevertheless tolerates any partially owned output. Success owns its
   * bytes independently of the frame, with 0 < size <= capacity <= 50 MiB. */
  DshImageStatus (*encode)(DshImageFrame*, const DshImageTarget*,
                         DshImageEncoded*, DshImageError*);
  void (*release_encoded)(DshImageEncoded*);
  /* Set *frame to NULL only after every native resource is actually released.
   * A non-NULL result is unconfirmed retirement: the adapter retains input
   * and frame ownership, rejects close, and cannot claim env cleanup complete.
   * NULL input is an idempotent success. An error with NULL can report a
   * platform error after confirmed release; status and retirement differ. */
  DshImageStatus (*close)(DshImageFrame**, DshImageError*);
} DshImageBackend;

/* Exactly one definition at link time. Host fake and production backend
 * must never be linked into the same addon. No runtime backend/env selector. */
const DshImageBackend* dsh_image_codec_backend_v1(void);

#ifdef __cplusplus
}
#endif
#endif
