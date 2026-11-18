/* Direct tests of the unchanged production C backend linked to SDK fakes.
 * This is neither a replacement DshImageBackend nor a real codec/device test. */
#include "image-ndk-host.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const DshImageBackend *backend;
static unsigned passed;
static const DshImageLimits limits = {sizeof(DshImageLimits), 32, 1024};

static void pass(const char *name) {
  const FxStats *s = image_ndk_fixture_stats();
  printf("PASS %s\n", name);
  printf("OBS {\"case\":\"%s\",\"sdkCalls\":%u,\"sourceDecodes\":%u,\"verifyDecodes\":%u,"
      "\"clones\":%u,\"rotations\":%u,\"scales\":%u,\"packs\":%u,"
      "\"baseOptions\":%u,\"verificationOptions\":%u,\"colorGets\":%u,"
      "\"colorNames\":%u,\"colorDestroys\":%u,\"sourceInputChecks\":%u,\"qualities\":[",
      name, s->sdk_calls, s->source_decodes, s->verification_decodes, s->clones,
      s->rotations, s->scales, s->packs, s->base_options, s->verification_options,
      s->color_gets, s->color_names, s->color_destroys, s->source_input_checks);
  for (unsigned i = 0; i < s->packs; ++i) printf("%s%u", i ? "," : "", s->qualities[i]);
  printf("],\"capacities\":[");
  for (unsigned i = 0; i < s->packs; ++i) printf("%s%zu", i ? "," : "", s->capacities[i]);
  printf("],\"liveFakeObjects\":[");
  for (unsigned i = 0; i < FX_KIND_COUNT; ++i) printf("%s%u", i ? "," : "", s->live[i]);
  printf("]}\n"); ++passed;
}
static FxConfig webp_config(void) {
  FxConfig c = image_ndk_fixture_defaults();
  c.pack_sizes[0] = 160; c.pack_sizes[1] = 120; c.pack_sizes[2] = 80; return c;
}
static DshImageTarget target(uint32_t w, uint32_t h, uint32_t format, uint64_t soft) {
  return (DshImageTarget){sizeof(DshImageTarget), w, h, format, soft};
}
static void error_is(DshImageStatus got, DshImageError e, DshImageStatus expected,
                     const char *stage, int32_t raw) {
  FX_REQUIRE(got == expected && e.stage && strcmp(e.stage, stage) == 0 && e.native_status == raw);
}
static void output_empty(const DshImageEncoded *o) {
  FX_REQUIRE(!o->data && !o->size && !o->capacity && !o->quality && !o->format);
}
static void close_ok(DshImageFrame **f) {
  DshImageError e = {0}; FX_REQUIRE(*f && backend->close(f, &e) == DSH_IMAGE_OK && !*f);
  unsigned calls = image_ndk_fixture_stats()->sdk_calls;
  FX_REQUIRE(backend->close(f, &e) == DSH_IMAGE_OK && !*f);
  FX_REQUIRE(image_ndk_fixture_stats()->sdk_calls == calls);
  image_ndk_fixture_check_normal_end();
}
static DshImageFrame *open_ok(bool exif, DshImageFacts *source, DshImageFacts *working) {
  DshImageFrame *f = NULL; DshImageError e = {0};
  const uint8_t *bytes = exif ? image_ndk_exif6_png : image_ndk_rgb_png;
  size_t length = exif ? image_ndk_exif6_png_size : image_ndk_rgb_png_size;
  FX_REQUIRE(backend->open(bytes, length, &limits, &f, source, working, &e) == DSH_IMAGE_OK && f);
  FX_REQUIRE(source->width == 6 && source->height == 4 && source->frame_count == 1);
  FX_REQUIRE(source->format == DSH_IMAGE_CODEC_FORMAT_PNG && source->orientation == (exif ? 6u : 1u));
  FX_REQUIRE((source->known & DSH_IMAGE_FACT_ALPHA) && !source->has_alpha);
  FX_REQUIRE((source->known & DSH_IMAGE_FACT_DEPTH) && source->bit_depth == 8);
  FX_REQUIRE((source->known & DSH_IMAGE_FACT_METADATA) && source->retained_metadata == (unsigned)exif);
  FX_REQUIRE(!(source->known & DSH_IMAGE_FACT_COLOR));
  FX_REQUIRE(working->width == 6 && working->height == 4 && working->color_space == DSH_IMAGE_COLOR_SRGB);
  FX_REQUIRE(working->known & DSH_IMAGE_FACT_COLOR);
  return f;
}
static void encoded_is(const DshImageEncoded *o, uint32_t w, uint32_t h,
                       uint32_t format, uint32_t quality, size_t size, size_t capacity) {
  const uint32_t known = DSH_IMAGE_FACT_DIMENSIONS | DSH_IMAGE_FACT_FORMAT | DSH_IMAGE_FACT_FRAMES |
      DSH_IMAGE_FACT_ORIENTATION | DSH_IMAGE_FACT_ALPHA | DSH_IMAGE_FACT_DEPTH |
      DSH_IMAGE_FACT_COLOR | DSH_IMAGE_FACT_METADATA | DSH_IMAGE_FACT_ALLOCATION;
  FX_REQUIRE(o->data && o->size == size && o->capacity == capacity);
  FX_REQUIRE(o->format == format && o->quality == quality && (o->facts.known & known) == known);
  FX_REQUIRE(o->facts.width == w && o->facts.height == h && o->facts.frame_count == 1);
  FX_REQUIRE(o->facts.orientation == 1 && !o->facts.retained_metadata && !o->facts.has_alpha);
  FX_REQUIRE(o->facts.bit_depth == 8 && o->facts.color_space == DSH_IMAGE_COLOR_SRGB);
  FX_REQUIRE(o->facts.allocation_bytes == (uint64_t)w * h * 3);
  const FxStats *s = image_ndk_fixture_stats();
  FX_REQUIRE(s->output_sources == s->output_source_releases && s->verification_options == FX_INDEX);
  FX_REQUIRE(s->live[FX_SOURCE] == 1 && s->live[FX_MAP] == 1);
  for (unsigned k = 0; k < FX_KIND_COUNT; ++k)
    if (k != FX_SOURCE && k != FX_MAP) FX_REQUIRE(s->live[k] == 0);
}
static void release_output(DshImageEncoded *o) { backend->release_encoded(o); output_empty(o); }

static void inspect_without_sdk(void) {
  image_ndk_fixture_reset(image_ndk_fixture_defaults()); DshImageFacts f = {0}; DshImageError e = {0};
  FX_REQUIRE(backend->inspect(image_ndk_rgb_png, image_ndk_rgb_png_size, &f, &e) == DSH_IMAGE_OK);
  FX_REQUIRE(f.width == 6 && f.height == 4 && f.orientation == 1 && !f.has_alpha && !f.retained_metadata);
  FX_REQUIRE(!(f.known & DSH_IMAGE_FACT_COLOR));
  FX_REQUIRE(backend->inspect(image_ndk_exif6_png, image_ndk_exif6_png_size, &f, &e) == DSH_IMAGE_OK);
  FX_REQUIRE(f.orientation == 6 && f.retained_metadata == 1);
  FX_REQUIRE(image_ndk_fixture_stats()->sdk_calls == 0); image_ndk_fixture_check_normal_end();
  pass("inspect-complete-containers-with-zero-sdk-calls");
}
static void open_facts(void) {
  image_ndk_fixture_reset(image_ndk_fixture_defaults()); DshImageFacts s = {0}, w = {0};
  DshImageFrame *f = open_ok(false, &s, &w);
  FX_REQUIRE(image_ndk_fixture_stats()->base_options == (FX_INDEX | FX_ROTATE | FX_FORMAT | FX_RANGE | FX_COLOR));
  FX_REQUIRE(w.allocation_bytes == 96 && !(w.known & DSH_IMAGE_FACT_METADATA));
  close_ok(&f); pass("source-unknown-color-is-not-replaced-by-working-facts");
}
static void limits_before_sdk(void) {
  image_ndk_fixture_reset(image_ndk_fixture_defaults()); DshImageFacts s = {0}, w = {0};
  DshImageFrame *f = NULL; DshImageError e = {0}; DshImageLimits l = limits; l.max_side = 5;
  DshImageStatus r = backend->open(image_ndk_rgb_png, image_ndk_rgb_png_size, &l, &f, &s, &w, &e);
  error_is(r, e, DSH_IMAGE_EDGE_LIMIT, "source-edge-limit", 0);
  FX_REQUIRE(!f); l = limits; l.max_pixels = 23; memset(&e, 0, sizeof(e));
  r = backend->open(image_ndk_rgb_png, image_ndk_rgb_png_size, &l, &f, &s, &w, &e);
  error_is(r, e, DSH_IMAGE_PIXEL_LIMIT, "source-pixel-limit", 0);
  FX_REQUIRE(!f && image_ndk_fixture_stats()->sdk_calls == 0); image_ndk_fixture_check_normal_end();
  pass("source-side-and-pixel-budgets-before-sdk-creation");
}
static void targets_from_base(void) {
  image_ndk_fixture_reset(webp_config()); DshImageFacts s = {0}, w = {0}; DshImageError e = {0};
  DshImageFrame *f = open_ok(true, &s, &w); DshImageEncoded a = {0}, b = {0};
  DshImageTarget t = target(2, 3, DSH_IMAGE_CODEC_FORMAT_WEBP, 1024);
  FX_REQUIRE(backend->encode(f, &t, &a, &e) == DSH_IMAGE_OK); encoded_is(&a, 2, 3, t.format, 85, 160, DSH_IMAGE_ENCODE_CAP);
  release_output(&a); t = target(100, 100, DSH_IMAGE_CODEC_FORMAT_WEBP, 1024);
  FX_REQUIRE(backend->encode(f, &t, &b, &e) == DSH_IMAGE_OK); encoded_is(&b, 4, 6, t.format, 85, 160, DSH_IMAGE_ENCODE_CAP);
  const FxStats *st = image_ndk_fixture_stats();
  FX_REQUIRE(st->clones == 2 && st->rotations == 2 && st->flips == 0 && st->scales == 1);
  FX_REQUIRE(st->last_angle == 90 && st->last_scale_x == 0.5f && st->last_scale_y == 0.5f);
  FX_REQUIRE(st->clone_parent[0] == st->last_base_id && st->clone_parent[1] == st->last_base_id);
  FX_REQUIRE(st->clone_width[0] == 6 && st->clone_height[0] == 4 && st->clone_width[1] == 6 && st->clone_height[1] == 4);
  release_output(&b); close_ok(&f); pass("two-targets-clone-base-orient-fit-inside-and-never-upscale");
}
static void jpeg_first_fit(void) {
  image_ndk_fixture_reset(image_ndk_fixture_defaults()); DshImageFacts s = {0}, w = {0}; DshImageError e = {0};
  DshImageFrame *f = open_ok(false, &s, &w); DshImageEncoded o = {0};
  DshImageTarget t = target(6, 4, DSH_IMAGE_CODEC_FORMAT_JPEG, 1024);
  FX_REQUIRE(backend->encode(f, &t, &o, &e) == DSH_IMAGE_OK); encoded_is(&o, 6, 4, t.format, 85, 240, DSH_IMAGE_ENCODE_CAP);
  FX_REQUIRE(image_ndk_fixture_stats()->packs == 1);
  uint8_t copy[240]; memcpy(copy, o.data, sizeof(copy)); close_ok(&f);
  FX_REQUIRE(memcmp(copy, o.data, sizeof(copy)) == 0); release_output(&o);
  pass("jpeg-first-quality-fit-and-output-outlives-frame");
}
static void webp_second_fit(void) {
  image_ndk_fixture_reset(webp_config()); DshImageFacts s = {0}, w = {0}; DshImageError e = {0};
  DshImageFrame *f = open_ok(false, &s, &w); DshImageEncoded o = {0}; DshImageTarget t = target(6, 4, DSH_IMAGE_CODEC_FORMAT_WEBP, 130);
  FX_REQUIRE(backend->encode(f, &t, &o, &e) == DSH_IMAGE_OK); encoded_is(&o, 6, 4, t.format, 75, 120, DSH_IMAGE_ENCODE_CAP);
  const FxStats *st = image_ndk_fixture_stats(); FX_REQUIRE(st->packs == 2 && st->qualities[0] == 85 && st->qualities[1] == 75);
  release_output(&o); close_ok(&f); pass("webp-stops-at-first-acceptable-quality");
}
static void smallest_three(void) {
  FxConfig c = webp_config(); c.pack_sizes[1] = 80; c.pack_sizes[2] = 120; image_ndk_fixture_reset(c);
  DshImageFacts s = {0}, w = {0}; DshImageError e = {0}; DshImageFrame *f = open_ok(false, &s, &w);
  DshImageEncoded o = {0}; DshImageTarget t = target(6, 4, DSH_IMAGE_CODEC_FORMAT_WEBP, 1);
  FX_REQUIRE(backend->encode(f, &t, &o, &e) == DSH_IMAGE_OK); encoded_is(&o, 6, 4, t.format, 75, 80, 80);
  const FxStats *st = image_ndk_fixture_stats(); FX_REQUIRE(st->packs == 3 && st->qualities[0] == 85 && st->qualities[1] == 75 && st->qualities[2] == 60);
  for (unsigned i = 0; i < 3; ++i) FX_REQUIRE(st->capacities[i] == DSH_IMAGE_ENCODE_CAP);
  release_output(&o); close_ok(&f); pass("three-qualities-select-smallest-success-with-fixed-capacity");
}
static void pack_failure(void) {
  FxConfig c = webp_config(); c.pack_error_call = 2; image_ndk_fixture_reset(c);
  DshImageFacts s = {0}, w = {0}; DshImageError e = {0}; DshImageFrame *f = open_ok(false, &s, &w);
  DshImageEncoded o = {0}; DshImageTarget t = target(6, 4, DSH_IMAGE_CODEC_FORMAT_WEBP, 1);
  DshImageStatus r = backend->encode(f, &t, &o, &e);
  error_is(r, e, DSH_IMAGE_ENCODE_FAILED, "pack-data", IMAGE_TOO_LARGE); output_empty(&o);
  const FxStats *st = image_ndk_fixture_stats(); FX_REQUIRE(st->packs == 2 && st->output_sources == 0 && st->verification_decodes == 0);
  FX_REQUIRE(st->qualities[0] == 85 && st->qualities[1] == 75 && st->capacities[1] == DSH_IMAGE_ENCODE_CAP);
  close_ok(&f); pass("failed-pack-does-not-retry-or-publish-prior-best");
}
static void base_actual_not_requested(void) {
  FxConfig c = webp_config(); c.base_color = DISPLAY_P3; image_ndk_fixture_reset(c);
  DshImageFacts s = {0}, w = {0}; DshImageError e = {0}; DshImageFrame *f = NULL;
  DshImageStatus r = backend->open(image_ndk_rgb_png, image_ndk_rgb_png_size, &limits, &f, &s, &w, &e);
  error_is(r, e, DSH_IMAGE_TRANSFORM_FAILED, "pixel-not-srgb", 0);
  FX_REQUIRE(f && image_ndk_fixture_stats()->source_decodes == 1);
  close_ok(&f); pass("requested-srgb-does-not-override-actual-base-color");
}
static void output_failure(FxConfig c, DshImageStatus expected, const char *stage, int32_t raw, const char *name) {
  image_ndk_fixture_reset(c); DshImageFacts s = {0}, w = {0}; DshImageError e = {0};
  DshImageFrame *f = open_ok(false, &s, &w); DshImageEncoded o = {0}; DshImageTarget t = target(6, 4, DSH_IMAGE_CODEC_FORMAT_WEBP, 1024);
  DshImageStatus r = backend->encode(f, &t, &o, &e); error_is(r, e, expected, stage, raw); output_empty(&o);
  const FxStats *st = image_ndk_fixture_stats();
  if (!c.truncate_packed_output) FX_REQUIRE(st->verification_options == FX_INDEX);
  else FX_REQUIRE(st->output_sources == 0 && st->verification_decodes == 0);
  close_ok(&f); pass(name);
}
static void failed_open_owner(void) {
  FxConfig c = webp_config(); c.base_decode_error = IMAGE_GET_IMAGE_DATA_FAILED; image_ndk_fixture_reset(c);
  uint8_t *bytes = malloc(image_ndk_rgb_png_size); FX_REQUIRE(bytes); memcpy(bytes, image_ndk_rgb_png, image_ndk_rgb_png_size);
  DshImageFacts s = {0}, w = {0}; DshImageError e = {0}; DshImageFrame *f = NULL;
  DshImageStatus r = backend->open(bytes, image_ndk_rgb_png_size, &limits, &f, &s, &w, &e);
  error_is(r, e, DSH_IMAGE_INVALID, "source-decode", IMAGE_GET_IMAGE_DATA_FAILED);
  const FxStats *st = image_ndk_fixture_stats();
  FX_REQUIRE(f && st->live[FX_SOURCE] == 1 && st->live[FX_DECODING] == 1 && st->live[FX_MAP] == 0);
  FX_REQUIRE(memcmp(bytes, image_ndk_rgb_png, image_ndk_rgb_png_size) == 0);
  close_ok(&f); FX_REQUIRE(memcmp(bytes, image_ndk_rgb_png, image_ndk_rgb_png_size) == 0); free(bytes);
  pass("failed-open-retains-owner-and-borrowed-input-until-close");
}
static void normal(void) {
  inspect_without_sdk(); open_facts(); limits_before_sdk(); targets_from_base();
  jpeg_first_fit(); webp_second_fit(); smallest_three(); pack_failure(); base_actual_not_requested();
  FxConfig c = webp_config(); c.output_color = DISPLAY_P3;
  output_failure(c, DSH_IMAGE_ENCODE_FAILED, "pixel-not-srgb", 0, "output-actual-color-mismatch-is-encode-failure");
  c = webp_config(); c.output_decode_error = IMAGE_GET_IMAGE_DATA_FAILED;
  output_failure(c, DSH_IMAGE_INVALID, "output-decode", IMAGE_GET_IMAGE_DATA_FAILED, "output-full-decode-error-is-invalid");
  c = webp_config(); c.output_color_error = IMAGE_UNSUPPORTED_OPERATION;
  output_failure(c, DSH_IMAGE_UNAVAILABLE, "color-getter", IMAGE_UNSUPPORTED_OPERATION, "output-getter-capability-error-is-unavailable");
  c = webp_config(); c.truncate_packed_output = true;
  output_failure(c, DSH_IMAGE_INVALID, "output-container-scan", 0, "truncated-owned-output-is-rejected-before-sdk-decode");
  c = webp_config(); c.output_alpha = PIXELMAP_ALPHA_TYPE_UNPREMULTIPLIED;
  output_failure(c, DSH_IMAGE_ENCODE_FAILED, "output-pixel-disagreement", 0, "output-alpha-is-an-observed-fact-not-an-option");
  failed_open_owner(); FX_REQUIRE(passed == 15);
}
static void unconfirmed(void) {
  FxConfig c = webp_config(); c.fail_base_destroy = true; image_ndk_fixture_reset(c);
  DshImageFacts s = {0}, w = {0}; DshImageError e = {0}; DshImageFrame *f = open_ok(false, &s, &w);
  DshImageFrame *retained = f; DshImageStatus r = backend->close(&f, &e);
  error_is(r, e, DSH_IMAGE_CLEANUP_UNCONFIRMED, "OH_PixelmapNative_Destroy:base", IMAGE_BAD_PARAMETER);
  FX_REQUIRE(f == retained); unsigned calls = image_ndk_fixture_stats()->sdk_calls;
  r = backend->close(&f, &e);
  error_is(r, e, DSH_IMAGE_CLEANUP_UNCONFIRMED, "OH_PixelmapNative_Destroy:base", IMAGE_BAD_PARAMETER);
  const FxStats *st = image_ndk_fixture_stats();
  FX_REQUIRE(f == retained && st->sdk_calls == calls && st->base_destroy_attempts == 1);
  FX_REQUIRE(st->live[FX_SOURCE] == 1 && st->live[FX_MAP] == 1 && st->bad_releases == 0);
  /* Do not free retained owner or source to manufacture a zero-leak result.
   * The planned separate process ends with the unconfirmed objects present. */
  pass("cleanup-unconfirmed-retains-owner-and-never-retries-release");
  FX_REQUIRE(passed == 1);
}
int main(int argc, char **argv) {
  if (argc != 2 || (strcmp(argv[1], "normal") && strcmp(argv[1], "cleanup-unconfirmed"))) {
    fprintf(stderr, "usage: image-ndk-contract normal|cleanup-unconfirmed\n"); return 64;
  }
  backend = dsh_image_codec_backend_v1();
  FX_REQUIRE(backend && backend->abi == DSH_IMAGE_CODEC_ABI && backend->struct_size == sizeof(*backend) && !backend->fixture_only);
  FX_REQUIRE(backend->color_getter_policy == (DSH_IMAGE_DESTROY_COLORSPACE_GETTER ? DSH_IMAGE_GETTER_DESTROY : DSH_IMAGE_GETTER_BORROW));
  FX_REQUIRE(strstr(backend->build_id, DSH_IMAGE_DESTROY_COLORSPACE_GETTER ? "getcolor=destroy" : "getcolor=borrow"));
  if (!strcmp(argv[1], "normal")) normal(); else unconfirmed();
  printf("SUMMARY cases=%u failed=0 sdk=fake pixels=fake real_backend=codec_ndk color_getter_policy=%s\n",
      passed, DSH_IMAGE_DESTROY_COLORSPACE_GETTER ? "destroy" : "borrow");
  return 0;
}
