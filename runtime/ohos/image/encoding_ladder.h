#ifndef DSH_OHOS_IMAGE_ENCODING_LADDER_H
#define DSH_OHOS_IMAGE_ENCODING_LADDER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* R3 OH policy: an owned buffer limit, not a codec/RSS bound. */
#define DSH_IMAGE_ENCODE_CAPACITY ((size_t)52428800)
enum dsh_image_encode_status {
  DSH_IMAGE_ENCODE_OK = 0,
  DSH_IMAGE_ENCODE_ARGUMENT = 1,
  DSH_IMAGE_ENCODE_ALLOCATION = 2,
  DSH_IMAGE_ENCODE_PACK = 3,
  DSH_IMAGE_ENCODE_LENGTH = 4
};
struct dsh_image_encoded_bytes {
  uint8_t *data;
  size_t length;
  size_t capacity;
  uint32_t quality;
};
struct dsh_image_encode_error {
  enum dsh_image_encode_status status;
  int32_t native_status;
  uint32_t quality;
  size_t capacity;
};
/* Synchronous worker callback. 0 means success. Each entry sets *size to C;
 * successful return sets the actual length. Failed size/data are not consumed.
 * Do not retain data or throw across C. context supplies codec/format/PixelMap. */
typedef int32_t (*dsh_image_pack_once)(void *context, uint32_t quality,
                                     uint8_t *data, size_t *size);
/* 85/75/60, first success within soft target, else smallest (earliest tie).
 * Any failure discards all candidates. out must be zero-initialized and empty.
 * Successful bytes belong to caller independently of frame; release below.
 * This function does not prove the returned bytes are a valid image. */
enum dsh_image_encode_status dsh_image_encode_ladder(
    dsh_image_pack_once pack, void *context, size_t soft_max_bytes,
    struct dsh_image_encoded_bytes *out, struct dsh_image_encode_error *error);
/* Idempotent for this function's initialized output; not a PixelMap release. */
void dsh_image_encoded_bytes_release(struct dsh_image_encoded_bytes *bytes);
#ifdef __cplusplus
}
#endif
#endif
