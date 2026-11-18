/* OH SDK 26.0.0.38 backend. Device behavior is not yet measured.
 * Node headers and C++ objects never enter this translation unit. */
#include "codec_bridge.h"
#include "container_facts.h"
#include "encoding_ladder.h"
#include <multimedia/image_framework/image/image_source_native.h>
#include <multimedia/image_framework/image/image_packer_native.h>
#include <native_color_space_manager/native_color_space_manager.h>
#include <stdlib.h>
#include <string.h>

struct DshImageFrame {
  OH_ImageSourceNative *source, *verify_source;
  OH_ImageSource_Info *source_info;
  OH_DecodingOptions *decoding;
  OH_PixelmapNative *base, *work, *verify;
  OH_Pixelmap_ImageInfo *pixel_info;
  OH_ImagePackerNative *packer;
  OH_PackingOptions *packing;
  struct dsh_image_encoded_bytes pending;
  DshImageFacts source_facts;
  DshImageError cleanup_error, pack_error;
  DshImageStatus pack_status;
  uint32_t pack_format;
  int opened, unconfirmed;
};

static DshImageStatus fail(DshImageError *e, DshImageStatus status,
                           const char *stage, int32_t native_status) {
  if (e) { e->stage = stage; e->native_status = native_status; }
  return status;
}
static void facts_init(DshImageFacts *f) {
  memset(f, 0, sizeof(*f)); f->struct_size = sizeof(*f);
}
static uint32_t format_id(DshImageFormat value) {
  switch (value) {
    case DSH_IMAGE_PNG: return DSH_IMAGE_CODEC_FORMAT_PNG;
    case DSH_IMAGE_JPEG: return DSH_IMAGE_CODEC_FORMAT_JPEG;
    case DSH_IMAGE_WEBP: return DSH_IMAGE_CODEC_FORMAT_WEBP;
    case DSH_IMAGE_GIF: return DSH_IMAGE_CODEC_FORMAT_GIF;
    default: return DSH_IMAGE_CODEC_FORMAT_UNKNOWN;
  }
}
static uint32_t mime_id(const Image_MimeType *m) {
  if (!m->data) return DSH_IMAGE_CODEC_FORMAT_UNKNOWN;
  if (m->size == 9 && memcmp(m->data, "image/png", 9) == 0) return DSH_IMAGE_CODEC_FORMAT_PNG;
  if (m->size == 10 && memcmp(m->data, "image/jpeg", 10) == 0) return DSH_IMAGE_CODEC_FORMAT_JPEG;
  if (m->size == 10 && memcmp(m->data, "image/webp", 10) == 0) return DSH_IMAGE_CODEC_FORMAT_WEBP;
  if (m->size == 9 && memcmp(m->data, "image/gif", 9) == 0) return DSH_IMAGE_CODEC_FORMAT_GIF;
  return DSH_IMAGE_CODEC_FORMAT_UNKNOWN;
}
static void container_facts(const DshImageContainerFacts *c, DshImageFacts *f) {
  facts_init(f); f->format = format_id(c->format); f->known = DSH_IMAGE_FACT_FORMAT;
  if (c->known & DSH_IMAGE_K_DIMENSIONS) {
    f->width = c->width; f->height = c->height; f->known |= DSH_IMAGE_FACT_DIMENSIONS;
  }
  if (c->known & DSH_IMAGE_K_FRAMES) { f->frame_count = c->frames; f->known |= DSH_IMAGE_FACT_FRAMES; }
  if (c->known & DSH_IMAGE_K_ALPHA) { f->has_alpha = c->alpha; f->known |= DSH_IMAGE_FACT_ALPHA; }
  if (c->known & DSH_IMAGE_K_SAMPLE_BITS) { f->bit_depth = c->sample_bits; f->known |= DSH_IMAGE_FACT_DEPTH; }
  if (c->known & DSH_IMAGE_K_METADATA) { f->retained_metadata = c->metadata; f->known |= DSH_IMAGE_FACT_METADATA; }
  if (c->known & DSH_IMAGE_K_ORIENTATION) { f->orientation = c->orientation; f->known |= DSH_IMAGE_FACT_ORIENTATION; }
  /* A container SRGB convention is not an observed pixel color space. */
}
static DshImageStatus inspect(const uint8_t *data, size_t size,
                              DshImageFacts *out, DshImageError *error) {
  DshImageContainerFacts c;
  DshImageScanStatus status = dsh_image_scan_container(data, size, &c);
  facts_init(out);
  if (status != DSH_IMAGE_SCAN_OK)
    return fail(error, status == DSH_IMAGE_SCAN_UNSUPPORTED ? DSH_IMAGE_UNAVAILABLE : DSH_IMAGE_INVALID,
                "container-scan", 0);
  container_facts(&c, out);
  return DSH_IMAGE_OK;
}

/* A failed release is not retried: the SDK did not confirm whether the object
 * is still usable. Keep its owner and all dependent storage, and reject close.
 * This quarantine is reported; it is never described as successful cleanup. */
static int cleanup_failed(DshImageFrame *f, const char *stage, Image_ErrorCode code) {
  f->unconfirmed = 1;
  f->cleanup_error.stage = stage; f->cleanup_error.native_status = code;
  return 0;
}
#define DROP(field, function) do { \
  if (f->field) { \
    Image_ErrorCode drop_status = function(f->field); \
    if (drop_status != IMAGE_SUCCESS) return cleanup_failed(f, #function, drop_status); \
    f->field = NULL; \
  } \
} while (0)
#define DESTROY_MAP(field) do { \
  if (f->field) { \
    Image_ErrorCode drop_status = OH_PixelmapNative_Destroy(&f->field); \
    if (drop_status != IMAGE_SUCCESS) return cleanup_failed(f, "OH_PixelmapNative_Destroy:" #field, drop_status); \
    f->field = NULL; \
  } \
} while (0)
static int cleanup_temporary(DshImageFrame *f) {
  if (f->unconfirmed) return 0;
  DROP(packer, OH_ImagePackerNative_Release);
  DROP(packing, OH_PackingOptions_Release);
  DROP(pixel_info, OH_PixelmapImageInfo_Release);
  DESTROY_MAP(verify);
  DROP(verify_source, OH_ImageSourceNative_Release);
  DROP(source_info, OH_ImageSourceInfo_Release);
  DROP(decoding, OH_DecodingOptions_Release);
  DESTROY_MAP(work);
  return 1;
}
static DshImageStatus close_frame(DshImageFrame **handle, DshImageError *error) {
  DshImageFrame *f = *handle;
  if (!f) return DSH_IMAGE_OK;
  f->opened = 0;
  if (!cleanup_temporary(f)) {
    if (error) *error = f->cleanup_error;
    return DSH_IMAGE_CLEANUP_UNCONFIRMED;
  }
  if (f->base) {
    Image_ErrorCode code = OH_PixelmapNative_Destroy(&f->base);
    if (code != IMAGE_SUCCESS) {
      cleanup_failed(f, "OH_PixelmapNative_Destroy:base", code);
      if (error) *error = f->cleanup_error;
      return DSH_IMAGE_CLEANUP_UNCONFIRMED;
    }
    f->base = NULL;
  }
  if (f->source) {
    Image_ErrorCode code = OH_ImageSourceNative_Release(f->source);
    if (code != IMAGE_SUCCESS) {
      cleanup_failed(f, "OH_ImageSourceNative_Release:source", code);
      if (error) *error = f->cleanup_error;
      return DSH_IMAGE_CLEANUP_UNCONFIRMED;
    }
    f->source = NULL;
  }
  dsh_image_encoded_bytes_release(&f->pending);
  free(f); *handle = NULL;
  return DSH_IMAGE_OK;
}

/* Sole getter site. ADD28 selects ownership handling at build time. The
 * declaration does not prove that choice; both builds need device evidence. */
static DshImageStatus actual_color(OH_PixelmapNative *map, uint32_t *color,
                                   DshImageError *error) {
  OH_NativeColorSpaceManager *manager = NULL;
  Image_ErrorCode code = OH_PixelmapNative_GetColorSpaceNative(map, &manager);
  int name;
  if (code != IMAGE_SUCCESS) return fail(error, DSH_IMAGE_UNAVAILABLE, "color-getter", code);
  if (!manager) return fail(error, DSH_IMAGE_UNAVAILABLE, "color-getter-empty", 0);
  name = OH_NativeColorSpaceManager_GetColorSpaceName(manager);
#if DSH_IMAGE_DESTROY_COLORSPACE_GETTER
  OH_NativeColorSpaceManager_Destroy(manager);
#endif
  if (name == NONE) return fail(error, DSH_IMAGE_UNAVAILABLE, "color-name-unknown", 0);
  *color = name == SRGB ? DSH_IMAGE_COLOR_SRGB : DSH_IMAGE_COLOR_OTHER;
  return DSH_IMAGE_OK;
}

/* Failed creator output is not a usable handle. A surprising non-NULL output
 * is retained without calling another SDK function on that uncertain object. */
static DshImageStatus created(DshImageFrame *f, const void *object, Image_ErrorCode code,
                              DshImageStatus status, const char *stage, DshImageError *error) {
  if (code != IMAGE_SUCCESS) {
    if (object) cleanup_failed(f, stage, code);
    return fail(error, status, stage, code);
  }
  if (!object) return fail(error, DSH_IMAGE_INTERNAL, stage, 0);
  return DSH_IMAGE_OK;
}

#define NATIVE(call, status, stage) do { \
  Image_ErrorCode native_code = (call); \
  if (native_code != IMAGE_SUCCESS) return fail(error, status, stage, native_code); \
} while (0)
static DshImageStatus source_info(DshImageFrame *f, OH_ImageSourceNative *source,
                                  DshImageFacts *facts, DshImageError *error) {
  Image_MimeType mime = {NULL, 0};
  uint32_t width = 0, height = 0, count = 0, format;
  Image_ErrorCode code;
  DshImageStatus status;
  if (!f->source_info) {
    code = OH_ImageSourceInfo_Create(&f->source_info);
    status = created(f, f->source_info, code, DSH_IMAGE_UNAVAILABLE, "source-info-create", error);
    if (status != DSH_IMAGE_OK) return status;
  }
  NATIVE(OH_ImageSourceNative_GetImageInfo(source, 0, f->source_info), DSH_IMAGE_INVALID, "source-info");
  NATIVE(OH_ImageSourceInfo_GetWidth(f->source_info, &width), DSH_IMAGE_UNAVAILABLE, "source-width");
  NATIVE(OH_ImageSourceInfo_GetHeight(f->source_info, &height), DSH_IMAGE_UNAVAILABLE, "source-height");
  NATIVE(OH_ImageSourceInfo_GetMimeType(f->source_info, &mime), DSH_IMAGE_UNAVAILABLE, "source-mime");
  format = mime_id(&mime); /* Borrowed MIME is consumed before info release. */
  NATIVE(OH_ImageSourceNative_GetFrameCount(source, &count), DSH_IMAGE_UNAVAILABLE, "source-frames");
  if (!width || !height || !count || !format)
    return fail(error, DSH_IMAGE_INVALID, "source-fields", 0);
  if (((facts->known & DSH_IMAGE_FACT_DIMENSIONS) && (facts->width != width || facts->height != height)) ||
      ((facts->known & DSH_IMAGE_FACT_FORMAT) && facts->format != format) ||
      ((facts->known & DSH_IMAGE_FACT_FRAMES) && facts->frame_count != count))
    return fail(error, DSH_IMAGE_INVALID, "source-container-disagreement", 0);
  facts->width = width; facts->height = height; facts->format = format; facts->frame_count = count;
  facts->known |= DSH_IMAGE_FACT_DIMENSIONS | DSH_IMAGE_FACT_FORMAT | DSH_IMAGE_FACT_FRAMES;
  return DSH_IMAGE_OK;
}
static DshImageStatus pixel_info(DshImageFrame *f, OH_PixelmapNative *map,
                                 DshImageFacts *facts, int require_rgba, DshImageError *error) {
  Image_ErrorCode code;
  DshImageStatus status;
  int32_t format = PIXEL_FORMAT_UNKNOWN, alpha_mode = PIXELMAP_ALPHA_TYPE_UNKNOWN;
  uint32_t allocation = 0;
  bool hdr = true;
  facts_init(facts);
  if (!f->pixel_info) {
    code = OH_PixelmapImageInfo_Create(&f->pixel_info);
    status = created(f, f->pixel_info, code, DSH_IMAGE_UNAVAILABLE, "pixel-info-create", error);
    if (status != DSH_IMAGE_OK) return status;
  }
  NATIVE(OH_PixelmapNative_GetImageInfo(map, f->pixel_info), DSH_IMAGE_UNAVAILABLE, "pixel-info");
  NATIVE(OH_PixelmapImageInfo_GetWidth(f->pixel_info, &facts->width), DSH_IMAGE_UNAVAILABLE, "pixel-width");
  NATIVE(OH_PixelmapImageInfo_GetHeight(f->pixel_info, &facts->height), DSH_IMAGE_UNAVAILABLE, "pixel-height");
  NATIVE(OH_PixelmapImageInfo_GetPixelFormat(f->pixel_info, &format), DSH_IMAGE_UNAVAILABLE, "pixel-format");
  NATIVE(OH_PixelmapImageInfo_GetAlphaMode(f->pixel_info, &alpha_mode), DSH_IMAGE_UNAVAILABLE, "pixel-alpha");
  NATIVE(OH_PixelmapImageInfo_GetDynamicRange(f->pixel_info, &hdr), DSH_IMAGE_UNAVAILABLE, "pixel-range");
  NATIVE(OH_PixelmapNative_GetAllocationByteCount(map, &allocation), DSH_IMAGE_UNAVAILABLE, "pixel-allocation");
  if (!facts->width || !facts->height || !allocation || hdr)
    return fail(error, DSH_IMAGE_TRANSFORM_FAILED, "pixel-fields", 0);
  if ((require_rgba && format != PIXEL_FORMAT_RGBA_8888) ||
      (format != PIXEL_FORMAT_RGBA_8888 && format != PIXEL_FORMAT_BGRA_8888 && format != PIXEL_FORMAT_RGB_888))
    return fail(error, DSH_IMAGE_TRANSFORM_FAILED, "pixel-precision", 0);
  if (alpha_mode != PIXELMAP_ALPHA_TYPE_OPAQUE && alpha_mode != PIXELMAP_ALPHA_TYPE_PREMULTIPLIED &&
      alpha_mode != PIXELMAP_ALPHA_TYPE_UNPREMULTIPLIED)
    return fail(error, DSH_IMAGE_UNAVAILABLE, "pixel-alpha-unknown", 0);
  status = actual_color(map, &facts->color_space, error);
  if (status != DSH_IMAGE_OK) return status;
  if (facts->color_space != DSH_IMAGE_COLOR_SRGB)
    return fail(error, DSH_IMAGE_TRANSFORM_FAILED, "pixel-not-srgb", 0);
  facts->has_alpha = alpha_mode != PIXELMAP_ALPHA_TYPE_OPAQUE;
  facts->bit_depth = 8; facts->allocation_bytes = allocation;
  facts->known = DSH_IMAGE_FACT_DIMENSIONS | DSH_IMAGE_FACT_ALPHA | DSH_IMAGE_FACT_DEPTH |
      DSH_IMAGE_FACT_COLOR | DSH_IMAGE_FACT_ALLOCATION;
  return DSH_IMAGE_OK;
}
static DshImageStatus source_limits(const DshImageFacts *source,
                                    const DshImageLimits *limits, DshImageError *error) {
  if (!(source->known & DSH_IMAGE_FACT_DIMENSIONS) || !source->width || !source->height)
    return fail(error, DSH_IMAGE_UNAVAILABLE, "source-dimensions-unknown", 0);
  if (source->width > limits->max_side || source->height > limits->max_side)
    return fail(error, DSH_IMAGE_EDGE_LIMIT, "source-edge-limit", 0);
  if ((uint64_t)source->width * source->height > limits->max_pixels)
    return fail(error, DSH_IMAGE_PIXEL_LIMIT, "source-pixel-limit", 0);
  return DSH_IMAGE_OK;
}
static DshImageStatus open_frame(const uint8_t *data, size_t size, const DshImageLimits *limits,
                                 DshImageFrame **out, DshImageFacts *source,
                                 DshImageFacts *working, DshImageError *error) {
  DshImageFrame *f;
  DshImageStatus status;
  Image_ErrorCode code;
  Image_String orientation_key = {(char *)"Orientation", 11};
  uint16_t orientation = 0;
  *out = NULL; facts_init(working);
  status = inspect(data, size, source, error);
  if (status != DSH_IMAGE_OK) return status;
  status = source_limits(source, limits, error);
  if (status != DSH_IMAGE_OK) return status;
  f = calloc(1, sizeof(*f));
  if (!f) return fail(error, DSH_IMAGE_INTERNAL, "frame-allocation", 0);
  *out = f; /* Even failure now has an owner until close confirms retirement. */
  code = OH_ImageSourceNative_CreateFromData((uint8_t *)data, size, &f->source);
  status = created(f, f->source, code, DSH_IMAGE_INVALID, "source-create", error);
  if (status != DSH_IMAGE_OK) return status;
  status = source_info(f, f->source, source, error);
  if (status != DSH_IMAGE_OK) return status;
  /* Actual source dimensions must pass the same budget before full decode. */
  status = source_limits(source, limits, error);
  if (status != DSH_IMAGE_OK) return status;
  code = OH_ImageSourceNative_GetImagePropertyShort(f->source, &orientation_key, &orientation);
  if (code == IMAGE_SUCCESS) {
    if (orientation < 1 || orientation > 8 ||
        ((source->known & DSH_IMAGE_FACT_ORIENTATION) && source->orientation != orientation))
      return fail(error, DSH_IMAGE_UNAVAILABLE, "orientation-conflict", 0);
    source->orientation = orientation; source->known |= DSH_IMAGE_FACT_ORIENTATION;
  }
  /* Failure does not mean absent. Only the complete scanner can prove default 1. */
  if (!(source->known & DSH_IMAGE_FACT_ORIENTATION))
    return fail(error, DSH_IMAGE_UNAVAILABLE, "orientation-unknown", code == IMAGE_SUCCESS ? 0 : code);
  f->source_facts = *source;
  code = OH_DecodingOptions_Create(&f->decoding);
  status = created(f, f->decoding, code, DSH_IMAGE_UNAVAILABLE, "decode-options-create", error);
  if (status != DSH_IMAGE_OK) return status;
  NATIVE(OH_DecodingOptions_SetIndex(f->decoding, 0), DSH_IMAGE_UNAVAILABLE, "decode-index");
  NATIVE(OH_DecodingOptions_SetRotate(f->decoding, 0), DSH_IMAGE_UNAVAILABLE, "decode-rotation");
  NATIVE(OH_DecodingOptions_SetPixelFormat(f->decoding, PIXEL_FORMAT_RGBA_8888), DSH_IMAGE_UNAVAILABLE, "decode-format");
  NATIVE(OH_DecodingOptions_SetDesiredDynamicRange(f->decoding, IMAGE_DYNAMIC_RANGE_SDR), DSH_IMAGE_UNAVAILABLE, "decode-range");
  NATIVE(OH_DecodingOptions_SetDesiredColorSpace(f->decoding, SRGB), DSH_IMAGE_UNAVAILABLE, "decode-color");
  code = OH_ImageSourceNative_CreatePixelmap(f->source, f->decoding, &f->base);
  status = created(f, f->base, code, DSH_IMAGE_INVALID, "source-decode", error);
  if (status != DSH_IMAGE_OK) return status;
  status = pixel_info(f, f->base, working, 1, error);
  if (status != DSH_IMAGE_OK) return status;
  if (working->width != source->width || working->height != source->height)
    return fail(error, DSH_IMAGE_UNAVAILABLE, "decode-dimensions-or-orientation", 0);
  if (!cleanup_temporary(f)) {
    if (error) *error = f->cleanup_error;
    return DSH_IMAGE_CLEANUP_UNCONFIRMED;
  }
  f->opened = 1;
  return DSH_IMAGE_OK;
}

static DshImageStatus prepare_work(DshImageFrame *f, const DshImageTarget *target,
                                   DshImageFacts *actual, DshImageError *error) {
  Image_ErrorCode code;
  DshImageStatus status;
  uint32_t orientation = f->source_facts.orientation;
  uint32_t oriented_w = orientation >= 5 ? f->source_facts.height : f->source_facts.width;
  uint32_t oriented_h = orientation >= 5 ? f->source_facts.width : f->source_facts.height;
  float angle = 0;
  bool flip_h = false, flip_v = false;
  double scale;
  code = OH_PixelmapNative_Clone(f->base, &f->work);
  status = created(f, f->work, code, DSH_IMAGE_TRANSFORM_FAILED, "work-clone", error);
  if (status != DSH_IMAGE_OK) return status;
  switch (orientation) {
    case 2: flip_h = true; break;
    case 3: angle = 180; break;
    case 4: flip_v = true; break;
    case 5: angle = 90; flip_h = true; break;
    case 6: angle = 90; break;
    case 7: angle = 90; flip_v = true; break;
    case 8: angle = 270; break;
    default: break; /* open admitted only exact 1..8. */
  }
  /* Positive angles follow the documented clockwise PixelMap convention.
   * The eight asymmetric device oracles must still confirm decoder behavior. */
  if (angle) NATIVE(OH_PixelmapNative_ApplyRotate(f->work, angle), DSH_IMAGE_TRANSFORM_FAILED, "work-rotate");
  if (flip_h || flip_v)
    NATIVE(OH_PixelmapNative_ApplyFlip(f->work, flip_h, flip_v), DSH_IMAGE_TRANSFORM_FAILED, "work-flip");
  status = pixel_info(f, f->work, actual, 1, error);
  if (status != DSH_IMAGE_OK) return status;
  if (actual->width != oriented_w || actual->height != oriented_h)
    return fail(error, DSH_IMAGE_TRANSFORM_FAILED, "work-orientation-dimensions", 0);
  scale = (double)target->width / oriented_w;
  if ((double)target->height / oriented_h < scale) scale = (double)target->height / oriented_h;
  if (scale > 1.0) scale = 1.0;
  if (scale < 1.0) {
    NATIVE(OH_PixelmapNative_ApplyScaleWithAntiAliasing(f->work, (float)scale, (float)scale,
           OH_PixelmapNative_AntiAliasing_HIGH), DSH_IMAGE_TRANSFORM_FAILED, "work-scale");
    status = pixel_info(f, f->work, actual, 1, error);
    if (status != DSH_IMAGE_OK) return status;
  }
  if (actual->width > target->width || actual->height > target->height ||
      actual->width > oriented_w || actual->height > oriented_h)
    return fail(error, DSH_IMAGE_TRANSFORM_FAILED, "work-fit-inside", 0);
  actual->orientation = 1; actual->known |= DSH_IMAGE_FACT_ORIENTATION;
  return DSH_IMAGE_OK;
}

static int cleanup_packing(DshImageFrame *f) {
  if (f->unconfirmed) return 0;
  DROP(packer, OH_ImagePackerNative_Release);
  DROP(packing, OH_PackingOptions_Release);
  return 1;
}
static int32_t pack_once(void *context, uint32_t quality, uint8_t *data, size_t *size) {
  DshImageFrame *f = context;
  Image_ErrorCode code;
  DshImageStatus status;
  Image_MimeType mime;
  DshImageError *error = &f->pack_error;
  mime.data = f->pack_format == DSH_IMAGE_CODEC_FORMAT_JPEG ? (char *)"image/jpeg" : (char *)"image/webp";
  mime.size = 10;
  f->pack_status = DSH_IMAGE_ENCODE_FAILED;
  code = OH_ImagePackerNative_Create(&f->packer);
  status = created(f, f->packer, code, DSH_IMAGE_ENCODE_FAILED, "packer-create", error);
  if (status != DSH_IMAGE_OK) { f->pack_status = status; goto failed; }
  code = OH_PackingOptions_Create(&f->packing);
  status = created(f, f->packing, code, DSH_IMAGE_ENCODE_FAILED, "packing-options-create", error);
  if (status != DSH_IMAGE_OK) { f->pack_status = status; goto failed; }
#define PACK_OPTION(call, stage_name) do { \
  code = (call); \
  if (code != IMAGE_SUCCESS) { fail(error, DSH_IMAGE_ENCODE_FAILED, stage_name, code); goto failed; } \
} while (0)
  PACK_OPTION(OH_PackingOptions_SetMimeType(f->packing, &mime), "packing-mime");
  PACK_OPTION(OH_PackingOptions_SetQuality(f->packing, quality), "packing-quality");
  PACK_OPTION(OH_PackingOptions_SetNeedsPackProperties(f->packing, false), "packing-properties");
  PACK_OPTION(OH_PackingOptions_SetDesiredDynamicRange(f->packing, IMAGE_PACKER_DYNAMIC_RANGE_SDR), "packing-range");
  /* The ladder resets size to its fixed 50 MiB capacity for every call. */
  code = OH_ImagePackerNative_PackToDataFromPixelmap(f->packer, f->packing, f->work, data, size);
  if (code != IMAGE_SUCCESS) { fail(error, DSH_IMAGE_ENCODE_FAILED, "pack-data", code); goto failed; }
  if (!cleanup_packing(f)) {
    f->pack_status = DSH_IMAGE_CLEANUP_UNCONFIRMED; f->pack_error = f->cleanup_error;
    return 1;
  }
  f->pack_status = DSH_IMAGE_OK;
  return 0;
failed:
  /* Keep the original operation error. close separately reports any failed
   * cleanup; the ladder receives nonzero and ignores failed size/data. */
  (void)cleanup_packing(f);
  return code == IMAGE_SUCCESS ? 1 : code;
#undef PACK_OPTION
}

static DshImageStatus verify_output(DshImageFrame *f, const DshImageFacts *working,
                                    DshImageFacts *out, DshImageError *error) {
  DshImageContainerFacts c;
  DshImageFacts decoded;
  DshImageScanStatus scan;
  DshImageStatus status;
  Image_ErrorCode code;
  uint32_t required = DSH_IMAGE_K_DIMENSIONS | DSH_IMAGE_K_SAMPLE_BITS |
      DSH_IMAGE_K_METADATA | DSH_IMAGE_K_ORIENTATION | DSH_IMAGE_K_FRAMES;
  scan = dsh_image_scan_container(f->pending.data, f->pending.length, &c);
  if (scan != DSH_IMAGE_SCAN_OK)
    return fail(error, scan == DSH_IMAGE_SCAN_UNSUPPORTED ? DSH_IMAGE_UNAVAILABLE : DSH_IMAGE_INVALID,
                "output-container-scan", 0);
  if ((c.known & required) != required)
    return fail(error, DSH_IMAGE_UNAVAILABLE, "output-container-facts-unknown", 0);
  if (!c.output_subset || c.sample_bits != 8 || c.metadata || c.orientation != 1 || c.frames != 1 ||
      format_id(c.format) != f->pack_format || c.width != working->width || c.height != working->height)
    return fail(error, DSH_IMAGE_ENCODE_FAILED, "output-container", 0);
  container_facts(&c, out);
  code = OH_ImageSourceNative_CreateFromData(f->pending.data, f->pending.length, &f->verify_source);
  status = created(f, f->verify_source, code, DSH_IMAGE_INVALID, "output-source-create", error);
  if (status != DSH_IMAGE_OK) return status;
  status = source_info(f, f->verify_source, out, error);
  if (status != DSH_IMAGE_OK) return status;
  code = OH_DecodingOptions_Create(&f->decoding);
  status = created(f, f->decoding, code, DSH_IMAGE_UNAVAILABLE, "output-options-create", error);
  if (status != DSH_IMAGE_OK) return status;
  NATIVE(OH_DecodingOptions_SetIndex(f->decoding, 0), DSH_IMAGE_UNAVAILABLE, "output-index");
  /* No desired color/pixel format/SDR override may manufacture output facts. */
  code = OH_ImageSourceNative_CreatePixelmap(f->verify_source, f->decoding, &f->verify);
  status = created(f, f->verify, code, DSH_IMAGE_INVALID, "output-decode", error);
  if (status != DSH_IMAGE_OK) return status;
  status = pixel_info(f, f->verify, &decoded, 0, error);
  if (status != DSH_IMAGE_OK)
    return status == DSH_IMAGE_TRANSFORM_FAILED ? DSH_IMAGE_ENCODE_FAILED : status;
  if (decoded.width != working->width || decoded.height != working->height ||
      ((c.known & DSH_IMAGE_K_ALPHA) && c.alpha != decoded.has_alpha) ||
      (f->pack_format == DSH_IMAGE_CODEC_FORMAT_JPEG && decoded.has_alpha))
    return fail(error, DSH_IMAGE_ENCODE_FAILED, "output-pixel-disagreement", 0);
  /* WebP may drop an entirely opaque alpha plane. GIF's existing first-frame
   * contract does not prescribe the alpha of the entire source animation. */
  if (f->source_facts.format != DSH_IMAGE_CODEC_FORMAT_GIF &&
      (f->source_facts.known & DSH_IMAGE_FACT_ALPHA) &&
      decoded.has_alpha != f->source_facts.has_alpha &&
      !(f->pack_format == DSH_IMAGE_CODEC_FORMAT_WEBP && f->source_facts.has_alpha && !decoded.has_alpha))
    return fail(error, DSH_IMAGE_ENCODE_FAILED, "output-alpha-contract", 0);
  out->has_alpha = decoded.has_alpha; out->color_space = decoded.color_space;
  out->allocation_bytes = decoded.allocation_bytes;
  out->known |= DSH_IMAGE_FACT_ALPHA | DSH_IMAGE_FACT_COLOR | DSH_IMAGE_FACT_ALLOCATION;
  return DSH_IMAGE_OK;
}

static DshImageStatus encode_frame(DshImageFrame *f, const DshImageTarget *target,
                                   DshImageEncoded *out, DshImageError *error) {
  DshImageFacts working, verified;
  DshImageStatus status;
  struct dsh_image_encode_error ladder_error;
  enum dsh_image_encode_status ladder_status;
  size_t soft_limit = (size_t)target->soft_max_bytes;
  if (!f || !f->opened || f->unconfirmed)
    return fail(error, DSH_IMAGE_CLEANUP_UNCONFIRMED, "frame-not-open", 0);
  if (!target->width || !target->height || !target->soft_max_bytes ||
      (uint64_t)soft_limit != target->soft_max_bytes || out->data || out->size || out->capacity ||
      (target->format != DSH_IMAGE_CODEC_FORMAT_JPEG && target->format != DSH_IMAGE_CODEC_FORMAT_WEBP))
    return fail(error, DSH_IMAGE_INTERNAL, "encode-arguments", 0);
  if (target->format == DSH_IMAGE_CODEC_FORMAT_JPEG &&
      (!(f->source_facts.known & DSH_IMAGE_FACT_ALPHA) || f->source_facts.has_alpha))
    return fail(error, DSH_IMAGE_TRANSFORM_FAILED, "jpeg-needs-known-opaque-source", 0);
  status = prepare_work(f, target, &working, error);
  if (status != DSH_IMAGE_OK) goto done;
  f->pack_format = target->format;
  ladder_status = dsh_image_encode_ladder(pack_once, f, soft_limit,
                                         &f->pending, &ladder_error);
  if (ladder_status != DSH_IMAGE_ENCODE_OK) {
    if (ladder_status == DSH_IMAGE_ENCODE_PACK) {
      status = f->pack_status;
      if (error) *error = f->pack_error;
    } else {
      status = fail(error, DSH_IMAGE_ENCODE_FAILED,
          ladder_status == DSH_IMAGE_ENCODE_ALLOCATION ? "encode-buffer-allocation" : "encode-result-length", 0);
    }
    goto done;
  }
  /* Drop the cloned work map before allocating verification pixels. The
   * immutable base remains alive so another target can use this frame. */
  if (!cleanup_temporary(f)) {
    if (error) *error = f->cleanup_error;
    return DSH_IMAGE_CLEANUP_UNCONFIRMED;
  }
  status = verify_output(f, &working, &verified, error);
done:
  if (!cleanup_temporary(f)) {
    if (status == DSH_IMAGE_OK) {
      if (error) *error = f->cleanup_error;
      return DSH_IMAGE_CLEANUP_UNCONFIRMED;
    }
    return status; /* close separately exposes the unconfirmed cleanup. */
  }
  if (status != DSH_IMAGE_OK) {
    dsh_image_encoded_bytes_release(&f->pending);
    return status;
  }
  out->data = f->pending.data; out->size = f->pending.length;
  out->capacity = f->pending.capacity; out->quality = f->pending.quality;
  out->format = target->format; out->facts = verified;
  memset(&f->pending, 0, sizeof(f->pending));
  return DSH_IMAGE_OK;
}
static void release_encoded(DshImageEncoded *out) {
  free(out->data); memset(out, 0, sizeof(*out));
}

#if DSH_IMAGE_DESTROY_COLORSPACE_GETTER
#define GETTER_ID "destroy"
#define GETTER_POLICY DSH_IMAGE_GETTER_DESTROY
#else
#define GETTER_ID "borrow"
#define GETTER_POLICY DSH_IMAGE_GETTER_BORROW
#endif
const DshImageBackend *dsh_image_codec_backend_v1(void) {
  static const DshImageBackend backend = {
    DSH_IMAGE_CODEC_ABI, sizeof(DshImageBackend),
    "oh-image-ndk26-v1;decode=rgba8-sdr-srgb;resize=high-fit-inside;orient=explicit;"
    "quality=85,75,60;cap=52428800;verify=container+decode;getcolor=" GETTER_ID,
    0, GETTER_POLICY, inspect, open_frame, encode_frame, release_encoded, close_frame
  };
  return &backend;
}
