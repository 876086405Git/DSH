#!/usr/bin/env python3
"""Checks a dsh-Go pet pack directory against the app's import gates.

    python3 pet_pack_check.py <pack-dir> [--compat-reactions]

Mirrors what the app enforces on import: schema-1 parsing and references
(pet_pack.dart), the stricter overlay rules for whole numbers and box x scale
cells (PetPack.kt), sheet bounds, and the complete PNG check (pet_png.dart).
--compat-reactions additionally requires every reaction to be a plain string,
i.e. a pack an older app (before numbered reactions) still accepts.

Standard library only. It cannot replace importing the pack once on a phone.
"""
import argparse
import json
import os
import struct
import sys
import zlib

LIMITS = {
    'json': 262144,
    'sheet': 8388608,
    'sheets': 64,
    'total': 50331648,
    'side': 4096,
    'decoded': 16777216,
    'name': 120,
}


class Check:
    def __init__(self):
        self.problems = []

    def bad(self, code, detail=''):
        self.problems.append(code + (': ' + detail if detail else ''))

    def ok(self):
        return not self.problems


def whole(value, low=0, high=1 << 30):
    return isinstance(value, (int, float)) and not isinstance(value, bool)         and float(value).is_integer() and low <= value <= high


def f32(value):
    return struct.unpack('<f', struct.pack('<f', float(value)))[0]


def kotlin_cell(box_side, scale):
    """(box x scale).toInt() as PetPack.kt computes it: Float multiply, truncate."""
    value = f32(f32(box_side) * float(int(scale)))
    return int(value) if value == value and abs(value) != float('inf') else -1


def check_png(check, name, data):
    if len(data) > LIMITS['sheet']:
        check.bad('png-size', name)
    signature = b'\x89PNG\r\n\x1a\n'
    if len(data) < 33 or data[:8] != signature:
        check.bad('png-header', name)
        return (0, 0)
    width, height = struct.unpack('>II', data[16:24])
    if not (0 < width <= LIMITS['side'] and 0 < height <= LIMITS['side']
            and width * height * 4 <= LIMITS['decoded']):
        check.bad('png-decoded-size', name + ' ' + str(width) + 'x' + str(height))
    depth, colour, interlace = data[24], data[25], data[28]
    allowed = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
    if depth not in allowed.get(colour, ()):
        check.bad('png-format', name)
    if data[26] != 0 or data[27] != 0 or interlace > 1:
        check.bad('png-format', name)
    at, palette, saw_idat, idat_ended, saw_trns, idat, ended = 8, 0, False, False, False, b'', False
    while at < len(data):
        if at + 12 > len(data):
            check.bad('png-chunk', name)
            break
        length = struct.unpack('>I', data[at:at + 4])[0]
        if length > len(data) - at - 12:
            check.bad('png-chunk', name)
            break
        kind = data[at + 4:at + 8]
        if not all((65 <= byte <= 90) or (97 <= byte <= 122) for byte in kind):
            check.bad('png-chunk-type', name)
        if zlib.crc32(data[at + 4:at + 8 + length]) & 0xFFFFFFFF != struct.unpack('>I', data[at + 8 + length:at + 12 + length])[0]:
            check.bad('png-crc', name)
        if kind in (b'acTL', b'fcTL', b'fdAT'):
            check.bad('png-animated', name)
        if kind == b'IHDR' and at != 8:
            check.bad('png-duplicate-header', name)
        if not kind[0] & 32 and kind not in (b'IHDR', b'PLTE', b'IDAT', b'IEND'):
            check.bad('png-critical-chunk', name)
        if kind in (b'iCCP', b'zTXt', b'iTXt', b'tEXt'):
            check.bad('png-metadata', name + ' carries text chunks')
        body = data[at + 8:at + 8 + length]
        if kind == b'PLTE':
            if saw_idat or saw_trns or palette or colour in (0, 4) or not 0 < length <= 768 or length % 3:
                check.bad('png-palette', name)
            palette = length // 3
            if colour == 3 and palette > 1 << depth:
                check.bad('png-palette', name)
        if kind == b'tRNS':
            if saw_idat or saw_trns or not ((colour == 0 and length == 2) or (colour == 2 and length == 6)
                                            or (colour == 3 and palette and 0 < length <= palette)):
                check.bad('png-transparency', name)
            saw_trns = True
        if kind == b'IDAT':
            if idat_ended or (colour == 3 and not palette):
                check.bad('png-idat-order', name)
            saw_idat = True
            idat += body
        elif saw_idat:
            idat_ended = True
        at += length + 12
        if kind == b'IEND':
            if length != 0 or at != len(data):
                check.bad('png-trailing', name)
            ended = True
            break
    if not ended or not saw_idat:
        check.bad('png-truncated', name)
    if len(idat) < 6:
        check.bad('png-zlib', name)
        return (width, height)
    if (idat[0] & 15) != 8 or (idat[0] >> 4) > 7 or (idat[0] * 256 + idat[1]) % 31 or idat[1] & 32:
        check.bad('png-zlib-header', name)
    try:
        raw = zlib.decompressobj(-15).decompress(idat[2:-4])
        if zlib.adler32(raw) & 0xFFFFFFFF != struct.unpack('>I', idat[-4:])[0]:
            check.bad('png-adler', name)
    except zlib.error as error:
        check.bad('png-zlib', name + ' ' + str(error))
        return (width, height)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
    bits = channels * depth
    if interlace == 0:
        rows = [((width * bits + 7) // 8, height)]
    else:
        rows = []
        for px, py, dx, dy in [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                               (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]:
            pw = 0 if width <= px else (width - px + dx - 1) // dx
            ph = 0 if height <= py else (height - py + dy - 1) // dy
            if pw > 0 and ph > 0:
                rows.append(((pw * bits + 7) // 8, ph))
    expected = sum((stride + 1) * count for stride, count in rows)
    if len(raw) != expected:
        check.bad('png-member-size', name)
    else:
        start = 0
        for stride, count in rows:
            for _ in range(count):
                if raw[start] > 4:
                    check.bad('png-filter', name)
                start += stride + 1
    return (width, height)


def check_pack(pack_dir, compat_reactions):
    check = Check()
    path = os.path.join(pack_dir, 'pack.json')
    if not os.path.isfile(path):
        check.bad('pack-missing', path)
        return check
    raw = open(path, 'rb').read()
    if len(raw) > LIMITS['json']:
        check.bad('pack-size', str(len(raw)))
    try:
        pack = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        check.bad('pack-json', str(error))
        return check
    animations = pack.get('animations')
    if not isinstance(animations, dict) or not animations:
        check.bad('animations')
        return check

    scale = pack.get('scale', 1)
    if not whole(scale, 1, LIMITS['side']):
        check.bad('scale', str(scale))
    canvas = pack.get('canvas')
    if not isinstance(canvas, dict) or not whole(canvas.get('w'), 1) or not whole(canvas.get('h'), 1):
        check.bad('canvas')
    content = pack.get('contentBox')
    if not isinstance(content, dict) or not all(isinstance(content.get(k), (int, float)) for k in ('x', 'y', 'w', 'h'))             or content.get('w', 0) <= 0 or content.get('h', 0) <= 0:
        check.bad('contentBox')
    if pack.get('schema') != 1:
        check.bad('schema')
    if not isinstance(pack.get('id'), str) or not pack['id']:
        check.bad('id')

    for name, anim in animations.items():
        if not isinstance(anim, dict):
            check.bad('animation', name)
            continue
        for key, high in (('frameW', LIMITS['side']), ('frameH', LIMITS['side']), ('cols', LIMITS['side'])):
            if not whole(anim.get(key), 1, high):
                check.bad('frame-int', name + '.' + key)
        box = anim.get('box')
        if not isinstance(box, dict) or not isinstance(box.get('w'), (int, float)) or not isinstance(box.get('h'), (int, float)):
            check.bad('box', name)
            continue
        if kotlin_cell(box['w'], scale) != anim.get('frameW') or kotlin_cell(box['h'], scale) != anim.get('frameH'):
            check.bad('cell', name + ': frameW/frameH != trunc(box x scale)')
        frames = anim.get('frames')
        if not isinstance(frames, list) or not frames:
            check.bad('frames', name)
            continue
        for frame in frames:
            if not isinstance(frame, dict) or not whole(frame.get('i')) or not whole(frame.get('ms'), 1):
                check.bad('frame-item', name)
                break
        if not isinstance(anim.get('sheet'), str) or anim['sheet'].startswith('.')                 or '/' in anim['sheet'] or '\\' in anim['sheet'] or not anim['sheet'].lower().endswith('.png'):
            check.bad('sheet-name', name)

    def known(name, where):
        if name not in animations:
            check.bad('reference', where + ' -> ' + str(name))

    states = pack.get('states') or {}
    if not isinstance(states, dict) or 'idle' not in states:
        check.bad('states-idle')
    for key, value in states.items():
        for name in value if isinstance(value, list) else []:
            known(name, 'states.' + str(key))
    for key, tiers in (pack.get('tiers') or {}).items():
        for tier in tiers if isinstance(tiers, list) else []:
            known(tier.get('anim'), 'tiers.' + str(key))
    for key, value in (pack.get('reactions') or {}).items():
        if isinstance(value, list):
            if compat_reactions:
                check.bad('compat-reactions', key + ' is a list; older apps reject it')
            if not value:
                check.bad('reactions-empty', key)
            for name in value:
                known(name, 'reactions.' + str(key))
        else:
            known(value, 'reactions.' + str(key))
    roam = pack.get('roam') or {}
    if roam.get('anim') is not None:
        known(roam['anim'], 'roam')
    pool = pack.get('idlePool')
    for item in ((pool.get('anims') if isinstance(pool, dict) else pool) or []):
        known(item.get('anim'), 'idlePool')
    for key, bonus in (pack.get('bonus') or {}).items():
        for name in bonus.get('anims') or []:
            known(name, 'bonus.' + str(key))

    sheets = sorted({anim['sheet'] for anim in animations.values() if isinstance(anim.get('sheet'), str)})
    if len(sheets) > LIMITS['sheets']:
        check.bad('sheet-count', str(len(sheets)))
    total = 0
    sizes = {}
    for sheet in sheets:
        path = os.path.join(pack_dir, sheet)
        if not os.path.isfile(path):
            check.bad('sheet-missing', sheet)
            continue
        data = open(path, 'rb').read()
        total += len(data)
        if total > LIMITS['total']:
            check.bad('sheet-total-size')
        sizes[sheet] = check_png(check, sheet, data)
    for name, anim in animations.items():
        width, height = sizes.get(anim.get('sheet'), (0, 0))
        if not width or not height:
            continue
        last = max((frame.get('i', 0) for frame in anim.get('frames') or []), default=0)
        if not (anim['cols'] <= width // anim['frameW'] and last // anim['cols'] < height // anim['frameH']):
            check.bad('sheet-frame-bounds', name)
    return check


def main(argv=None):
    parser = argparse.ArgumentParser(description='Check a dsh-Go pet pack before importing it.')
    parser.add_argument('pack_dir')
    parser.add_argument('--compat-reactions', action='store_true',
                        help='also require plain-string reactions (older apps)')
    args = parser.parse_args(argv)
    check = check_pack(args.pack_dir, args.compat_reactions)
    if check.ok():
        print('PASS: the pack passes the import checks' + (' (old-app reactions)' if args.compat_reactions else ''))
        return 0
    print('FAIL: ' + str(len(check.problems)) + ' problem(s)')
    for problem in check.problems[:40]:
        print(' - ' + problem)
    return 1


if __name__ == '__main__':
    sys.exit(main())
