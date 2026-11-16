#ifndef DSH_IMAGE_NDK_HOST_H
#define DSH_IMAGE_NDK_HOST_H
#ifndef DSH_IMAGE_NDK_HOST_FIXTURE
#error "Test-only SDK protocol fixture"
#endif
#include "codec_bridge.h"
#include <multimedia/image_framework/image/image_source_native.h>
#include <multimedia/image_framework/image/image_packer_native.h>
#include <native_color_space_manager/native_color_space_manager.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

enum { FX_SOURCE_WIDTH = 6, FX_SOURCE_HEIGHT = 4, FX_MAX_EVENTS = 2048 };
enum FxKind { FX_SOURCE, FX_SOURCE_INFO, FX_DECODING, FX_MAP, FX_PIXEL_INFO,
              FX_PACKER, FX_PACKING, FX_KIND_COUNT };
enum FxMapRole { FX_BASE = 1, FX_WORK = 2, FX_VERIFY = 3 };
enum FxOption { FX_INDEX = 1, FX_ROTATE = 2, FX_FORMAT = 4, FX_RANGE = 8, FX_COLOR = 16 };
typedef struct {
  size_t pack_sizes[3];
  unsigned pack_error_call;
  Image_ErrorCode pack_error;
  bool truncate_packed_output;
  Image_ErrorCode base_decode_error, output_decode_error, output_color_error;
  int base_color, output_color;
  int32_t base_format, output_format, base_alpha, output_alpha;
  bool base_hdr, output_hdr;
  bool fail_base_destroy;
} FxConfig;
typedef struct { const char *name; unsigned object_id; uint64_t a, b; } FxEvent;
typedef struct {
  unsigned sdk_calls, created[FX_KIND_COUNT], released[FX_KIND_COUNT];
  unsigned live[FX_KIND_COUNT], bad_releases;
  unsigned source_decodes, verification_decodes, output_sources, output_source_releases;
  unsigned clones, rotations, flips, scales, last_base_id;
  unsigned clone_parent[16], clone_width[16], clone_height[16];
  unsigned base_options, verification_options;
  unsigned packs, qualities[16];
  size_t capacities[16];
  unsigned color_gets, color_names, color_destroys;
  unsigned base_destroy_attempts, source_input_checks;
  float last_angle, last_scale_x, last_scale_y;
  unsigned events_count;
  FxEvent events[FX_MAX_EVENTS];
} FxStats;

FxConfig image_ndk_fixture_defaults(void);
void image_ndk_fixture_reset(FxConfig);
const FxStats *image_ndk_fixture_stats(void);
void image_ndk_fixture_check_normal_end(void);
void image_ndk_fixture_require(int, const char *, int);
#define FX_REQUIRE(x) image_ndk_fixture_require(!!(x), #x, __LINE__)

/* Source arrays are real self-generated RGB PNGs. Fake pack output packets
 * are complete structural containers only; the fake decoder invents pixels. */
extern const uint8_t image_ndk_rgb_png[];
extern const size_t image_ndk_rgb_png_size;
extern const uint8_t image_ndk_exif6_png[];
extern const size_t image_ndk_exif6_png_size;
#endif
