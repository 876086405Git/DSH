#ifndef DSH_IMAGE_CODEC_FAKE_H
#define DSH_IMAGE_CODEC_FAKE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  uint32_t opens, closes, active, encodes, overlaps;
  uint32_t outputs, released_outputs, input_mismatches;
  uint32_t cleanup_starts;
} DshImageFakeStats;
void dsh_image_fake_stats(DshImageFakeStats*);
void dsh_image_fake_hold_encodes(uint32_t);
void dsh_image_fake_cleanup_started(void);
#ifdef __cplusplus
}
#endif
#endif
