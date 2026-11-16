/* Test-only derivative of frozen 376 for ordinary sequential attachment integration.
 * Real v3 factory, bridge and NDK code stay unchanged. These are 44 SDK call
 * implementations, not pixel codecs or device color-handle ownership proof.
 * Byte origin and decode purpose are separate. JSONL is observation only. */
#include "image-attachment-host.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <unistd.h>

enum { POOL = 128, RECEIPTS = 32 };
typedef struct { unsigned id; enum FxKind kind; bool live; } Object;
struct OH_ImageSourceNative {
  Object o; const uint8_t *bytes; size_t size; uint64_t checksum;
  uint32_t width, height, format; uint16_t orientation; bool output; int32_t alpha;
};
struct OH_ImageSource_Info { Object o; OH_ImageSourceNative *source; };
struct OH_DecodingOptions {
  Object o; unsigned mask; uint32_t index; float rotate;
  int32_t format, range, color;
};
struct OH_PixelmapNative {
  Object o; OH_ImageSourceNative *source; enum FxMapRole role;
  uint32_t width, height; int32_t format, alpha; int color; bool hdr;
};
struct OH_Pixelmap_ImageInfo {
  Object o; uint32_t width, height; int32_t format, alpha; bool hdr;
};
struct OH_PackingOptions { Object o; unsigned mask; uint32_t quality, format; bool properties; int32_t range; };
struct OH_ImagePackerNative { Object o; OH_PackingOptions *last_options; };
struct OH_NativeColorSpaceManager { unsigned id; bool live, borrowed; int name; OH_PixelmapNative *map; };
typedef struct {
  uint8_t data[1024]; size_t size;
  uint32_t width, height, format; int32_t alpha;
} Receipt;

static FxConfig config;
static FxStats stats;
static unsigned next_id, source_used, info_used, decoding_used, map_used;
static unsigned pixel_info_used, packer_used, packing_used, color_used, receipt_used;
static OH_ImageSourceNative sources[POOL];
static OH_ImageSource_Info source_infos[POOL];
static OH_DecodingOptions decodings[POOL];
static OH_PixelmapNative maps[POOL];
static OH_Pixelmap_ImageInfo pixel_infos[POOL];
static OH_ImagePackerNative packers[POOL];
static OH_PackingOptions packings[POOL];
static OH_NativeColorSpaceManager colors[POOL];
static Receipt receipts[RECEIPTS];
static OH_NativeColorSpaceManager *pending_color;
static unsigned color_phase;

/* No exported test stats API, factory wrapper, or fixtureOnly override.
 * The observer FD is test-owned and stays open until this host process exits. */
static int trace_fd = -1;
static uint64_t trace_sequence;
static pthread_mutex_t trace_mutex = PTHREAD_MUTEX_INITIALIZER;
static void trace_event(const char *type, const char *name, unsigned id,
                        uint64_t a, uint64_t b) {
  char line[512];
  if (pthread_mutex_lock(&trace_mutex)) _exit(71);
  int n = snprintf(line, sizeof(line),
      "{\"seq\":%" PRIu64 ",\"type\":\"%s\",\"name\":\"%s\",\"id\":%u,\"a\":%" PRIu64 ",\"b\":%" PRIu64 "}\n",
      ++trace_sequence, type, name, id, a, b);
  if (n <= 0 || (size_t)n >= sizeof(line) || trace_fd < 0) _exit(71);
  size_t at = 0;
  while (at < (size_t)n) {
    ssize_t v = write(trace_fd, line + at, (size_t)n - at);
    if (v < 0 && errno == EINTR) continue;
    if (v <= 0) _exit(71);
    at += (size_t)v;
  }
  if (pthread_mutex_unlock(&trace_mutex)) _exit(71);
}
__attribute__((constructor)) static void trace_begin(void) {
  const char *path = getenv("DSH_IMAGE_TEST_TRACE");
  if (!path || path[0] != '/') _exit(71);
  trace_fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (trace_fd < 0) _exit(71);
  config = image_ndk_fixture_defaults();
  trace_event("carrier", "sdk-test-carrier-not-pixels", 0, 1, 0);
}
__attribute__((destructor)) static void trace_end(void) {
  if (trace_fd >= 0) {
    trace_event("carrier", "process-exit", 0, stats.packs, stats.sdk_calls);
    int fd = trace_fd; trace_fd = -1;
    if (close(fd) != 0) _exit(71);
  }
}

void image_ndk_fixture_require(int condition, const char *expression, int line) {
  if (condition) return;
  fprintf(stderr, "SDK_FIXTURE_CONTRACT_FAIL line=%d expression=%s\n", line, expression);
  exit(70);
}
static uint64_t checksum(const uint8_t *p, size_t n) {
  uint64_t h = UINT64_C(14695981039346656037);
  for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= UINT64_C(1099511628211); }
  return h;
}
static void call(const char *name, unsigned id, uint64_t a, uint64_t b) {
  if (color_phase == 1) FX_REQUIRE(strcmp(name, "OH_NativeColorSpaceManager_GetColorSpaceName") == 0);
  if (color_phase == 2) FX_REQUIRE(strcmp(name, "OH_NativeColorSpaceManager_Destroy") == 0);
  FX_REQUIRE(stats.events_count < FX_MAX_EVENTS);
  stats.events[stats.events_count++] = (FxEvent){name, id, a, b};
  ++stats.sdk_calls;
  trace_event("call", name, id, a, b);
}
static void *object(void *array, size_t stride, unsigned *used, enum FxKind kind) {
  FX_REQUIRE(*used < POOL);
  Object *o = (Object *)((uint8_t *)array + stride * (*used)++);
  memset(o, 0, stride); o->id = ++next_id; o->kind = kind; o->live = true;
  ++stats.created[kind]; ++stats.live[kind];
  trace_event("create", "sdk-object", o->id, kind, 0); return o;
}
static void valid(const Object *o, enum FxKind kind) { FX_REQUIRE(o && o->live && o->kind == kind); }
static void drop(Object *o, enum FxKind kind) {
  if (!o || !o->live || o->kind != kind) { ++stats.bad_releases; FX_REQUIRE(0); }
  o->live = false; --stats.live[kind]; ++stats.released[kind];
  trace_event("release", "sdk-object", o->id, kind, 0);
}
#define NEW(array, used, kind) object(array, sizeof((array)[0]), &(used), kind)
#define ENTER(name, p, kind) do { valid(&(p)->o, kind); call(#name, (p)->o.id, 0, 0); } while (0)

FxConfig image_ndk_fixture_defaults(void) {
  FxConfig c = {0};
  c.pack_sizes[0] = 240; c.pack_sizes[1] = 220; c.pack_sizes[2] = 200;
  c.pack_error = IMAGE_TOO_LARGE;
  c.base_color = c.output_color = SRGB;
  c.base_format = PIXEL_FORMAT_RGBA_8888; c.output_format = PIXEL_FORMAT_RGB_888;
  c.base_alpha = c.output_alpha = PIXELMAP_ALPHA_TYPE_OPAQUE;
  return c;
}
void image_ndk_fixture_check_normal_end(void) {
  for (unsigned k = 0; k < FX_KIND_COUNT; ++k) {
    FX_REQUIRE(stats.live[k] == 0); FX_REQUIRE(stats.created[k] == stats.released[k]);
  }
  FX_REQUIRE(stats.bad_releases == 0 && !pending_color && color_phase == 0);
  for (unsigned i = 0; i < color_used; ++i) FX_REQUIRE(!colors[i].live);
#if DSH_IMAGE_DESTROY_COLORSPACE_GETTER
  FX_REQUIRE(stats.color_names == stats.color_destroys);
#else
  FX_REQUIRE(stats.color_destroys == 0);
#endif
}
void image_ndk_fixture_reset(FxConfig c) {
  image_ndk_fixture_check_normal_end(); config = c; memset(&stats, 0, sizeof(stats));
  next_id = source_used = info_used = decoding_used = map_used = 0;
  pixel_info_used = packer_used = packing_used = color_used = receipt_used = 0;
  pending_color = NULL; color_phase = 0;
}
const FxStats *image_ndk_fixture_stats(void) { return &stats; }

Image_ErrorCode OH_ImageSourceNative_CreateFromData(uint8_t *data, size_t size, OH_ImageSourceNative **out) {
  call("OH_ImageSourceNative_CreateFromData", 0, size, 0); FX_REQUIRE(data && out && !*out);
  OH_ImageSourceNative *s = NEW(sources, source_used, FX_SOURCE);
  s->bytes = data; s->size = size; s->checksum = checksum(data, size);
  if (size == image_attachment_jpeg_size && memcmp(data, image_attachment_jpeg, size) == 0) {
    s->width = 6; s->height = 4; s->format = DSH_IMAGE_CODEC_FORMAT_JPEG;
    s->orientation = 1; s->alpha = PIXELMAP_ALPHA_TYPE_OPAQUE;
  } else if (size == image_attachment_png_size && memcmp(data, image_attachment_png, size) == 0) {
    s->width = 6; s->height = 4; s->format = DSH_IMAGE_CODEC_FORMAT_PNG;
    s->orientation = 1; s->alpha = PIXELMAP_ALPHA_TYPE_UNPREMULTIPLIED;
  } else {
    const Receipt *r = NULL;
    for (unsigned i = receipt_used; i > 0; --i) {
      const Receipt *v = &receipts[i - 1];
      /* The real ladder may return a distinct, length-sized copy of its best
       * result. Match the entire emitted packet, not the original buffer's
       * address; this still rejects anything the fake packer did not emit. */
      if (v->size == size && memcmp(v->data, data, size) == 0) { r = v; break; }
    }
    FX_REQUIRE(r); s->width = r->width; s->height = r->height; s->format = r->format;
    s->orientation = 1; s->alpha = r->alpha; s->output = true; ++stats.output_sources;
  }
  trace_event("source", s->output ? "receipt" : "input", s->o.id, s->format, (uint64_t)(s->alpha != PIXELMAP_ALPHA_TYPE_OPAQUE));
  *out = s; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceNative_Release(OH_ImageSourceNative *s) {
  ENTER(OH_ImageSourceNative_Release, s, FX_SOURCE);
  for (unsigned i = 0; i < map_used; ++i) FX_REQUIRE(!maps[i].o.live || maps[i].source != s);
  FX_REQUIRE(checksum(s->bytes, s->size) == s->checksum); ++stats.source_input_checks;
  if (s->output) ++stats.output_source_releases;
  drop(&s->o, FX_SOURCE); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceInfo_Create(OH_ImageSource_Info **out) {
  call("OH_ImageSourceInfo_Create", 0, 0, 0); FX_REQUIRE(out && !*out);
  *out = NEW(source_infos, info_used, FX_SOURCE_INFO); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceInfo_Release(OH_ImageSource_Info *i) {
  ENTER(OH_ImageSourceInfo_Release, i, FX_SOURCE_INFO); drop(&i->o, FX_SOURCE_INFO); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceNative_GetImageInfo(OH_ImageSourceNative *s, int32_t index, OH_ImageSource_Info *i) {
  ENTER(OH_ImageSourceNative_GetImageInfo, s, FX_SOURCE); valid(&i->o, FX_SOURCE_INFO);
  FX_REQUIRE(index == 0); i->source = s; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceInfo_GetWidth(OH_ImageSource_Info *i, uint32_t *v) {
  ENTER(OH_ImageSourceInfo_GetWidth, i, FX_SOURCE_INFO); valid(&i->source->o, FX_SOURCE); *v = i->source->width; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceInfo_GetHeight(OH_ImageSource_Info *i, uint32_t *v) {
  ENTER(OH_ImageSourceInfo_GetHeight, i, FX_SOURCE_INFO); valid(&i->source->o, FX_SOURCE); *v = i->source->height; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceInfo_GetMimeType(OH_ImageSource_Info *i, Image_MimeType *v) {
  ENTER(OH_ImageSourceInfo_GetMimeType, i, FX_SOURCE_INFO); valid(&i->source->o, FX_SOURCE);
  v->data = i->source->format == DSH_IMAGE_CODEC_FORMAT_PNG ? (char *)"image/png" :
      i->source->format == DSH_IMAGE_CODEC_FORMAT_JPEG ? (char *)"image/jpeg" : (char *)"image/webp";
  v->size = strlen(v->data); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceNative_GetFrameCount(OH_ImageSourceNative *s, uint32_t *v) {
  ENTER(OH_ImageSourceNative_GetFrameCount, s, FX_SOURCE); *v = 1; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyShort(OH_ImageSourceNative *s, Image_String *key, uint16_t *v) {
  ENTER(OH_ImageSourceNative_GetImagePropertyShort, s, FX_SOURCE);
  FX_REQUIRE(key && key->size == 11 && memcmp(key->data, "Orientation", 11) == 0);
  if (s->orientation == 1) return IMAGE_UNSUPPORTED_METADATA;
  *v = s->orientation; return IMAGE_SUCCESS;
}

Image_ErrorCode OH_DecodingOptions_Create(OH_DecodingOptions **out) {
  call("OH_DecodingOptions_Create", 0, 0, 0); FX_REQUIRE(out && !*out);
  *out = NEW(decodings, decoding_used, FX_DECODING); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_DecodingOptions_Release(OH_DecodingOptions *o) {
  ENTER(OH_DecodingOptions_Release, o, FX_DECODING); drop(&o->o, FX_DECODING); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_DecodingOptions_SetIndex(OH_DecodingOptions *o, uint32_t v) {
  ENTER(OH_DecodingOptions_SetIndex, o, FX_DECODING); o->mask |= FX_INDEX; o->index = v; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_DecodingOptions_SetRotate(OH_DecodingOptions *o, float v) {
  ENTER(OH_DecodingOptions_SetRotate, o, FX_DECODING); o->mask |= FX_ROTATE; o->rotate = v; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_DecodingOptions_SetPixelFormat(OH_DecodingOptions *o, int32_t v) {
  ENTER(OH_DecodingOptions_SetPixelFormat, o, FX_DECODING); o->mask |= FX_FORMAT; o->format = v; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_DecodingOptions_SetDesiredDynamicRange(OH_DecodingOptions *o, int32_t v) {
  ENTER(OH_DecodingOptions_SetDesiredDynamicRange, o, FX_DECODING); o->mask |= FX_RANGE; o->range = v; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_DecodingOptions_SetDesiredColorSpace(OH_DecodingOptions *o, int32_t v) {
  ENTER(OH_DecodingOptions_SetDesiredColorSpace, o, FX_DECODING); o->mask |= FX_COLOR; o->color = v; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImageSourceNative_CreatePixelmap(OH_ImageSourceNative *s, OH_DecodingOptions *o, OH_PixelmapNative **out) {
  ENTER(OH_ImageSourceNative_CreatePixelmap, s, FX_SOURCE); valid(&o->o, FX_DECODING); FX_REQUIRE(out && !*out);
  FX_REQUIRE(o->index == 0 && (o->mask & FX_INDEX));
  const bool verification = o->mask == FX_INDEX;
  if (verification) {
    FX_REQUIRE(s->output);
    ++stats.verification_decodes; stats.verification_options |= o->mask;
    FX_REQUIRE(o->mask == FX_INDEX);
    if (config.output_decode_error) return config.output_decode_error;
    /* A work clone must already be retired before verification allocates. */
    for (unsigned i = 0; i < map_used; ++i) FX_REQUIRE(!maps[i].o.live || maps[i].role != FX_WORK);
  } else {
    ++stats.source_decodes; stats.base_options |= o->mask;
    FX_REQUIRE(o->mask == (FX_INDEX | FX_ROTATE | FX_FORMAT | FX_RANGE | FX_COLOR));
    FX_REQUIRE(o->rotate == 0 && o->format == PIXEL_FORMAT_RGBA_8888 && o->range == IMAGE_DYNAMIC_RANGE_SDR && o->color == SRGB);
    if (config.base_decode_error) return config.base_decode_error;
  }
  OH_PixelmapNative *m = NEW(maps, map_used, FX_MAP);
  m->source = s; m->role = verification ? FX_VERIFY : FX_BASE; m->width = s->width; m->height = s->height;
  /* These returned facts are independent of the request fields above. */
  m->format = verification && s->alpha == PIXELMAP_ALPHA_TYPE_OPAQUE ? PIXEL_FORMAT_RGB_888 : PIXEL_FORMAT_RGBA_8888;
  m->alpha = s->alpha;
  m->color = SRGB;
  m->hdr = false;
  if (!verification) stats.last_base_id = m->o.id;
  trace_event("decode", verification ? "verify" : "source", m->o.id, s->width, s->height);
  *out = m; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapNative_Clone(OH_PixelmapNative *src, OH_PixelmapNative **out) {
  ENTER(OH_PixelmapNative_Clone, src, FX_MAP); FX_REQUIRE(src->role == FX_BASE && out && !*out && stats.clones < 16);
  FX_REQUIRE(src->width == src->source->width && src->height == src->source->height);
  unsigned i = stats.clones++; stats.clone_parent[i] = src->o.id;
  stats.clone_width[i] = src->width; stats.clone_height[i] = src->height;
  OH_PixelmapNative *m = NEW(maps, map_used, FX_MAP); Object own = m->o; *m = *src; m->o = own; m->role = FX_WORK;
  *out = m; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapNative_ApplyRotate(OH_PixelmapNative *m, float angle) {
  ENTER(OH_PixelmapNative_ApplyRotate, m, FX_MAP); FX_REQUIRE(m->role == FX_WORK);
  FX_REQUIRE(angle == 90 || angle == 180 || angle == 270); ++stats.rotations; stats.last_angle = angle;
  if (angle == 90 || angle == 270) { uint32_t w = m->width; m->width = m->height; m->height = w; }
  return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapNative_ApplyFlip(OH_PixelmapNative *m, bool h, bool v) {
  ENTER(OH_PixelmapNative_ApplyFlip, m, FX_MAP); FX_REQUIRE(m->role == FX_WORK && (h || v)); ++stats.flips; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapNative_ApplyScaleWithAntiAliasing(OH_PixelmapNative *m, float x, float y, OH_PixelmapNative_AntiAliasingLevel level) {
  ENTER(OH_PixelmapNative_ApplyScaleWithAntiAliasing, m, FX_MAP);
  FX_REQUIRE(m->role == FX_WORK && x > 0 && x < 1 && x == y && level == OH_PixelmapNative_AntiAliasing_HIGH);
  ++stats.scales; stats.last_scale_x = x; stats.last_scale_y = y;
  trace_event("scale", "HIGH-half", m->o.id, m->width, m->height);
  m->width = (uint32_t)(m->width * x); m->height = (uint32_t)(m->height * y);
  FX_REQUIRE(m->width && m->height); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapNative_Destroy(OH_PixelmapNative **out) {
  FX_REQUIRE(out && *out); OH_PixelmapNative *m = *out; ENTER(OH_PixelmapNative_Destroy, m, FX_MAP);
  valid(&m->source->o, FX_SOURCE);
  if (m->role == FX_BASE) {
    ++stats.base_destroy_attempts;
    if (config.fail_base_destroy) return IMAGE_BAD_PARAMETER;
  }
  for (unsigned i = 0; i < color_used; ++i) if (colors[i].live && colors[i].map == m) {
    FX_REQUIRE(colors[i].borrowed); colors[i].live = false;
    trace_event("release", "color-handle", colors[i].id, 7, 0);
  }
  drop(&m->o, FX_MAP); *out = NULL; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapImageInfo_Create(OH_Pixelmap_ImageInfo **out) {
  call("OH_PixelmapImageInfo_Create", 0, 0, 0); FX_REQUIRE(out && !*out); *out = NEW(pixel_infos, pixel_info_used, FX_PIXEL_INFO); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapImageInfo_Release(OH_Pixelmap_ImageInfo *i) {
  ENTER(OH_PixelmapImageInfo_Release, i, FX_PIXEL_INFO); drop(&i->o, FX_PIXEL_INFO); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapNative_GetImageInfo(OH_PixelmapNative *m, OH_Pixelmap_ImageInfo *i) {
  ENTER(OH_PixelmapNative_GetImageInfo, m, FX_MAP); valid(&i->o, FX_PIXEL_INFO); valid(&m->source->o, FX_SOURCE);
  i->width = m->width; i->height = m->height; i->format = m->format; i->alpha = m->alpha; i->hdr = m->hdr; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapImageInfo_GetWidth(OH_Pixelmap_ImageInfo *i, uint32_t *v) {
  ENTER(OH_PixelmapImageInfo_GetWidth, i, FX_PIXEL_INFO); *v = i->width; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapImageInfo_GetHeight(OH_Pixelmap_ImageInfo *i, uint32_t *v) {
  ENTER(OH_PixelmapImageInfo_GetHeight, i, FX_PIXEL_INFO); *v = i->height; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapImageInfo_GetPixelFormat(OH_Pixelmap_ImageInfo *i, int32_t *v) {
  ENTER(OH_PixelmapImageInfo_GetPixelFormat, i, FX_PIXEL_INFO); *v = i->format; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapImageInfo_GetAlphaMode(OH_Pixelmap_ImageInfo *i, int32_t *v) {
  ENTER(OH_PixelmapImageInfo_GetAlphaMode, i, FX_PIXEL_INFO); *v = i->alpha; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapImageInfo_GetDynamicRange(OH_Pixelmap_ImageInfo *i, bool *v) {
  ENTER(OH_PixelmapImageInfo_GetDynamicRange, i, FX_PIXEL_INFO); *v = i->hdr; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapNative_GetAllocationByteCount(OH_PixelmapNative *m, uint32_t *v) {
  ENTER(OH_PixelmapNative_GetAllocationByteCount, m, FX_MAP);
  *v = m->width * m->height * (m->format == PIXEL_FORMAT_RGB_888 ? 3u : 4u); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PixelmapNative_GetColorSpaceNative(OH_PixelmapNative *m, OH_NativeColorSpaceManager **out) {
  ENTER(OH_PixelmapNative_GetColorSpaceNative, m, FX_MAP); FX_REQUIRE(out && !*out); ++stats.color_gets;
  if (m->role == FX_VERIFY && config.output_color_error) return config.output_color_error;
  FX_REQUIRE(color_used < POOL);
  OH_NativeColorSpaceManager *c = &colors[color_used++];
  *c = (OH_NativeColorSpaceManager){++next_id, true, !DSH_IMAGE_DESTROY_COLORSPACE_GETTER, m->color, m};
  *out = c; pending_color = c; color_phase = 1;
  trace_event("create", "color-handle", c->id, 7, 0); return IMAGE_SUCCESS;
}
int OH_NativeColorSpaceManager_GetColorSpaceName(OH_NativeColorSpaceManager *c) {
  FX_REQUIRE(c && c->live && c == pending_color && color_phase == 1);
  call("OH_NativeColorSpaceManager_GetColorSpaceName", c->id, 0, 0); ++stats.color_names;
#if DSH_IMAGE_DESTROY_COLORSPACE_GETTER
  color_phase = 2;
#else
  color_phase = 0; pending_color = NULL;
#endif
  return c->name;
}
void OH_NativeColorSpaceManager_Destroy(OH_NativeColorSpaceManager *c) {
  FX_REQUIRE(c && c->live && !c->borrowed && c == pending_color && color_phase == 2);
  call("OH_NativeColorSpaceManager_Destroy", c->id, 0, 0); ++stats.color_destroys;
  c->live = false; pending_color = NULL; color_phase = 0;
  trace_event("release", "color-handle", c->id, 7, 0);
}

Image_ErrorCode OH_ImagePackerNative_Create(OH_ImagePackerNative **out) {
  call("OH_ImagePackerNative_Create", 0, 0, 0); FX_REQUIRE(out && !*out); *out = NEW(packers, packer_used, FX_PACKER); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_ImagePackerNative_Release(OH_ImagePackerNative *p) {
  ENTER(OH_ImagePackerNative_Release, p, FX_PACKER); drop(&p->o, FX_PACKER); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PackingOptions_Create(OH_PackingOptions **out) {
  call("OH_PackingOptions_Create", 0, 0, 0); FX_REQUIRE(out && !*out); *out = NEW(packings, packing_used, FX_PACKING); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PackingOptions_Release(OH_PackingOptions *o) {
  ENTER(OH_PackingOptions_Release, o, FX_PACKING);
  for (unsigned i = 0; i < packer_used; ++i) FX_REQUIRE(!packers[i].o.live || packers[i].last_options != o);
  drop(&o->o, FX_PACKING); return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PackingOptions_SetMimeType(OH_PackingOptions *o, Image_MimeType *v) {
  ENTER(OH_PackingOptions_SetMimeType, o, FX_PACKING); FX_REQUIRE(v && v->data && v->size == 10);
  if (memcmp(v->data, "image/jpeg", 10) == 0) o->format = DSH_IMAGE_CODEC_FORMAT_JPEG;
  else { FX_REQUIRE(memcmp(v->data, "image/webp", 10) == 0); o->format = DSH_IMAGE_CODEC_FORMAT_WEBP; }
  o->mask |= 1; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PackingOptions_SetQuality(OH_PackingOptions *o, uint32_t v) {
  ENTER(OH_PackingOptions_SetQuality, o, FX_PACKING); FX_REQUIRE(v == 85 || v == 75 || v == 60); o->quality = v; o->mask |= 2; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PackingOptions_SetNeedsPackProperties(OH_PackingOptions *o, bool v) {
  ENTER(OH_PackingOptions_SetNeedsPackProperties, o, FX_PACKING); o->properties = v; o->mask |= 4; return IMAGE_SUCCESS;
}
Image_ErrorCode OH_PackingOptions_SetDesiredDynamicRange(OH_PackingOptions *o, int32_t v) {
  ENTER(OH_PackingOptions_SetDesiredDynamicRange, o, FX_PACKING); o->range = v; o->mask |= 8; return IMAGE_SUCCESS;
}
static void be16(uint8_t *p, unsigned x) { p[0] = (uint8_t)(x >> 8); p[1] = (uint8_t)x; }
static void le16(uint8_t *p, unsigned x) { p[0] = (uint8_t)x; p[1] = (uint8_t)(x >> 8); }
static void le32(uint8_t *p, size_t x) { for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(x >> (8 * i)); }
static void jpeg_packet(uint8_t *p, size_t size, uint32_t w, uint32_t h, uint32_t quality) {
  /* Strict marker subset, deliberately no DCT/entropy encoding claim. */
  size_t n = 0; FX_REQUIRE(size >= 180 && size <= 1024);
  p[n++] = 0xff; p[n++] = 0xd8;
  p[n++] = 0xff; p[n++] = 0xe0; be16(p + n, 16); n += 2;
  static const uint8_t jfif[14] = {'J','F','I','F',0,1,1,0,0,1,0,1,0,0};
  memcpy(p + n, jfif, sizeof(jfif)); n += sizeof(jfif);
  p[n++] = 0xff; p[n++] = 0xdb; be16(p + n, 67); n += 2; p[n++] = 0;
  memset(p + n, 1, 64); n += 64;
  p[n++] = 0xff; p[n++] = 0xc0; be16(p + n, 17); n += 2;
  p[n++] = 8; be16(p + n, h); n += 2; be16(p + n, w); n += 2; p[n++] = 3;
  for (unsigned i = 1; i <= 3; ++i) { p[n++] = (uint8_t)i; p[n++] = 0x11; p[n++] = 0; }
  p[n++] = 0xff; p[n++] = 0xc4; be16(p + n, 38); n += 2;
  for (unsigned cls = 0; cls < 2; ++cls) {
    p[n++] = (uint8_t)(cls << 4); p[n++] = 1; memset(p + n, 0, 15); n += 15; p[n++] = 0;
  }
  p[n++] = 0xff; p[n++] = 0xda; be16(p + n, 12); n += 2; p[n++] = 3;
  for (unsigned i = 1; i <= 3; ++i) { p[n++] = (uint8_t)i; p[n++] = 0; }
  p[n++] = 0; p[n++] = 63; p[n++] = 0;
  FX_REQUIRE(n + 3 <= size); memset(p + n, 0x11, size - n - 2); p[n] = (uint8_t)quality;
  p[size - 2] = 0xff; p[size - 1] = 0xd9;
}
static void webp_packet(uint8_t *p, size_t size, uint32_t w, uint32_t h,
                        uint32_t quality, bool alpha) {
  /* Complete structural RIFF, not a real entropy encoder. Alpha planes are
   * carrier data. Real decoding, color conversion and compression stay untested. */
  FX_REQUIRE(size >= 120 && size <= 1024 && !(size & 1));
  memset(p, 0, size); memcpy(p, "RIFF", 4); le32(p + 4, size - 8);
  memcpy(p + 8, "WEBP", 4); size_t n = 12;
  if (alpha) {
    memcpy(p + n, "VP8X", 4); le32(p + n + 4, 10); n += 8;
    p[n] = 0x10; le32(p + n + 4, w - 1); p[n + 7] = (uint8_t)(h - 1);
    n += 10;
    memcpy(p + n, "ALPH", 4); size_t count = (size_t)w * h + 1;
    le32(p + n + 4, count); n += 8; p[n++] = 0;
    for (size_t i = 0; i < count - 1; ++i) p[n++] = (uint8_t)((i % 3) * 127);
    if (count & 1) p[n++] = 0;
  }
  FX_REQUIRE(n + 19 <= size); memcpy(p + n, "VP8 ", 4); le32(p + n + 4, size - n - 8); n += 8;
  memset(p + n, 0x35, size - n); p[n] = 0x30; p[n + 1] = p[n + 2] = 0;
  p[n + 3] = 0x9d; p[n + 4] = 1; p[n + 5] = 0x2a;
  le16(p + n + 6, w); le16(p + n + 8, h); p[size - 1] = (uint8_t)quality;
}
Image_ErrorCode OH_ImagePackerNative_PackToDataFromPixelmap(OH_ImagePackerNative *p, OH_PackingOptions *o,
    OH_PixelmapNative *m, uint8_t *data, size_t *size) {
  ENTER(OH_ImagePackerNative_PackToDataFromPixelmap, p, FX_PACKER); valid(&o->o, FX_PACKING); valid(&m->o, FX_MAP);
  FX_REQUIRE(m->role == FX_WORK && data && size && *size == DSH_IMAGE_ENCODE_CAP && stats.packs < 16);
  FX_REQUIRE(o->mask == 15 && !o->properties && o->range == IMAGE_PACKER_DYNAMIC_RANGE_SDR);
  p->last_options = o;
  unsigned call_index = stats.packs++; stats.qualities[call_index] = o->quality; stats.capacities[call_index] = *size;
  if (config.pack_error_call == stats.packs) {
    /* Failure outputs are unspecified. This ordinary error deliberately gives
     * a meaningless size; the observable oracle demands original error/no retry. */
    *size = SIZE_MAX; data[0] = 0; return config.pack_error;
  }
  unsigned qi = o->quality == 85 ? 0 : o->quality == 75 ? 1 : 2;
  size_t produced = config.pack_sizes[qi];
  if (o->format == DSH_IMAGE_CODEC_FORMAT_JPEG) jpeg_packet(data, produced, m->width, m->height, o->quality);
  else webp_packet(data, produced, m->width, m->height, o->quality, m->alpha != PIXELMAP_ALPHA_TYPE_OPAQUE);
  if (config.truncate_packed_output) --produced;
  FX_REQUIRE(receipt_used < RECEIPTS);
  Receipt *receipt = &receipts[receipt_used++];
  FX_REQUIRE(produced <= sizeof(receipt->data));
  memcpy(receipt->data, data, produced); receipt->size = produced;
  receipt->width = m->width; receipt->height = m->height; receipt->format = o->format; receipt->alpha = m->alpha;
  trace_event("pack", o->format == DSH_IMAGE_CODEC_FORMAT_JPEG ? "jpeg" : "webp", m->o.id, o->quality, produced);
  *size = produced; return IMAGE_SUCCESS;
}
