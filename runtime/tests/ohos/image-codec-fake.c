/* Host lifecycle fixture. The token and output below are NOT image data.
 * This file must never be a production codec backend. */
#ifndef DSH_IMAGE_HOST_FIXTURE
#error "image-codec-fake.c requires explicit host-fixture build"
#endif
#include "codec_bridge.h"
#include "image-codec-fake.h"
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct DshImageFrame {
  const uint8_t* retained_input;
  size_t input_size;
  uint8_t original[4];
  uint32_t serial;
  atomic_bool busy;
};

static atomic_uint opens, closes, active, encodes, overlaps;
static atomic_uint outputs, released_outputs, input_mismatches;
static atomic_uint cleanup_starts;
static pthread_mutex_t hold_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t hold_condition = PTHREAD_COND_INITIALIZER;
static bool hold_encodes;

static void facts(DshImageFacts* f, uint32_t width, uint32_t height, int working) {
  memset(f, 0, sizeof(*f));
  f->struct_size = sizeof(*f);
  f->known = DSH_IMAGE_FACT_DIMENSIONS | DSH_IMAGE_FACT_FORMAT | DSH_IMAGE_FACT_FRAMES |
      DSH_IMAGE_FACT_ORIENTATION;
  f->width = width; f->height = height; f->format = DSH_IMAGE_CODEC_FORMAT_PNG;
  f->frame_count = 1; f->orientation = 1;
  if (working) {
    f->known |= DSH_IMAGE_FACT_ALPHA | DSH_IMAGE_FACT_DEPTH | DSH_IMAGE_FACT_COLOR |
        DSH_IMAGE_FACT_METADATA | DSH_IMAGE_FACT_ALLOCATION;
    f->has_alpha = 0; f->bit_depth = 8; f->color_space = DSH_IMAGE_COLOR_SRGB;
    f->retained_metadata = 0; f->allocation_bytes = (uint64_t)width * height * 4;
  }
}

static DshImageStatus inspect(const uint8_t* bytes, size_t size,
                              DshImageFacts* out, DshImageError* error) {
  if (!bytes || size != 4 || bytes[0] != 0x31 || bytes[1] != 0x41 ||
      bytes[2] != 0x59 || bytes[3] != 0x26) {
    error->stage = "fake-token";
    return DSH_IMAGE_INVALID;
  }
  facts(out, 2, 2, 0);
  return DSH_IMAGE_OK;
}

static DshImageStatus open_frame(const uint8_t* bytes, size_t size,
    const DshImageLimits* limits, DshImageFrame** out, DshImageFacts* source,
    DshImageFacts* working, DshImageError* error) {
  DshImageStatus result = inspect(bytes, size, source, error);
  if (result != DSH_IMAGE_OK) return result;
  if (limits->max_side < 2) return DSH_IMAGE_EDGE_LIMIT;
  if (limits->max_pixels < 4) return DSH_IMAGE_PIXEL_LIMIT;
  DshImageFrame* f = calloc(1, sizeof(*f));
  if (!f) return DSH_IMAGE_INTERNAL;
  f->retained_input = bytes; f->input_size = size;
  memcpy(f->original, bytes, 4);
  atomic_init(&f->busy, false);
  facts(working, 2, 2, 1);
  *out = f;
  atomic_fetch_add(&opens, 1);
  return DSH_IMAGE_OK;
}

static DshImageStatus encode(DshImageFrame* f, const DshImageTarget* target,
                            DshImageEncoded* out, DshImageError* error) {
  if (atomic_exchange(&f->busy, true)) {
    atomic_fetch_add(&overlaps, 1);
    error->stage = "fake-overlap";
    return DSH_IMAGE_INTERNAL;
  }
  atomic_fetch_add(&active, 1);
  atomic_fetch_add(&encodes, 1);
  /* A fixture-only scheduling latch, not a codec result or injected failure.
   * No assumption that a timer window happens to catch an in-flight call. */
  pthread_mutex_lock(&hold_mutex);
  while (hold_encodes) pthread_cond_wait(&hold_condition, &hold_mutex);
  pthread_mutex_unlock(&hold_mutex);
  DshImageStatus result = DSH_IMAGE_OK;
  if (f->input_size != 4 || memcmp(f->retained_input, f->original, 4) != 0) {
    atomic_fetch_add(&input_mismatches, 1);
    error->stage = "fake-input-lifetime";
    result = DSH_IMAGE_INTERNAL;
  } else {
    out->data = malloc(8);
    if (!out->data) result = DSH_IMAGE_INTERNAL;
    else {
      out->size = out->capacity = 8;
      out->format = target->format; out->quality = 85;
      memcpy(out->data, "FAKE", 4);
      out->data[4] = f->original[0];
      out->data[5] = (uint8_t)target->width;
      out->data[6] = (uint8_t)target->height;
      out->data[7] = (uint8_t)++f->serial;
      facts(&out->facts, target->width, target->height, 1);
      out->facts.format = target->format;
      atomic_fetch_add(&outputs, 1);
    }
  }
  atomic_fetch_sub(&active, 1);
  atomic_store(&f->busy, false);
  return result;
}

static void release_encoded(DshImageEncoded* out) {
  if (out->data) {
    free(out->data);
    atomic_fetch_add(&released_outputs, 1);
  }
  memset(out, 0, sizeof(*out));
}

static DshImageStatus close_frame(DshImageFrame** ptr, DshImageError* error) {
  if (!*ptr) return DSH_IMAGE_OK;
  DshImageFrame* f = *ptr;
  if (atomic_exchange(&f->busy, true)) {
    atomic_fetch_add(&overlaps, 1);
    error->stage = "fake-close-overlap";
    return DSH_IMAGE_CLEANUP_UNCONFIRMED;
  }
  free(f);
  *ptr = NULL;
  atomic_fetch_add(&closes, 1);
  return DSH_IMAGE_OK;
}

static const DshImageBackend backend = {
  DSH_IMAGE_CODEC_ABI, sizeof(DshImageBackend),
  "host-lifecycle-fake-v1:no-codec:no-ndk:color-getter=not-used", 1,
  DSH_IMAGE_GETTER_NOT_USED, inspect, open_frame, encode, release_encoded, close_frame
};

const DshImageBackend* dsh_image_codec_backend_v1(void) { return &backend; }

void dsh_image_fake_stats(DshImageFakeStats* out) {
  *out = (DshImageFakeStats){
    atomic_load(&opens), atomic_load(&closes), atomic_load(&active),
    atomic_load(&encodes), atomic_load(&overlaps), atomic_load(&outputs),
    atomic_load(&released_outputs), atomic_load(&input_mismatches),
    atomic_load(&cleanup_starts)
  };
}

void dsh_image_fake_hold_encodes(uint32_t hold) {
  pthread_mutex_lock(&hold_mutex);
  hold_encodes = hold != 0;
  if (!hold_encodes) pthread_cond_broadcast(&hold_condition);
  pthread_mutex_unlock(&hold_mutex);
}

void dsh_image_fake_cleanup_started(void) { atomic_fetch_add(&cleanup_starts, 1); }
