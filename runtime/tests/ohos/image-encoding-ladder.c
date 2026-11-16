#include "encoding_ladder.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "fixture failure: %s\n", message);
    exit(1);
  }
}
struct step { size_t length; int32_t status; };
struct plan { struct step steps[3]; size_t calls; };
static int32_t pack(void *context, uint32_t quality, uint8_t *data, size_t *size) {
  static const uint32_t ordered[] = {85, 75, 60};
  struct plan *p = context;
  require(p->calls < 3, "a quality was retried");
  require(quality == ordered[p->calls], "quality order changed");
  require(*size == DSH_IMAGE_ENCODE_CAPACITY, "capacity not reset to C");
  const struct step step = p->steps[p->calls++];
  *size = step.length;
  if (step.status == 0 && step.length <= DSH_IMAGE_ENCODE_CAPACITY)
    memset(data, (int)quality, step.length);
  return step.status;
}
struct test_case {
  const char *name;
  struct step steps[3];
  size_t soft;
  enum dsh_image_encode_status status;
  size_t calls;
  uint32_t quality;
  size_t length;
  size_t capacity;
  int32_t native_status;
};
int main(void) {
  const struct test_case cases[] = {
    {"first-fit", {{31,0},{17,0},{9,0}},64,DSH_IMAGE_ENCODE_OK,1,85,31,DSH_IMAGE_ENCODE_CAPACITY,0},
    {"second-fit",{{31,0},{17,0},{9,0}},20,DSH_IMAGE_ENCODE_OK,2,75,17,DSH_IMAGE_ENCODE_CAPACITY,0},
    {"smallest-last",{{31,0},{17,0},{9,0}},1,DSH_IMAGE_ENCODE_OK,3,60,9,9,0},
    {"smallest-first",{{9,0},{17,0},{31,0}},1,DSH_IMAGE_ENCODE_OK,3,85,9,9,0},
    {"smallest-middle",{{31,0},{9,0},{17,0}},1,DSH_IMAGE_ENCODE_OK,3,75,9,9,0},
    {"earliest-tie",{{9,0},{9,0},{17,0}},1,DSH_IMAGE_ENCODE_OK,3,85,9,9,0},
    {"first-fails",{{SIZE_MAX,71},{17,0},{9,0}},1,DSH_IMAGE_ENCODE_PACK,1,85,0,0,71},
    {"second-fails-discards-best",{{31,0},{SIZE_MAX,72},{9,0}},1,DSH_IMAGE_ENCODE_PACK,2,75,0,0,72},
    {"third-fails-discards-best",{{31,0},{17,0},{SIZE_MAX,73}},1,DSH_IMAGE_ENCODE_PACK,3,60,0,0,73},
    {"successful-zero-length",{{0,0},{17,0},{9,0}},1,DSH_IMAGE_ENCODE_LENGTH,1,85,0,0,0},
    {"successful-length-over-cap",{{DSH_IMAGE_ENCODE_CAPACITY+1,0},{17,0},{9,0}},1,DSH_IMAGE_ENCODE_LENGTH,1,85,0,0,0},
    {"exact-hard-cap",{{DSH_IMAGE_ENCODE_CAPACITY,0},{17,0},{9,0}},DSH_IMAGE_ENCODE_CAPACITY,DSH_IMAGE_ENCODE_OK,1,85,DSH_IMAGE_ENCODE_CAPACITY,DSH_IMAGE_ENCODE_CAPACITY,0},
    {"zero-soft-target",{{31,0},{17,0},{9,0}},0,DSH_IMAGE_ENCODE_ARGUMENT,0,0,0,0,0}
  };
  for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); ++i) {
    const struct test_case *t = &cases[i];
    struct plan p = {{t->steps[0],t->steps[1],t->steps[2]},0};
    struct dsh_image_encoded_bytes output = {0};
    struct dsh_image_encode_error error = {0};
    const enum dsh_image_encode_status status =
        dsh_image_encode_ladder(pack, &p, t->soft, &output, &error);
    require(status == t->status, t->name);
    require(p.calls == t->calls, "call count");
    if (status == DSH_IMAGE_ENCODE_OK) {
      require(output.data != NULL, "successful bytes missing");
      require(output.length == t->length && output.capacity == t->capacity,
              "successful length/capacity");
      require(output.quality == t->quality, "chosen quality");
      require(error.status == 0 && error.native_status == 0 &&
              error.quality == 0 && error.capacity == 0, "success error state");
      for (size_t j = 0; j < output.length; ++j)
        require(output.data[j] == (uint8_t)t->quality, "chosen bytes changed");
      /* Reusing a still-owned result must reject without replacing its bytes. */
      uint8_t *owned = output.data;
      struct dsh_image_encode_error rejected = {0};
      require(dsh_image_encode_ladder(pack, &p, 1, &output, &rejected) ==
              DSH_IMAGE_ENCODE_ARGUMENT, "nonempty output accepted");
      require(output.data == owned && output.length == t->length &&
              output.quality == t->quality && p.calls == t->calls,
              "rejected call altered owned output or invoked pack");
    } else {
      require(output.data == NULL && output.length == 0 &&
              output.capacity == 0 && output.quality == 0,
              "failure retained a candidate");
      require(error.status == t->status && error.native_status == t->native_status &&
              error.quality == t->quality && error.capacity == DSH_IMAGE_ENCODE_CAPACITY,
              "failure facts");
    }
    dsh_image_encoded_bytes_release(&output);
    dsh_image_encoded_bytes_release(&output);
    require(output.data == NULL && output.length == 0 && output.capacity == 0 &&
            output.quality == 0, "release did not clear result");
    printf("{\"case\":\"%s\",\"status\":\"PASS\",\"packCalls\":%zu}\n",t->name,p.calls);
  }
  puts("{\"scope\":\"host fake packer only; not an image codec\",\"cases\":13,\"status\":\"PASS\"}");
  return 0;
}
