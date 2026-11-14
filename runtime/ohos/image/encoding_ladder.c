#include "encoding_ladder.h"
#include <stdlib.h>
#include <string.h>

static enum dsh_image_encode_status fail(
    struct dsh_image_encode_error *error, enum dsh_image_encode_status status,
    int32_t native_status, uint32_t quality) {
  if (error != NULL) {
    error->status = status;
    error->native_status = native_status;
    error->quality = quality;
    error->capacity = DSH_IMAGE_ENCODE_CAPACITY;
  }
  return status;
}

void dsh_image_encoded_bytes_release(struct dsh_image_encoded_bytes *bytes) {
  if (bytes == NULL) return;
  free(bytes->data);
  *bytes = (struct dsh_image_encoded_bytes){0};
}

enum dsh_image_encode_status dsh_image_encode_ladder(
    dsh_image_pack_once pack, void *context, size_t soft_max_bytes,
    struct dsh_image_encoded_bytes *out, struct dsh_image_encode_error *error) {
  static const uint32_t qualities[] = {85, 75, 60};
  uint8_t *current = NULL;
  struct dsh_image_encoded_bytes best = {0};
  if (pack == NULL || soft_max_bytes == 0 || out == NULL || error == NULL ||
      out->data != NULL || out->length != 0 || out->capacity != 0 ||
      out->quality != 0) {
    return fail(error, DSH_IMAGE_ENCODE_ARGUMENT, 0, 0);
  }
  *error = (struct dsh_image_encode_error){0};
  current = (uint8_t *)malloc(DSH_IMAGE_ENCODE_CAPACITY);
  if (current == NULL) return fail(error, DSH_IMAGE_ENCODE_ALLOCATION, 0, 0);
  for (size_t i = 0; i < sizeof(qualities) / sizeof(qualities[0]); ++i) {
    const uint32_t quality = qualities[i];
    size_t length = DSH_IMAGE_ENCODE_CAPACITY;
    const int32_t native_status = pack(context, quality, current, &length);
    if (native_status != 0) {
      free(current);
      dsh_image_encoded_bytes_release(&best);
      return fail(error, DSH_IMAGE_ENCODE_PACK, native_status, quality);
    }
    if (length == 0 || length > DSH_IMAGE_ENCODE_CAPACITY) {
      free(current);
      dsh_image_encoded_bytes_release(&best);
      return fail(error, DSH_IMAGE_ENCODE_LENGTH, 0, quality);
    }
    if (length <= soft_max_bytes) {
      dsh_image_encoded_bytes_release(&best);
      *out = (struct dsh_image_encoded_bytes){
          current, length, DSH_IMAGE_ENCODE_CAPACITY, quality};
      return DSH_IMAGE_ENCODE_OK;
    }
    if (best.data == NULL || length < best.length) {
      /* Release the old best first: live owned encoding payload <= C + C. */
      dsh_image_encoded_bytes_release(&best);
      best.data = (uint8_t *)malloc(length);
      if (best.data == NULL) {
        free(current);
        return fail(error, DSH_IMAGE_ENCODE_ALLOCATION, 0, quality);
      }
      memcpy(best.data, current, length);
      best.length = length;
      best.capacity = length;
      best.quality = quality;
    }
  }
  free(current);
  *out = best;
  return DSH_IMAGE_ENCODE_OK;
}
