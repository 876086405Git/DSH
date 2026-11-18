/* Finite host fixtures for the private container scanner, not codec fixtures.
 * WebP compressed bytes are opaque header fixtures; no pixel decode is claimed.
 * Original test construction; no external implementation or pixel decoder.
 */
#include "container_facts.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { \
    fprintf(stderr, "fixture assertion line %d: %s\n", __LINE__, #x); exit(1); \
} } while (0)
#define K_BASE (DSH_IMAGE_K_DIMENSIONS | DSH_IMAGE_K_SAMPLE_BITS | DSH_IMAGE_K_METADATA | DSH_IMAGE_K_ORIENTATION | DSH_IMAGE_K_FRAMES)
#define K_ALPHA (K_BASE | DSH_IMAGE_K_ALPHA)
#define K_ALL (K_ALPHA | DSH_IMAGE_K_SPACE)

typedef struct { uint8_t b[4096]; size_t n; } Buffer;
static unsigned checks;
static void add(Buffer *b, const void *p, size_t n) {
    CHECK(n <= sizeof(b->b) - b->n);
    if (n) memcpy(b->b + b->n, p, n);
    b->n += n;
}
static void byte(Buffer *b, unsigned v) { uint8_t c = (uint8_t)v; add(b, &c, 1); }
static void u16(Buffer *b, unsigned v) { byte(b, v >> 8); byte(b, v); }
static void u32be(Buffer *b, uint32_t v) {
    byte(b, v >> 24); byte(b, v >> 16); byte(b, v >> 8); byte(b, v);
}
static void u32le(Buffer *b, uint32_t v) {
    byte(b, v); byte(b, v >> 8); byte(b, v >> 16); byte(b, v >> 24);
}
static uint32_t fixture_crc(const uint8_t *p, size_t n) {
    uint32_t state = 0xffffffffu;
    size_t i; unsigned k;
    for (i = 0; i < n; ++i) {
        state ^= p[i];
        for (k = 0; k < 8; ++k) {
            if (state & 1) state = (state >> 1) ^ 0xedb88320u;
            else state >>= 1;
        }
    }
    return ~state;
}
static void png_chunk(Buffer *b, const char *name, const void *p, size_t n) {
    size_t start;
    CHECK(n <= UINT32_MAX);
    u32be(b, (uint32_t)n); start = b->n; add(b, name, 4); add(b, p, n);
    u32be(b, fixture_crc(b->b + start, n + 4));
}
static void riff_chunk(Buffer *b, const char *name, const void *p, size_t n) {
    CHECK(n <= UINT32_MAX);
    add(b, name, 4); u32le(b, (uint32_t)n); add(b, p, n);
    if (n & 1) byte(b, 0);
}
static void riff_finish(Buffer *b) {
    uint32_t len;
    CHECK(b->n >= 12 && b->n - 8 <= UINT32_MAX);
    len = (uint32_t)(b->n - 8);
    b->b[4] = (uint8_t)len; b->b[5] = (uint8_t)(len >> 8);
    b->b[6] = (uint8_t)(len >> 16); b->b[7] = (uint8_t)(len >> 24);
}
static void jpeg_segment(Buffer *b, unsigned marker, const void *p, size_t n) {
    CHECK(n <= 65533); byte(b, 255); byte(b, marker); u16(b, (unsigned)n + 2); add(b, p, n);
}
static DshImageContainerFacts good(const char *name, const Buffer *b, DshImageFormat format,
                                  uint32_t known, unsigned alpha, unsigned bits,
                                  unsigned meta, unsigned orient, unsigned count,
                                  unsigned space, unsigned subset, unsigned warnings) {
    DshImageContainerFacts f;
    CHECK(dsh_image_scan_container(b->b, b->n, &f) == DSH_IMAGE_SCAN_OK);
    CHECK(f.format == format && f.complete == 1 && f.known == known);
    CHECK(f.width == 1 && f.height == 1 && f.sample_bits == bits);
    if (known & DSH_IMAGE_K_ALPHA) CHECK(f.alpha == alpha);
    if (known & DSH_IMAGE_K_METADATA) CHECK(f.metadata == meta);
    if (known & DSH_IMAGE_K_ORIENTATION) CHECK(f.orientation == orient);
    if (known & DSH_IMAGE_K_FRAMES) CHECK(f.frames == count);
    if (known & DSH_IMAGE_K_SPACE) CHECK(f.space == space);
    CHECK(f.output_subset == subset && f.warnings == warnings);
    ++checks; printf("PASS %s\n", name); return f;
}
static void bad(const char *name, const Buffer *b, DshImageScanStatus expected) {
    DshImageContainerFacts f, zero;
    memset(&f, 0xa5, sizeof(f)); memset(&zero, 0, sizeof(zero));
    CHECK(dsh_image_scan_container(b->b, b->n, &f) == expected);
    CHECK(memcmp(&f, &zero, sizeof(f)) == 0);
    ++checks; printf("PASS %s (no partial facts)\n", name);
}
static const uint8_t exif6[] = {
    'I','I',42,0,8,0,0,0, 1,0,
    0x12,1,3,0,1,0,0,0,6,0,0,0, 0,0,0,0
};
static void make_png(Buffer *b, unsigned variant) {
    const uint8_t ihdr[] = {0,0,0,1,0,0,0,1,8,2,0,0,0};
    /* zlib stored block containing filter byte plus three zero RGB samples. */
    const uint8_t idat[] = {0x78,0x01,0x01,0x04,0x00,0xfb,0xff,0,0,0,0,0,0x04,0,0x01};
    const uint8_t trns[] = {0,0,0,0,0,0};
    const uint8_t srgb[] = {0};
    b->n = 0; add(b, "\211PNG\r\n\032\n", 8); png_chunk(b, "IHDR", ihdr, sizeof(ihdr));
    if (variant == 1) png_chunk(b, "tRNS", trns, sizeof(trns));
    if (variant == 2) png_chunk(b, "eXIf", exif6, sizeof(exif6));
    if (variant == 3) png_chunk(b, "vpAg", "x", 1);
    if (variant == 4 || variant == 6) png_chunk(b, "sRGB", srgb, sizeof(srgb));
    if (variant == 6) { const uint8_t cicp[] = {9,16,0,1}; png_chunk(b, "cICP", cicp, sizeof(cicp)); }
    if (variant == 5) png_chunk(b, "eXIf", exif6, 5);
    png_chunk(b, "IDAT", idat, sizeof(idat)); png_chunk(b, "IEND", NULL, 0);
}
static void make_jpeg(Buffer *b, unsigned variant) {
    const uint8_t jfif[] = {'J','F','I','F',0,1,2,0,0,1,0,1,0,0};
    const uint8_t sof[] = {8,0,1,0,1,3,1,0x11,0,2,0x11,0,3,0x11,0};
    const uint8_t sos[] = {3,1,0,2,0,3,0,0,63,0};
    uint8_t quant[65], huffman[36];
    Buffer ex = {{0},0};
    memset(quant, 1, sizeof(quant)); quant[0] = 0;
    memset(huffman, 0, sizeof(huffman)); huffman[1] = 1; huffman[18] = 0x10; huffman[19] = 1;
    b->n = 0; byte(b, 255); byte(b, 0xd8);
    jpeg_segment(b, 0xe0, jfif, sizeof(jfif));
    if (variant == 1) {
        add(&ex, "Exif\0\0", 6); add(&ex, exif6, sizeof(exif6));
        jpeg_segment(b, 0xe1, ex.b, ex.n);
    }
    if (variant == 2) jpeg_segment(b, 0xe3, "opaque", 6);
    jpeg_segment(b, 0xdb, quant, sizeof(quant));
    jpeg_segment(b, 0xc0, sof, sizeof(sof));
    jpeg_segment(b, 0xc4, huffman, sizeof(huffman));
    jpeg_segment(b, 0xda, sos, sizeof(sos));
    byte(b, 3); /* three DC0/EOB pairs, followed by one-bit entropy padding. */
    if (variant == 3) jpeg_segment(b, 0xfe, "comment-after-scan", 18);
    byte(b, 255); byte(b, 0xd9);
}
/* Header-only compressed-body fixtures. They are NOT codec-success oracles. */
static const uint8_t vp8[] = {0x30,0,0,0x9d,1,0x2a,1,0,1,0,0,0};
static const uint8_t vp8l[] = {0x2f,0,0,0,0,0};
static void make_webp(Buffer *b, unsigned variant) {
    uint8_t x[10] = {0};
    b->n = 0; add(b, "RIFF", 4); u32le(b, 0); add(b, "WEBP", 4);
    if (variant == 2) x[0] = 8;
    if (variant == 3) x[0] = 2;
    if (variant == 4) x[0] = 0x10;
    if (variant >= 2 && variant <= 4) riff_chunk(b, "VP8X", x, sizeof(x));
    if (variant == 3) {
        uint8_t anim[6] = {0};
        Buffer frame = {{0},0};
        uint8_t header[16] = {0};
        riff_chunk(b, "ANIM", anim, sizeof(anim));
        add(&frame, header, sizeof(header)); riff_chunk(&frame, "VP8 ", vp8, sizeof(vp8));
        riff_chunk(b, "ANMF", frame.b, frame.n); riff_chunk(b, "ANMF", frame.b, frame.n);
    } else {
        if (variant == 4) { const uint8_t a[] = {0,0}; riff_chunk(b, "ALPH", a, sizeof(a)); }
        if (variant == 5) riff_chunk(b, "VP8L", vp8l, sizeof(vp8l));
        else riff_chunk(b, "VP8 ", vp8, sizeof(vp8));
        if (variant == 1) riff_chunk(b, "zzzz", "x", 1);
        if (variant == 2) riff_chunk(b, "EXIF", exif6, sizeof(exif6));
    }
    riff_finish(b);
}
static void make_gif(Buffer *b, unsigned variant) {
    const uint8_t lsd[] = {1,0,1,0,0x80,0,0};
    const uint8_t palette[] = {0,0,0,255,255,255};
    const uint8_t image[] = {0x2c,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0};
    const uint8_t gce[] = {0x21,0xf9,4,1,0,0,0,0};
    const uint8_t app[] = {0x21,0xff,11,'U','n','k','n','o','w','n','1','0','0','0',1,'x',0};
    b->n = 0; add(b, "GIF89a", 6); add(b, lsd, sizeof(lsd)); add(b, palette, sizeof(palette));
    if (variant == 1) add(b, gce, sizeof(gce));
    if (variant == 3) add(b, app, sizeof(app));
    add(b, image, sizeof(image)); if (variant == 2) add(b, image, sizeof(image));
    byte(b, 0x3b);
}
int main(void) {
    Buffer b = {{0},0};
    make_png(&b,0); good("PNG RGB declaration",&b,DSH_IMAGE_PNG,K_ALPHA,0,8,0,1,1,0,0,0);
    --b.n; bad("PNG truncated IEND",&b,DSH_IMAGE_SCAN_TRUNCATED);
    make_png(&b,0); b.b[b.n-1] ^= 1; bad("PNG CRC mismatch",&b,DSH_IMAGE_SCAN_INVALID);
    make_png(&b,1); good("PNG transparency key",&b,DSH_IMAGE_PNG,K_ALPHA,1,8,0,1,1,0,0,0);
    make_png(&b,2); good("PNG bounded Exif orientation 6",&b,DSH_IMAGE_PNG,K_ALPHA,0,8,1,6,1,0,0,0);
    make_png(&b,3); good("PNG unknown ancillary remains unknown",&b,DSH_IMAGE_PNG,
        DSH_IMAGE_K_DIMENSIONS|DSH_IMAGE_K_SAMPLE_BITS|DSH_IMAGE_K_ALPHA,0,8,0,0,0,0,0,DSH_IMAGE_W_EXTENSION);
    make_png(&b,4); good("PNG sRGB is an explicit convention",&b,DSH_IMAGE_PNG,K_ALL,0,8,1,1,1,1,0,0);
    make_png(&b,5); good("PNG unparsed Exif is not orientation 1",&b,DSH_IMAGE_PNG,
        K_ALPHA & ~DSH_IMAGE_K_ORIENTATION,0,8,1,0,1,0,0,DSH_IMAGE_W_EXIF);
    make_png(&b,6); good("PNG cICP prevents sRGB inference",&b,DSH_IMAGE_PNG,K_ALPHA,0,8,1,1,1,0,0,0);
    make_jpeg(&b,0); good("JPEG baseline structural subset",&b,DSH_IMAGE_JPEG,K_ALPHA,0,8,0,1,1,0,1,0);
    --b.n; bad("JPEG missing final EOI byte",&b,DSH_IMAGE_SCAN_TRUNCATED);
    make_jpeg(&b,0); byte(&b,0); bad("JPEG trailing byte",&b,DSH_IMAGE_SCAN_INVALID);
    make_jpeg(&b,1); good("JPEG bounded Exif orientation 6",&b,DSH_IMAGE_JPEG,K_ALPHA,0,8,1,6,1,0,0,0);
    make_jpeg(&b,2); good("JPEG unknown APP not clean metadata",&b,DSH_IMAGE_JPEG,
        K_ALPHA & ~(DSH_IMAGE_K_ALPHA|DSH_IMAGE_K_ORIENTATION|DSH_IMAGE_K_FRAMES),0,8,1,0,0,0,0,DSH_IMAGE_W_EXTENSION);
    make_jpeg(&b,3); good("JPEG metadata after entropy is visited",&b,DSH_IMAGE_JPEG,K_ALPHA,0,8,1,1,1,0,0,0);
    make_webp(&b,0); good("WebP lossy header subset",&b,DSH_IMAGE_WEBP,K_ALL,0,8,0,1,1,1,1,0);
    --b.n; bad("WebP RIFF truncated",&b,DSH_IMAGE_SCAN_TRUNCATED);
    make_webp(&b,0); byte(&b,0); bad("WebP trailing byte",&b,DSH_IMAGE_SCAN_INVALID);
    make_webp(&b,1); good("WebP unknown chunk remains unknown",&b,DSH_IMAGE_WEBP,
        DSH_IMAGE_K_DIMENSIONS|DSH_IMAGE_K_SAMPLE_BITS|DSH_IMAGE_K_ALPHA|DSH_IMAGE_K_FRAMES,
        0,8,0,0,1,0,0,DSH_IMAGE_W_EXTENSION);
    make_webp(&b,2); good("WebP Exif orientation 6",&b,DSH_IMAGE_WEBP,K_ALL,0,8,1,6,1,1,0,0);
    make_webp(&b,3); good("WebP two declared frames not a single image",&b,DSH_IMAGE_WEBP,
        K_ALL & ~DSH_IMAGE_K_ALPHA,0,8,0,1,2,1,0,DSH_IMAGE_W_FRAME_SCOPE);
    make_webp(&b,4); good("WebP ALPH declaration",&b,DSH_IMAGE_WEBP,K_ALL,1,8,0,1,1,1,1,0);
    make_webp(&b,5); good("WebP lossless hint zero is still unknown alpha",&b,DSH_IMAGE_WEBP,
        K_ALL & ~DSH_IMAGE_K_ALPHA,0,8,0,1,1,1,1,DSH_IMAGE_W_ALPHA_HINT);
    make_gif(&b,0); good("GIF one image no transparency declaration",&b,DSH_IMAGE_GIF,K_ALPHA,0,8,0,1,1,0,0,0);
    b.n -= 2; bad("GIF truncated image sub-block terminator",&b,DSH_IMAGE_SCAN_TRUNCATED);
    make_gif(&b,1); good("GIF GCE transparency scope",&b,DSH_IMAGE_GIF,K_ALPHA,1,8,0,1,1,0,0,0);
    make_gif(&b,2); good("GIF two images",&b,DSH_IMAGE_GIF,K_ALPHA,0,8,0,1,2,0,0,0);
    make_gif(&b,3); good("GIF application extension orientation unknown",&b,DSH_IMAGE_GIF,
        K_ALPHA & ~DSH_IMAGE_K_ORIENTATION,0,8,1,0,1,0,0,DSH_IMAGE_W_EXTENSION);
    printf("container facts: %u finite checks; no pixel decoding\n",checks);
    return 0;
}
