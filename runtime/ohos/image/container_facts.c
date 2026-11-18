/*
 * Original implementation of bounded container rules; no third-party code.
 * Rules: W3C PNG 3 (chunks/IHDR/tRNS/eXIf), Compuserve GIF89a,
 * Google WebP RIFF/lossless headers, RFC6386 section 9.1,
 * ITU T.81 Annex B (W3C-hosted 1992 PDF). Exif reads only classic TIFF IFD0.
 * Precise adopted versions, restrictions and public links: SOURCES.md in this directory.
 */
#include "container_facts.h"
#include <string.h>

#define OK DSH_IMAGE_SCAN_OK
#define BAD DSH_IMAGE_SCAN_INVALID
#define SHORT DSH_IMAGE_SCAN_TRUNCATED
#define UNSUP DSH_IMAGE_SCAN_UNSUPPORTED

typedef struct {
    DshImageContainerFacts f;
    int meta, meta_unknown, orientation_seen, orientation_unknown;
    uint8_t orientation;
} Scan;

static int fits(size_t n, size_t at, size_t count) {
    return at <= n && count <= n - at;
}
static uint16_t be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}
static uint16_t le16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[1] << 8) | p[0]);
}
static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}
static uint32_t le32(const uint8_t *p) {
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[1] << 8) | p[0];
}
static uint32_t le24(const uint8_t *p) {
    return ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
}
static int tag(const uint8_t *p, const char *s) { return memcmp(p, s, 4) == 0; }
static void extension(Scan *s) {
    s->meta_unknown = 1;
    s->orientation_unknown = 1;
    s->f.warnings |= DSH_IMAGE_W_EXTENSION;
}
static void dimensions(Scan *s, uint32_t w, uint32_t h) {
    s->f.width = w; s->f.height = h; s->f.known |= DSH_IMAGE_K_DIMENSIONS;
}
static void alpha(Scan *s, unsigned a) {
    s->f.alpha = (uint8_t)(a != 0); s->f.known |= DSH_IMAGE_K_ALPHA;
}
static void bits(Scan *s, unsigned b) {
    s->f.sample_bits = (uint8_t)b; s->f.known |= DSH_IMAGE_K_SAMPLE_BITS;
}
static void frames(Scan *s, uint32_t count) {
    s->f.frames = count; s->f.known |= DSH_IMAGE_K_FRAMES;
}
static void finish(Scan *s) {
    s->f.complete = 1;
    if (s->meta || !s->meta_unknown) {
        s->f.known |= DSH_IMAGE_K_METADATA;
        s->f.metadata = (uint8_t)(s->meta != 0);
    }
    if (!s->orientation_unknown) {
        s->f.known |= DSH_IMAGE_K_ORIENTATION;
        s->f.orientation = s->orientation_seen ? s->orientation : 1;
    }
}
static uint16_t t16(const uint8_t *p, int little) {
    return little ? le16(p) : be16(p);
}
static uint32_t t32(const uint8_t *p, int little) {
    return little ? le32(p) : be32(p);
}
/* A complete IFD0 table proves its own Orientation presence/absence only.
 * No pointer chasing to sub-IFDs, thumbnails, maker notes or pixel storage. */
static void exif(Scan *s, const uint8_t *p, size_t n) {
    size_t at, count, i;
    uint16_t previous = 0;
    int little, have_previous = 0, found = 0;
    uint8_t value = 1;
    s->meta = 1;
    if (n >= 6 && memcmp(p, "Exif\0\0", 6) == 0) { p += 6; n -= 6; }
    if (n < 8) goto unknown;
    little = p[0] == 'I' && p[1] == 'I';
    if (!little && !(p[0] == 'M' && p[1] == 'M')) goto unknown;
    if (t16(p + 2, little) != 42) goto unknown;
    at = t32(p + 4, little);
    if (at < 8 || (at & 1) || !fits(n, at, 2)) goto unknown;
    count = t16(p + at, little); at += 2;
    if (!fits(n, at, 4) || count > (n - at - 4) / 12) goto unknown;
    for (i = 0; i < count; ++i) {
        const uint8_t *e = p + at + i * 12;
        uint16_t id = t16(e, little);
        if (have_previous && id <= previous) goto unknown;
        previous = id; have_previous = 1;
        if (id == 0x02bc) { /* TIFF XMP packet may carry another orientation. */
            s->orientation_unknown = 1; s->f.warnings |= DSH_IMAGE_W_EXIF;
        }
        if (id == 0x0112) {
            unsigned v;
            if (found || t16(e + 2, little) != 3 || t32(e + 4, little) != 1)
                goto unknown;
            v = t16(e + 8, little);
            if (v < 1 || v > 8) goto unknown;
            value = (uint8_t)v; found = 1;
        }
    }
    if (s->orientation_seen) goto unknown; /* Multiple Exif profiles: no precedence guess. */
    s->orientation_seen = 1; s->orientation = value;
    return;
unknown:
    s->orientation_unknown = 1;
    s->f.warnings |= DSH_IMAGE_W_EXIF;
}

static uint32_t crc32_png(const uint8_t *p, size_t n) {
    uint32_t crc = UINT32_MAX;
    size_t i; unsigned b;
    for (i = 0; i < n; ++i) {
        crc ^= p[i];
        for (b = 0; b < 8; ++b)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return crc ^ UINT32_MAX;
}
static int png_type(const uint8_t *p) {
    unsigned i;
    for (i = 0; i < 4; ++i)
        if (!((p[i] >= 'A' && p[i] <= 'Z') || (p[i] >= 'a' && p[i] <= 'z')))
            return 0;
    return (p[2] & 32) == 0;
}
static int png_depth(unsigned type, unsigned depth) {
    if (type == 0) return depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16;
    if (type == 3) return depth == 1 || depth == 2 || depth == 4 || depth == 8;
    return (type == 2 || type == 4 || type == 6) && (depth == 8 || depth == 16);
}
static DshImageScanStatus png(Scan *s, const uint8_t *p, size_t n) {
    size_t at = 8;
    unsigned type = 0, depth = 0, palette = 0;
    int ihdr = 0, idat = 0, idat_ended = 0, trns = 0, srgb = 0, iccp = 0;
    int exif_seen = 0, animation = 0, color_override = 0;
    s->f.format = DSH_IMAGE_PNG;
    if (n < 8) return SHORT;
    if (memcmp(p, "\211PNG\r\n\032\n", 8) != 0) return BAD;
    while (at < n) {
        size_t len; const uint8_t *t, *v;
        if (!fits(n, at, 12)) return SHORT;
        len = be32(p + at); t = p + at + 4; v = p + at + 8;
        if (len > 0x7fffffffu || !png_type(t)) return BAD;
        if (len > n - at - 12) return SHORT;
        if (crc32_png(t, len + 4) != be32(v + len)) return BAD;
        if (!ihdr && !tag(t, "IHDR")) return BAD;
        if (idat && !tag(t, "IDAT")) idat_ended = 1;
        if (tag(t, "IHDR")) {
            if (ihdr || len != 13 || at != 8) return BAD;
            if (!be32(v) || !be32(v + 4) || be32(v) > 0x7fffffffu || be32(v + 4) > 0x7fffffffu)
                return BAD;
            depth = v[8]; type = v[9];
            if (!png_depth(type, depth) || v[10] || v[11] || v[12] > 1) return BAD;
            dimensions(s, be32(v), be32(v + 4));
            bits(s, type == 3 ? 8 : depth); alpha(s, type == 4 || type == 6); ihdr = 1;
        } else if (tag(t, "PLTE")) {
            if (palette || idat || type == 0 || type == 4 || !len || len > 768 || len % 3)
                return BAD;
            palette = (unsigned)(len / 3);
            if (type == 3 && palette > (1u << depth)) return BAD;
        } else if (tag(t, "tRNS")) {
            if (trns || idat || (type == 0 && len != 2) || (type == 2 && len != 6) ||
                (type == 3 && (!palette || !len || len > palette)) || type == 4 || type == 6)
                return BAD;
            trns = 1; alpha(s, 1);
        } else if (tag(t, "IDAT")) {
            if (idat_ended || (type == 3 && !palette)) return BAD;
            idat = 1;
        } else if (tag(t, "IEND")) {
            if (len || !idat || at + 12 != n) return BAD;
            if (!animation && !(s->f.warnings & DSH_IMAGE_W_EXTENSION)) frames(s, 1);
            if (srgb && !iccp && !color_override && !(s->f.warnings & DSH_IMAGE_W_EXTENSION)) { s->f.space = DSH_IMAGE_SPACE_SRGB_CONVENTION; s->f.known |= DSH_IMAGE_K_SPACE; }
            finish(s); return OK;
        } else if (tag(t, "eXIf")) {
            if (exif_seen++) return BAD;
            exif(s, v, len);
        } else if (tag(t, "sRGB")) {
            if (srgb || iccp || idat || palette || len != 1 || v[0] > 3) return BAD;
            srgb = 1; s->meta = 1;
        } else if (tag(t, "iCCP")) {
            if (iccp || srgb || idat || palette || len < 3) return BAD;
            iccp = 1; s->meta = 1; /* Profile contents are not inflated. */
        } else if (tag(t, "acTL") || tag(t, "fcTL") || tag(t, "fdAT")) {
            if ((tag(t, "acTL") && (len != 8 || !be32(v))) ||
                (tag(t, "fcTL") && len != 26) || (tag(t, "fdAT") && len < 4)) return BAD;
            animation = 1;
            s->f.warnings |= DSH_IMAGE_W_FRAME_SCOPE; /* No APNG page/composition claims. */
        } else if (tag(t, "cHRM") || tag(t, "gAMA") || tag(t, "cICP") ||
                   tag(t, "mDCV") || tag(t, "cLLI") || tag(t, "sBIT") ||
                   tag(t, "bKGD") || tag(t, "hIST") || tag(t, "pHYs") ||
                   tag(t, "sPLT") || tag(t, "tIME")) {
            s->meta = 1; /* Do not derive color or defaults from uninterpreted fields. */
            if (tag(t, "cICP")) color_override = 1;
        } else if (tag(t, "tEXt") || tag(t, "zTXt") || tag(t, "iTXt")) {
            s->meta = 1; s->orientation_unknown = 1; /* May carry an unparsed XMP profile. */
        } else {
            if ((t[0] & 32) == 0) return UNSUP;
            extension(s);
        }
        at += len + 12;
    }
    return SHORT;
}

/* JPEG: non-hierarchical Huffman SOF0/1/2 only. No coefficient decoding.
 * Entropy traversal continues through every scan and segment to exact EOI. */
typedef struct {
    unsigned sof, components, scans, qmask, q8mask, dcmask, acmask, restart;
    uint8_t ids[4], qt[4];
    int jfif, strict;
} Jpeg;

static DshImageScanStatus jpeg_quant(Jpeg *j, const uint8_t *p, size_t n) {
    size_t at = 0;
    if (!n) return BAD;
    while (at < n) {
        unsigned spec = p[at++], prec = spec >> 4, id = spec & 15, i;
        size_t bytes;
        if (prec > 1 || id > 3) return BAD;
        bytes = prec ? 128 : 64;
        if (!fits(n, at, bytes)) return BAD;
        for (i = 0; i < 64; ++i)
            if (!(prec ? be16(p + at + 2 * i) : p[at + i])) return BAD;
        j->qmask |= 1u << id;
        j->q8mask &= ~(1u << id);
        if (!prec) j->q8mask |= 1u << id;
        at += bytes;
    }
    return OK;
}
static DshImageScanStatus jpeg_huffman(Jpeg *j, const uint8_t *p, size_t n) {
    size_t at = 0;
    if (!n) return BAD;
    while (at < n) {
        unsigned spec, cls, id, i, count = 0, slots = 1;
        if (!fits(n, at, 17)) return BAD;
        spec = p[at++]; cls = spec >> 4; id = spec & 15;
        if (cls > 1 || id > 3) return BAD;
        for (i = 0; i < 16; ++i) {
            unsigned v = p[at + i];
            slots *= 2;
            if (v > slots) return BAD;
            slots -= v; count += v;
        }
        at += 16;
        if (!count || count > 256 || !slots || !fits(n, at, count)) return BAD;
        if (cls) j->acmask |= 1u << id; else j->dcmask |= 1u << id;
        at += count;
    }
    return OK;
}
static DshImageScanStatus jpeg(Scan *s, const uint8_t *p, size_t n) {
    Jpeg j;
    size_t at = 2;
    int entropy = 0, scan_data = 0;
    unsigned rst = 0;
    memset(&j, 0, sizeof(j)); j.strict = 1;
    s->f.format = DSH_IMAGE_JPEG;
    if (n < 2) return SHORT;
    if (p[0] != 0xff || p[1] != 0xd8) return BAD;
    while (at < n) {
        unsigned marker;
        size_t len, marker_at;
        const uint8_t *v;
        if (entropy) {
            while (at < n && p[at] != 0xff) { ++at; scan_data = 1; }
            if (at == n) return SHORT;
        } else if (p[at] != 0xff) return BAD;
        marker_at = at++;
        while (at < n && p[at] == 0xff) ++at;
        if (at == n) return SHORT;
        marker = p[at++];
        if (entropy && marker == 0) {
            /* A data FF is exactly FF00, not marker fill followed by 00. */
            if (at - marker_at != 2) return BAD;
            scan_data = 1; continue;
        }
        if (entropy && marker >= 0xd0 && marker <= 0xd7) {
            if (!j.restart || marker != 0xd0 + rst) return BAD;
            rst = (rst + 1) & 7; continue;
        }
        if (entropy && !scan_data) return BAD;
        entropy = 0;
        if (marker == 0xd9) {
            if (!j.sof || !j.scans || at != n) return BAD;
            if (!(s->f.warnings & DSH_IMAGE_W_EXTENSION)) frames(s, 1);
            /* JFIF defines one Y or three YCbCr components; generic JPEG
             * component counts alone do not identify a source alpha channel. */
            if (j.jfif && !(s->f.warnings & DSH_IMAGE_W_EXTENSION) &&
                (j.components == 1 || j.components == 3)) alpha(s, 0);
            finish(s);
            s->f.output_subset = (uint8_t)(j.strict && j.sof == 0xc0 &&
                j.components == 3 && j.scans == 1 && !s->meta &&
                !s->meta_unknown && !s->orientation_unknown);
            return OK;
        }
        if (marker == 0 || marker == 0xd8 || (marker >= 0xd0 && marker <= 0xd7))
            return BAD;
        /* No arithmetic, hierarchical, lossless, DNL, TEM or reserved syntax. */
        if (!(marker == 0xc0 || marker == 0xc1 || marker == 0xc2 ||
              marker == 0xc4 || marker == 0xdb || marker == 0xdd ||
              marker == 0xda || marker == 0xfe || (marker >= 0xe0 && marker <= 0xef)))
            return UNSUP;
        if (!fits(n, at, 2)) return SHORT;
        len = be16(p + at);
        if (len < 2) return BAD;
        if (!fits(n, at, len)) return SHORT;
        v = p + at + 2; len -= 2; at += len + 2;
        if (marker == 0xc0 || marker == 0xc1 || marker == 0xc2) {
            unsigned i, k, count;
            if (j.sof || j.scans || len < 6) return BAD;
            count = v[5];
            if (!count || len != 6u + 3u * count || !be16(v + 1) || !be16(v + 3)) return BAD;
            if (count > 4) return UNSUP;
            if ((marker == 0xc0 && v[0] != 8) ||
                (marker != 0xc0 && v[0] != 8 && v[0] != 12)) return BAD;
            j.sof = marker; j.components = count;
            dimensions(s, be16(v + 3), be16(v + 1)); bits(s, v[0]);
            for (i = 0; i < count; ++i) {
                unsigned hv = v[7 + i * 3];
                j.ids[i] = v[6 + i * 3]; j.qt[i] = v[8 + i * 3];
                if (!(hv >> 4) || (hv >> 4) > 4 || !(hv & 15) || (hv & 15) > 4 || j.qt[i] > 3)
                    return BAD;
                for (k = 0; k < i; ++k) if (j.ids[k] == j.ids[i]) return BAD;
            }
        } else if (marker == 0xdb) {
            if (jpeg_quant(&j, v, len) != OK) return BAD;
        } else if (marker == 0xc4) {
            if (jpeg_huffman(&j, v, len) != OK) return BAD;
        } else if (marker == 0xdd) {
            if (len != 2) return BAD;
            j.restart = be16(v);
        } else if (marker == 0xda) {
            unsigned count, ss, se, ah, al, i, used = 0;
            if (!j.sof || len < 4) return BAD;
            count = v[0];
            if (!count || count > 4 || count > j.components || len != 4u + 2u * count)
                return BAD;
            ss = v[1 + 2 * count]; se = v[2 + 2 * count];
            ah = v[3 + 2 * count] >> 4; al = v[3 + 2 * count] & 15;
            if (j.sof != 0xc2) {
                if (ss || se != 63 || ah || al) return BAD;
            } else if (ss > se || se > 63 || (ss == 0 && se != 0) ||
                       (ss && count != 1) || ah > 13 || al > 13 || (ah && ah != al + 1)) return BAD;
            for (i = 0; i < count; ++i) {
                unsigned k, tables = v[2 + 2 * i], dc = tables >> 4, ac = tables & 15;
                for (k = 0; k < j.components && j.ids[k] != v[1 + 2 * i]; ++k) { }
                if (k == j.components || (used & (1u << k)) || dc > 3 || ac > 3) return BAD;
                used |= 1u << k;
                if (!(j.qmask & (1u << j.qt[k]))) return BAD;
                if (j.sof == 0xc0 && !(j.q8mask & (1u << j.qt[k]))) return BAD;
                if (!ss && !ah && !(j.dcmask & (1u << dc))) return BAD;
                if (se && !(j.acmask & (1u << ac))) return BAD;
                if (j.sof == 0xc2 && ((!ss && ac) || (ss && dc))) return BAD;
            }
            if (j.scans == UINT32_MAX) return BAD;
            ++j.scans;
            if (j.sof != 0xc0 || count != 3 || j.components != 3) j.strict = 0;
            entropy = 1; scan_data = 0; rst = 0;
        } else if (marker == 0xe0 && len >= 5 && memcmp(v, "JFIF\0", 5) == 0) {
            size_t thumb;
            if (j.jfif || marker_at != 2 || len < 14 || v[5] != 1 || v[6] > 2 ||
                v[7] > 2 || !be16(v + 8) || !be16(v + 10)) return BAD;
            thumb = 3u * (size_t)v[12] * v[13];
            if (len != 14 + thumb || ((v[12] == 0) != (v[13] == 0))) return BAD;
            j.jfif = 1;
            if (thumb) s->meta = 1;
        } else if (marker == 0xe1 && len >= 6 && memcmp(v, "Exif\0\0", 6) == 0) {
            exif(s, v, len);
        } else if (marker == 0xe2 && len >= 12 && memcmp(v, "ICC_PROFILE\0", 12) == 0) {
            s->meta = 1; /* No ICC interpretation or decompression. */
            if (len < 14 || !v[12] || !v[13] || v[12] > v[13]) extension(s);
        } else if (marker == 0xfe) {
            s->meta = 1;
        } else {
            s->meta = 1; extension(s);
        }
    }
    return SHORT;
}

/* RIFF chunk padding is part of the enclosing length, not the payload. */
static DshImageScanStatus riff_chunk(const uint8_t *p, size_t n, size_t *at,
                                    const uint8_t **t, const uint8_t **v, size_t *len) {
    size_t start = *at, padded;
    if (!fits(n, start, 8)) return SHORT;
    *t = p + start; *v = p + start + 8; *len = le32(p + start + 4);
    if (*len > n - start - 8) return SHORT;
    padded = *len;
    if (padded & 1) {
        if (padded == n - start - 8) return SHORT;
        if ((*v)[padded] != 0) return BAD;
        ++padded;
    }
    *at = start + 8 + padded;
    return OK;
}
typedef struct {
    uint32_t width, height;
    int seen, lossless, alph, alpha_known, alpha_value;
    const uint8_t *alpha_data;
    size_t alpha_len;
} WebpImage;
static DshImageScanStatus webp_alpha(WebpImage *im, const uint8_t *v, size_t n) {
    if (im->seen || im->alph || n < 2 || (v[0] & 0xc0) ||
        ((v[0] >> 4) & 3) > 1 || (v[0] & 3) > 1) return BAD;
    im->alph = 1; im->alpha_data = v; im->alpha_len = n;
    return OK;
}
static DshImageScanStatus webp_bits(Scan *s, WebpImage *im, const uint8_t *t,
                                   const uint8_t *v, size_t n) {
    if (im->seen) return BAD;
    im->seen = 1;
    if (tag(t, "VP8 ")) {
        uint32_t header, first;
        if (n < 11) return SHORT;
        header = le24(v); first = header >> 5;
        if ((header & 1) || ((header >> 1) & 7) > 3 || !(header & 16) ||
            memcmp(v + 3, "\235\001\052", 3) != 0 || !first || first > n - 10) return BAD;
        if ((le16(v + 6) & 0xc000) || (le16(v + 8) & 0xc000)) return UNSUP;
        im->width = le16(v + 6) & 0x3fff; im->height = le16(v + 8) & 0x3fff;
        if (!im->width || !im->height) return BAD;
        im->alpha_known = 1; im->alpha_value = im->alph;
        if (im->alph && (im->alpha_data[0] & 3) == 0 &&
            (uint64_t)im->alpha_len - 1 != (uint64_t)im->width * im->height) return BAD;
    } else {
        uint32_t h;
        if (n < 6) return SHORT;
        if (v[0] != 0x2f || im->alph) return BAD;
        h = le32(v + 1);
        if (h >> 29) return UNSUP;
        im->lossless = 1; im->width = (h & 0x3fff) + 1;
        im->height = ((h >> 14) & 0x3fff) + 1;
        /* Bit 28 is expressly a decoder hint, not an alpha proof. */
        im->alpha_known = 0; s->f.warnings |= DSH_IMAGE_W_ALPHA_HINT;
    }
    return OK;
}
static DshImageScanStatus webp_frame(Scan *s, const uint8_t *p, size_t n,
                                    uint32_t width, uint32_t height, WebpImage *im) {
    size_t at = 0;
    memset(im, 0, sizeof(*im));
    while (at < n) {
        const uint8_t *t, *v; size_t len;
        DshImageScanStatus r = riff_chunk(p, n, &at, &t, &v, &len);
        if (r != OK) return r;
        if (tag(t, "ALPH")) r = webp_alpha(im, v, len);
        else if (tag(t, "VP8 ") || tag(t, "VP8L")) r = webp_bits(s, im, t, v, len);
        else extension(s);
        if (r != OK) return r;
    }
    if (!im->seen || im->width != width || im->height != height) return BAD;
    return OK;
}
static DshImageScanStatus webp(Scan *s, const uint8_t *p, size_t n) {
    size_t at = 12;
    WebpImage im;
    unsigned flags = 0;
    int extended = 0, iccp = 0, ex = 0, xmp = 0, anim = 0;
    int all_alpha_known = 1, any_alpha = 0, any_alph_chunk = 0, any_lossless = 0;
    uint32_t frame_count = 0, canvas_w = 0, canvas_h = 0;
    memset(&im, 0, sizeof(im));
    s->f.format = DSH_IMAGE_WEBP;
    if (n < 12) return SHORT;
    if (!tag(p, "RIFF") || !tag(p + 8, "WEBP")) return BAD;
    if (le32(p + 4) > UINT32_MAX - 9u || (le32(p + 4) & 1)) return BAD;
    if ((uint64_t)le32(p + 4) + 8 > n) return SHORT;
    if ((uint64_t)le32(p + 4) + 8 != n) return BAD;
    while (at < n) {
        const uint8_t *t, *v; size_t len, start = at;
        DshImageScanStatus r = riff_chunk(p, n, &at, &t, &v, &len);
        if (r != OK) return r;
        if (tag(t, "VP8X")) {
            if (extended || start != 12 || len != 10 || (v[0] & 0xc1) || v[1] || v[2] || v[3]) return BAD;
            extended = 1; flags = v[0]; canvas_w = le24(v + 4) + 1; canvas_h = le24(v + 7) + 1;
            if ((uint64_t)canvas_w * canvas_h > UINT32_MAX) return BAD;
        } else if (tag(t, "ICCP")) {
            if (!extended || !(flags & 0x20) || iccp || anim || im.alph || im.seen || !len) return BAD;
            iccp = 1; s->meta = 1;
        } else if (tag(t, "EXIF")) {
            if (!extended || !(flags & 8) || ex) return BAD;
            ex = 1; exif(s, v, len);
        } else if (tag(t, "XMP ")) {
            if (!extended || !(flags & 4) || xmp) return BAD;
            xmp = 1; s->meta = 1; s->orientation_unknown = 1;
        } else if (tag(t, "ANIM")) {
            if (!extended || !(flags & 2) || anim || im.alph || im.seen || len != 6) return BAD;
            anim = 1;
            /* The background can have alpha independently of VP8X alpha.
             * A composed animation is not inferred from individual frames. */
            s->f.warnings |= DSH_IMAGE_W_FRAME_SCOPE;
        } else if (tag(t, "ANMF")) {
            uint32_t x, y, w, h; WebpImage frame;
            if (!anim || len < 16 || (v[15] & 0xfc)) return BAD;
            x = le24(v) * 2; y = le24(v + 3) * 2;
            w = le24(v + 6) + 1; h = le24(v + 9) + 1;
            if (x > canvas_w || w > canvas_w - x || y > canvas_h || h > canvas_h - y) return BAD;
            r = webp_frame(s, v + 16, len - 16, w, h, &frame);
            if (r != OK) return r;
            if (frame_count == UINT32_MAX) return BAD;
            ++frame_count;
            all_alpha_known &= frame.alpha_known; any_alpha |= frame.alpha_value;
            any_alph_chunk |= frame.alph; any_lossless |= frame.lossless;
        } else if (tag(t, "ALPH")) {
            if (!extended || anim || (flags & 2)) return BAD;
            r = webp_alpha(&im, v, len); if (r != OK) return r;
        } else if (tag(t, "VP8 ") || tag(t, "VP8L")) {
            if (anim || (flags & 2)) return BAD;
            r = webp_bits(s, &im, t, v, len); if (r != OK) return r;
        } else extension(s);
    }
    if (extended && (((flags & 0x20) != 0) != iccp || ((flags & 8) != 0) != ex ||
                     ((flags & 4) != 0) != xmp || ((flags & 2) != 0) != anim)) return BAD;
    if (anim) {
        if (!frame_count) return BAD;
        frames(s, frame_count);
        /* Whole animation transparency also involves background and disposal. */
    } else {
        if (!im.seen || (extended && (im.width != canvas_w || im.height != canvas_h))) return BAD;
        frame_count = 1; frames(s, 1);
        if (!extended) { canvas_w = im.width; canvas_h = im.height; }
        all_alpha_known = im.alpha_known; any_alpha = im.alpha_value;
        any_alph_chunk = im.alph; any_lossless = im.lossless;
        if (all_alpha_known) alpha(s, (unsigned)any_alpha);
    }
    /* Check declarations when the chunk structure supplies the fact.
     * VP8L's hint cannot prove the opposite value; its alpha stays unknown. */
    if (extended && ((any_alph_chunk && !(flags & 0x10)) ||
        (!any_lossless && (((flags & 0x10) != 0) != (any_alpha != 0))))) return BAD;
    dimensions(s, canvas_w, canvas_h); bits(s, 8);
    if (!iccp && !(s->f.warnings & DSH_IMAGE_W_EXTENSION)) {
        s->f.space = DSH_IMAGE_SPACE_SRGB_CONVENTION; s->f.known |= DSH_IMAGE_K_SPACE;
    }
    finish(s);
    s->f.output_subset = (uint8_t)(!anim && frame_count == 1 && !s->meta &&
        !s->meta_unknown && !s->orientation_unknown);
    return OK;
}

static DshImageScanStatus gif_blocks(const uint8_t *p, size_t n, size_t *at,
                                     int *has_data) {
    for (;;) {
        size_t len;
        if (*at == n) return SHORT;
        len = p[(*at)++];
        if (!len) return OK;
        if (!fits(n, *at, len)) return SHORT;
        *has_data = 1; *at += len;
    }
}
static DshImageScanStatus gif(Scan *s, const uint8_t *p, size_t n) {
    size_t at = 13;
    unsigned global = 0, pending = 0, transparent = 0, transparent_index = 0;
    uint32_t count = 0;
    int any_alpha = 0, scope_unknown = 0, v89;
    s->f.format = DSH_IMAGE_GIF;
    if (n < 13) return SHORT;
    v89 = memcmp(p, "GIF89a", 6) == 0;
    if (!v89 && memcmp(p, "GIF87a", 6) != 0) return BAD;
    if (!le16(p + 6) || !le16(p + 8)) return BAD;
    dimensions(s, le16(p + 6), le16(p + 8)); bits(s, 8);
    if (p[10] & 0x80) {
        global = 1u << ((p[10] & 7) + 1);
        if (!fits(n, at, 3u * global)) return SHORT;
        if (p[11] >= global) return BAD;
        at += 3u * global;
    }
    while (at < n) {
        unsigned label = p[at++];
        DshImageScanStatus r;
        int has_data = 0;
        if (label == 0x3b) {
            if (at != n || !count || pending) return BAD;
            if (!scope_unknown) { frames(s, count); alpha(s, (unsigned)any_alpha); }
            finish(s); return OK;
        }
        if (label == 0x2c) {
            unsigned table = global, packed;
            uint32_t x, y, w, h;
            if (!fits(n, at, 9)) return SHORT;
            x = le16(p + at); y = le16(p + at + 2);
            w = le16(p + at + 4); h = le16(p + at + 6); packed = p[at + 8];
            if (!w || !h || x > s->f.width || w > s->f.width - x ||
                y > s->f.height || h > s->f.height - y || (packed & 0x18)) return BAD;
            at += 9;
            if (packed & 0x80) {
                table = 1u << ((packed & 7) + 1);
                if (!fits(n, at, 3u * table)) return SHORT;
                at += 3u * table;
            }
            /* This standalone buffer does not inherit a previous stream palette. */
            if (!table || (pending && transparent && transparent_index >= table)) return UNSUP;
            if (at == n) return SHORT;
            if (p[at] < 2 || p[at] > 8) return BAD;
            ++at; r = gif_blocks(p, n, &at, &has_data);
            if (r != OK) return r;
            if (!has_data || count == UINT32_MAX) return BAD;
            ++count;
            if (pending && transparent) any_alpha = 1;
            pending = 0; transparent = 0;
        } else if (label == 0x21) {
            if (at == n) return SHORT;
            label = p[at++];
            if (label == 0xf9) {
                unsigned packed;
                if (!v89) return UNSUP;
                if (!fits(n, at, 6)) return SHORT;
                if (pending || p[at] != 4 || p[at + 5] != 0) return BAD;
                packed = p[at + 1];
                if ((packed & 0xe0) || ((packed >> 2) & 7) > 3) return UNSUP;
                pending = 1; transparent = packed & 1; transparent_index = p[at + 4];
                at += 6;
            } else if (label == 0xfe) {
                if (!v89) return UNSUP;
                r = gif_blocks(p, n, &at, &has_data);
                if (r != OK) return r;
                s->meta = 1;
            } else if (label == 0xff || label == 0x01) {
                unsigned fixed = label == 0xff ? 11 : 12;
                if (!v89) return UNSUP;
                if (!fits(n, at, fixed + 1)) return SHORT;
                if (p[at] != fixed) return BAD;
                at += fixed + 1;
                r = gif_blocks(p, n, &at, &has_data);
                if (r != OK) return r;
                s->meta = 1;
                if (label == 0xff) {
                    /* Application bytes are opaque, including loop/XMP variants. */
                    extension(s);
                } else {
                    /* Plain text is a graphic rendering block, consuming GCE.
                     * This scanner counts images, not text/composited pages. */
                    scope_unknown = 1; pending = 0; transparent = 0;
                    s->f.warnings |= DSH_IMAGE_W_FRAME_SCOPE;
                }
            } else {
                r = gif_blocks(p, n, &at, &has_data);
                if (r != OK) return r;
                extension(s); scope_unknown = 1;
                s->f.warnings |= DSH_IMAGE_W_FRAME_SCOPE;
            }
        } else return BAD;
    }
    return SHORT;
}

DshImageScanStatus dsh_image_scan_container(const uint8_t *p, size_t n,
                                          DshImageContainerFacts *out) {
    Scan s;
    DshImageScanStatus r = DSH_IMAGE_SCAN_UNRECOGNIZED;
    if (!out) return BAD;
    memset(out, 0, sizeof(*out)); memset(&s, 0, sizeof(s));
    if (!p) return n ? BAD : DSH_IMAGE_SCAN_UNRECOGNIZED;
    if (n >= 4 && memcmp(p, "\211PNG", 4) == 0) r = png(&s, p, n);
    else if (n >= 2 && p[0] == 0xff && p[1] == 0xd8) r = jpeg(&s, p, n);
    else if (n >= 4 && tag(p, "RIFF")) r = webp(&s, p, n);
    else if (n >= 3 && memcmp(p, "GIF", 3) == 0) r = gif(&s, p, n);
    if (r == OK) *out = s.f;
    return r;
}
