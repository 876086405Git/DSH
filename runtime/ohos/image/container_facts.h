/* Private OH image container facts. No pixel decoding, SDK or Node types. */
#ifndef DSH_OHOS_IMAGE_CONTAINER_FACTS_H
#define DSH_OHOS_IMAGE_CONTAINER_FACTS_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DSH_IMAGE_SCAN_OK = 0,
    DSH_IMAGE_SCAN_UNRECOGNIZED,
    DSH_IMAGE_SCAN_TRUNCATED,
    DSH_IMAGE_SCAN_INVALID,
    DSH_IMAGE_SCAN_UNSUPPORTED
} DshImageScanStatus;

typedef enum {
    DSH_IMAGE_FORMAT_UNKNOWN = 0, DSH_IMAGE_PNG, DSH_IMAGE_JPEG,
    DSH_IMAGE_WEBP, DSH_IMAGE_GIF
} DshImageFormat;

enum {
    DSH_IMAGE_K_DIMENSIONS = 1u << 0,
    DSH_IMAGE_K_ALPHA = 1u << 1,
    DSH_IMAGE_K_SAMPLE_BITS = 1u << 2,
    DSH_IMAGE_K_SPACE = 1u << 3,
    DSH_IMAGE_K_METADATA = 1u << 4,
    DSH_IMAGE_K_ORIENTATION = 1u << 5,
    DSH_IMAGE_K_FRAMES = 1u << 6
};
enum {
    DSH_IMAGE_W_EXTENSION = 1u << 0,
    DSH_IMAGE_W_EXIF = 1u << 1,
    DSH_IMAGE_W_ALPHA_HINT = 1u << 2,
    DSH_IMAGE_W_FRAME_SCOPE = 1u << 3
};
enum { DSH_IMAGE_SPACE_UNKNOWN = 0, DSH_IMAGE_SPACE_SRGB_CONVENTION = 1 };

typedef struct {
    DshImageFormat format;
    uint32_t known;
    uint32_t warnings;
    uint32_t width, height, frames;
    uint8_t sample_bits; /* Encoded sample precision; palette RGB is 8-bit. */
    uint8_t alpha;       /* Declared alpha/transparency capability, not pixel values. */
    uint8_t space;       /* A container convention, never a measured conversion. */
    uint8_t metadata;
    uint8_t orientation; /* 1..8; known bit required, including proven default 1. */
    uint8_t complete;
    uint8_t output_subset;
} DshImageContainerFacts;

/*
 * Caller owns an immutable, already size-admitted buffer for this call.
 * No allocation, recursion, I/O, retained pointers or pixel/profile decompression.
 * Work is linear in buffer length; Exif only visits bounded IFD0 entries.
 * On non-OK all facts are reset (including known, complete, output_subset).
 * On OK only fields with a known bit may be consumed; zero is not "known false".
 * complete means the supported container structure reaches its exact end.
 * output_subset is ONLY the JPEG/WebP structural allowlist result. It NEVER
 * certifies a decodable image, actual color/alpha, orientation application,
 * memory safety of a codec, or permission to publish. Full NDK decode and the
 * independent output contract remain mandatory. Unknown fields stay unknown.
 * VP8L alpha_is_used is only a hint: alpha remains unknown even with bit 0.
 */
DshImageScanStatus dsh_image_scan_container(const uint8_t *data, size_t length,
                                         DshImageContainerFacts *out);
#ifdef __cplusplus
}
#endif
#endif
