#!/usr/bin/env python3
"""Builds the runtime pet packs in assets/pets/<id>/ from the source art in tool/pet_src.

Run from app/ (needs Pillow and numpy):

    python3 tool/make_pet_pack.py [--src DIR] [--out DIR] [--preview DIR] [--only ID]

`--src` defaults to tool/pet_src (in git), `--out` to assets/pets and
`--preview` to build/pet_preview (pass `--preview ''` to skip).
The output is deterministic: running it twice gives byte-identical files.

Two source formats, both mapped onto Clawd on Desk's states (our pet protocol):

* Clawd on Desk theme (pet_src/deepy-whale/): theme.json plus one APNG per animation in
  assets/. Frames are decoded in order and each keeps its own delay, read straight
  from the APNG's fcTL chunks. states / workingTiers / jugglingTiers /
  idleAnimations / reactions / timings come from theme.json.
* Whale-girl sticker set (pet_src/whale-girl/, from https://dshtui.com/pets/whale-girl-emoji/;
  rig/ is the layered master, kept for reference): sheets/<key>.png are 1x strips (69x66
  cells); per-frame durations come from index.html's `set-data` JSON and are
  cross-checked against gifs/NN-<key>.gif (8x export: the GIF merges consecutive
  identical frames, so the strip is collapsed the same way before comparing
  durations and pixels). The state mapping follows the page's Clawd table.

Decisions (measured on every run, the build fails when an assumption breaks):

1. Scale. A theme's APNGs are N x its viewBox. If every frame is an exact
   nearest-neighbour blow-up of a 1x frame (downscale, scale back up, compare
   pixel by pixel) the pack is stored at 1x; otherwise at N and pack.json says
   `"scale": N`. Deepy's body sits on half-pixel x and squashes in 1/5-pixel
   steps, so it stays at 5x.
2. idle-follow.svg (eyes follow the mouse; CSS breathing, blinking, tail poses) is
   not converted: a phone has no pointer, the CSS animation needs a browser engine
   to rasterise, and the theme's own idle.apng is the same pose breathing at the
   same 2.4 s period, rendered by the author at the pack's exact pixels. idle.apng
   becomes the base idle loop; idle-look / idle-spout go to `idlePool`.
3. Storage. Per animation: crop to the union of its non-transparent pixels
   (rounded out to whole logical pixels: `box`), store each distinct frame once
   (`frames[].i` may repeat), pack the cells row-major in a grid at most 4096 px
   on a side (GPU texture limit on older phones). Fully transparent pixels are
   written as 0,0,0,0. A sheet with at most 256 RGBA colours is written as an
   indexed PNG with a tRNS table (lossless), otherwise as RGBA.
4. Anchor. `baseline` is the bottom edge of the lowest opaque (alpha >= 128) row,
   the mode over the base idle loop's frames: the feet line that sits on a perch.
   Deepy's 22 % shadow is below it (Clawd's baselineY 48.5 is the shadow's centre
   line; the body ends at 48). `x` is the opaque centroid averaged over the idle
   loop, rounded to 0.5. `contentBox` is the union of the idle loop's opaque
   pixels, rounded out to whole logical pixels: layout and size.
5. Hit boxes, measured on the logical grid (a cell is body when any of its pixels
   has alpha >= 128). Per frame the body is the largest 8-connected blob, so
   detached props (thought cloud, Zzz, notes, sparkles) never catch taps; per
   animation the body box covers the cells that are body for at least
   OCCUPANCY of its running time, so a flip's apex or a flying nightcap does not
   inflate it. Clawd's classes: `default` is the base idle's box, `sleeping` the
   sleeping animations'; an animation reaching more than WIDE_MARGIN past
   `default` is listed in `wideAnims` and widens `wide`; one reaching more than
   OWN_MARGIN past it, or covering less than VACATE of it (lifted by a drag), gets
   its own box in `byAnim` instead of inflating `wide` for everyone. An animation
   whose body spends more than 1 - CATCH of its time outside `default` (a flip)
   is wide too; the build fails if any animation's box catches less than CATCH.
6. Timings. Deepy keeps theme.json's, except that notification has no
   autoReturn: it holds until the approval or question is dealt with
   (docs/design/pets.md section 12 #7). Whale-girl keeps the rhythm of
   her page: each temporary state lasts the number of loops the page's
   event table holds it (`hold`; error 1, happy 2, notification 3, carrying 2,
   waking 1); compacting has no hold there (it stays until the next event), so
   its minDisplay is one loop. working / thinking debounce (1000) and the
   sweeping cap (300000) are not loops and stay as in Deepy's theme. One-shot animations (`loop: false`) are waking and
   the tap / tickle reactions. idlePool entries play 2 loops (Clawd's
   idleAnimations durations, whale-girl's own loops); whale-girl's
   smile-hearts / thumbs-up are the attention `bonus`.

Format reference: docs/design/pets.md section 3.
"""
import argparse
import json
import math
import os
import re
import struct
import sys
from collections import Counter

import numpy as np
from PIL import Image, ImageDraw, ImageFont

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC = os.path.join(APP, 'tool', 'pet_src')
DEFAULT_OUT = os.path.join(APP, 'assets', 'pets')
DEFAULT_PREVIEW = os.path.join(APP, 'build', 'pet_preview')

SCHEMA = 1
MAX_SHEET = 4096          # px per sheet side
OPAQUE = 128              # alpha at or above which a pixel counts as body

# Clawd on Desk state names, in display order.
STATES = ['idle', 'thinking', 'working', 'juggling', 'error', 'attention', 'notification',
          'sweeping', 'carrying', 'sleeping', 'waking', 'roam']
REACTIONS = ['tapLeft', 'tapRight', 'tickle', 'drag']

# The reference timings (Deepy's theme.json): the keys every pack carries; whale-girl
# replaces the loop-based ones with her page's holds.
REFERENCE_TIMINGS = {
    'minDisplay': {'attention': 5200, 'error': 4800, 'sweeping': 5600, 'notification': 3200,
                   'carrying': 3200, 'working': 1000, 'thinking': 1000},
    'autoReturn': {'attention': 5200, 'error': 4800, 'sweeping': 300000, 'carrying': 3200},
}
HOLDING = ['notification']    # held until resolved: never in autoReturn
# Entries that are debounce or a safety cap, not a number of loops.
NOT_LOOPS = {('minDisplay', 'working'), ('minDisplay', 'thinking'), ('autoReturn', 'sweeping')}
VARIANT_LOOPS = 2         # an idlePool entry plays this many loops, then back to the base idle
IDLE_EVERY_MS = {'mean': 120000, 'min': 45000, 'max': 300000}
BONUS_CHANCE = 0.2
SLEEP_AFTER_MS = 60000

# Hit boxes (decision 5).
OCCUPANCY = 0.25
WIDE_MARGIN = 2
OWN_MARGIN = 8
VACATE = 0.5
CATCH = 0.9               # every animation's hit box holds at least this share of its body

PACKS = {
    'deepy-whale': dict(
        kind='clawd', dir='deepy-whale',
        name='Deepy 小鲸鱼',
        author='DSH-TUI',
        license='DSH-TUI 吉祥物，作者授权 dsh-go 使用',
        source='DSH-TUI（Clawd on Desk 主题包 v1.0.0）',
        faces='left',
        preview_zoom=2, preview_per_row=24,
    ),
    'whale-girl': dict(
        kind='whale-girl', dir='whale-girl',
        name='鲸娘',
        author='DSH-TUI',
        license='DSH-TUI 吉祥物，作者授权 dsh-go 使用',
        source='https://dshtui.com/pets/whale-girl-emoji/',
        faces='front',     # she faces the viewer: never mirrored
        preview_zoom=3, preview_per_row=12,
    ),
}

# Whale-girl: Clawd mapping from the page's event table (index.html, AGENT / MOUSE).
# Each animation's `state` label on the page is checked against this.
WHALE_GIRL = dict(
    states={
        'idle': ['idle'],
        'thinking': ['thinking'], 'working': ['typing'], 'juggling': ['music'],
        'error': ['error'], 'attention': ['happy'],
        'notification': ['notification'], 'sweeping': ['compacting'], 'carrying': ['carrying'],
        'sleeping': ['sleeping'], 'waking': ['waking'], 'roam': ['swim'],
    },
    tiers={
        'working': [{'min': 3, 'anim': 'building'}, {'min': 2, 'anim': 'music'},
                    {'min': 1, 'anim': 'typing'}],
        'juggling': [{'min': 2, 'anim': 'conducting'}, {'min': 1, 'anim': 'music'}],
    },
    idle_pool=['idle-look', 'idle-spout'],
    # "不绑定事件，可做完成时的随机彩蛋"
    bonus={'attention': ['smile-hearts', 'thumbs-up']},
    reactions={'tapLeft': 'poke-left', 'tapRight': 'poke-right', 'tickle': 'tickle',
               'drag': 'drag'},
    page_states={         # anim -> the page's `state` label
        'idle': 'idle', 'idle-look': 'idle', 'idle-spout': 'idle', 'thinking': 'thinking',
        'typing': 'working', 'music': 'working', 'building': 'working',
        'conducting': 'juggling', 'error': 'error', 'happy': 'attention',
        'notification': 'notification', 'compacting': 'sweeping', 'carrying': 'carrying',
        'sleeping': 'sleeping', 'waking': 'waking', 'poke-left': 'reaction',
        'poke-right': 'reaction', 'tickle': 'reaction', 'drag': 'reaction',
        'swim': 'idle · roam', 'smile-hearts': 'bonus', 'thumbs-up': 'bonus',
    },
)


class BuildError(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise BuildError(msg)


# ---------------------------------------------------------------- decoding


def clean(a):
    """RGBA uint8 copy with every fully transparent pixel set to 0,0,0,0."""
    a = np.array(a, dtype=np.uint8, copy=True)
    a[a[..., 3] == 0] = 0
    return a


def read_text(path):
    with open(path, encoding='utf-8') as fh:
        return fh.read()


def read_rgba(path):
    with Image.open(path) as im:
        return np.asarray(im.convert('RGBA'))


def png_chunks(path):
    with open(path, 'rb') as fh:
        data = fh.read()
    check(data[:8] == b'\x89PNG\r\n\x1a\n', f'{path}: not a PNG')
    p = 8
    while p < len(data):
        (n,) = struct.unpack('>I', data[p:p + 4])
        yield data[p + 4:p + 8], data[p + 8:p + 8 + n]
        p += 12 + n


def apng_delays(path):
    """Per-frame delay in ms from the fcTL chunks (delay_num / delay_den, den 0 = 100)."""
    out = []
    for ctype, body in png_chunks(path):
        if ctype == b'fcTL':
            num, den = struct.unpack('>HH', body[20:24])
            ms = 1000 * num / (den or 100)
            check(ms == int(ms) and ms > 0, f'{path}: delay {num}/{den} is not a whole ms')
            out.append(int(ms))
    return out


def read_apng(path):
    delays = apng_delays(path)
    frames = []
    with Image.open(path) as im:
        n = getattr(im, 'n_frames', 1)
        check(n == len(delays), f'{path}: {n} frames but {len(delays)} fcTL chunks')
        for i in range(n):
            im.seek(i)
            frames.append(clean(np.asarray(im.convert('RGBA'))))
    return frames, delays


def read_gif(path):
    frames, durs = [], []
    with Image.open(path) as im:
        for i in range(getattr(im, 'n_frames', 1)):
            im.seek(i)
            durs.append(int(im.info['duration']))
            frames.append(clean(np.asarray(im.convert('RGBA'))))
    return frames, durs


def downscale_exact(a, f):
    """The 1x frame if `a` is an exact f x nearest-neighbour blow-up of one, else None."""
    small = a[::f, ::f]
    return small if np.array_equal(np.repeat(np.repeat(small, f, 0), f, 1), a) else None


def merge_repeats(frames, durs):
    """Collapse consecutive identical frames, summing their durations (what a GIF does)."""
    mf, md = [], []
    for f, d in zip(frames, durs):
        if mf and np.array_equal(mf[-1], f):
            md[-1] += d
        else:
            mf.append(f)
            md.append(d)
    return mf, md


# ---------------------------------------------------------------- sources


def load_clawd(src, meta):
    """Clawd on Desk theme -> (canvas, scale, anims, mapping)."""
    root = os.path.join(src, meta['dir'])
    theme = json.loads(read_text(os.path.join(root, 'theme.json')))
    vb = theme['viewBox']
    cw, ch = int(vb['width']), int(vb['height'])
    stem = lambda f: os.path.splitext(f)[0]

    files = sorted(f for f in os.listdir(os.path.join(root, 'assets')) if f.endswith('.apng'))
    anims, factor = {}, None
    for f in files:
        frames, delays = read_apng(os.path.join(root, 'assets', f))
        h, w = frames[0].shape[:2]
        check(w % cw == 0 and h % ch == 0 and w // cw == h // ch,
              f'{f}: {w}x{h} is not a whole multiple of the {cw}x{ch} viewBox')
        check(factor in (None, w // cw), f'{f}: export scale differs from the other files')
        factor = w // cw
        check(all(fr.shape == frames[0].shape for fr in frames), f'{f}: frame sizes differ')
        anims[stem(f)] = dict(frames=frames, durs=delays, source=f)

    # Decision 1: store at 1x only when that is lossless for every frame of every file.
    lossless = all(downscale_exact(fr, factor) is not None
                   for a in anims.values() for fr in a['frames'])
    scale = 1 if lossless else factor
    if lossless:
        for a in anims.values():
            a['frames'] = [downscale_exact(fr, factor) for fr in a['frames']]

    # Decision 2: the base idle loop replaces idle-follow.svg.
    idle_files = [stem(x['file']) for x in theme.get('idleAnimations', [])]
    base_idle = 'idle' if 'idle' in anims else idle_files[0]
    states = {}
    for s in STATES:
        names = [base_idle if f.endswith('.svg') else stem(f) for f in theme['states'].get(s, [])]
        check(names, f'theme has no animation for state {s}')
        states[s] = names
    idle_pool = []
    for x in theme.get('idleAnimations', []):
        n = stem(x['file'])
        if n != base_idle:
            check(int(x['duration']) == VARIANT_LOOPS * sum(anims[n]['durs']),
                  f'idleAnimations {n}: {x["duration"]} ms is not {VARIANT_LOOPS} loops')
            idle_pool.append({'anim': n, 'ms': int(x['duration']), 'weight': 1})

    tiers = {}
    for key, s in (('workingTiers', 'working'), ('jugglingTiers', 'juggling')):
        if theme.get(key):
            tiers[s] = [{'min': t['minSessions'], 'anim': stem(t['file'])} for t in theme[key]]

    r = theme['reactions']
    reactions = {
        'tapLeft': stem(r['clickLeft']['file']),
        'tapRight': stem(r['clickRight']['file']),
        'tickle': stem(r['double']['files'][0]),
        'drag': stem(r['drag']['file']),
    }

    tm = theme['timings']
    timings = {'minDisplay': dict(tm['minDisplay']),
               'autoReturn': {s: ms for s, ms in tm['autoReturn'].items() if s not in HOLDING},
               'wakeMs': int(tm.get('wakeDuration', sum(anims[states['waking'][0]]['durs'])))}
    # Reaction durations in theme.json are one loop of the file (they are one-shots).
    for key, rk in (('clickLeft', 'tapLeft'), ('clickRight', 'tapRight'), ('double', 'tickle')):
        if 'duration' in r[key]:
            check(int(r[key]['duration']) == sum(anims[reactions[rk]]['durs']),
                  f'reaction {key}: duration is not one loop')
    # roamFlipAssets: the art faces left and is mirrored to walk right.
    check(meta['faces'] in ('left', 'right') if theme.get('roamFlipAssets') else True,
          'roamFlipAssets needs faces left or right')

    mapping = dict(
        states=states, tiers=tiers, reactions=reactions, timings=timings,
        idle_pool=idle_pool, bonus={},
        roam={'anim': states['roam'][0], 'faces': meta['faces']},
        sleep={'afterMs': int(tm.get('mouseSleepTimeout', SLEEP_AFTER_MS))},
        base_idle=base_idle,
        clawd_layout=theme.get('layout', {}),
        clawd_hit=dict(boxes=theme.get('hitBoxes', {}), wide=theme.get('wideHitboxFiles', []),
                       sleeping=theme.get('sleepingHitboxFiles', []),
                       files=theme.get('fileHitBoxes', {})),
    )
    one_shot = {states['waking'][0], reactions['tapLeft'], reactions['tapRight'],
                reactions['tickle']}
    for n, a in anims.items():
        a['loop'] = n not in one_shot
    # theme.json's wake duration and reaction durations are one loop of the file.
    if 'wakeDuration' in tm:
        check(sum(anims[states['waking'][0]]['durs']) == tm['wakeDuration'],
              'wakeDuration is not one loop of the waking animation')
    return (cw, ch), scale, factor, anims, mapping


def page_holds(html):
    """anim -> loops held, from the page's agent-event table (`const AGENT = [...]`):
    `{ code: …, name: …, key: 'error', hold: 1 }`. Entries without `hold` stay until the
    next event (persistent); they get one loop as their minimum."""
    m = re.search(r'const AGENT = \[(.*?)\];', html, re.S)
    check(m, 'index.html: no AGENT event table')
    holds = {}
    for key, hold in re.findall(r"key: '([\w-]+)'(?:, hold: (\d+))?", m.group(1)):
        if hold:
            holds[key] = int(hold)
    check(holds, 'index.html: AGENT table has no holds')
    return holds


def load_whale_girl(src, meta):
    root = os.path.join(src, meta['dir'])
    html = read_text(os.path.join(root, 'index.html'))
    m = re.search(r'<script type="application/json" id="set-data">(.*?)</script>', html, re.S)
    check(m, 'index.html: no set-data JSON')
    data = json.loads(m.group(1))
    cw, ch = int(data['w']), int(data['h'])
    anims = {}
    for a in data['anims']:
        key, durs = a['key'], [int(d) for d in a['durs']]
        check(WHALE_GIRL['page_states'].get(key) == a['state'],
              f'{key}: page state {a["state"]!r} does not match the mapping')
        sheet = read_rgba(os.path.join(root, 'sheets', f'{key}.png'))
        check(sheet.shape[0] == ch and sheet.shape[1] == cw * len(durs),
              f'sheets/{key}.png: {sheet.shape[1]}x{sheet.shape[0]} for {len(durs)} frames of {cw}x{ch}')
        frames = [clean(sheet[:, i * cw:(i + 1) * cw]) for i in range(len(durs))]

        # Cross-check against the GIF export: same timing, same pixels.
        gif = os.path.join(root, 'gifs', f'{a["i"]:02d}-{key}.gif')
        gframes, gdurs = read_gif(gif)
        mf, md = merge_repeats(frames, durs)
        check(md == gdurs, f'{key}: index.html durations {durs} != GIF {gdurs} (after merging repeats)')
        gf = gframes[0].shape[1] // cw
        check(gframes[0].shape[:2] == (ch * gf, cw * gf), f'{gif}: not a whole multiple of {cw}x{ch}')
        for k, (s, g) in enumerate(zip(mf, gframes)):
            g1 = downscale_exact(g, gf)
            check(g1 is not None and np.array_equal(clean(g1), s),
                  f'{key}: GIF frame {k} differs from the sheet')
        anims[key] = dict(frames=frames, durs=durs, source=f'sheets/{key}.png')

    W = WHALE_GIRL
    states = {s: list(v) for s, v in W['states'].items()}
    reactions = dict(W['reactions'])
    loop_ms = {n: sum(a['durs']) for n, a in anims.items()}

    # Her page's rhythm: how many loops the page holds each temporary state.
    holds = page_holds(html)

    def held(state):
        anim = states[state][0]
        return holds.get(anim, 1) * loop_ms[anim]

    timings = {}
    for group, vals in REFERENCE_TIMINGS.items():
        timings[group] = {s: (ms if (group, s) in NOT_LOOPS else held(s)) for s, ms in vals.items()}
    timings['wakeMs'] = held('waking')

    mapping = dict(
        states=states, tiers=W['tiers'], reactions=reactions, timings=timings,
        idle_pool=[{'anim': n, 'ms': VARIANT_LOOPS * loop_ms[n], 'weight': 1} for n in W['idle_pool']],
        bonus={s: {'anims': list(v), 'chance': BONUS_CHANCE} for s, v in W['bonus'].items()},
        roam={'anim': states['roam'][0], 'faces': meta['faces']},
        sleep={'afterMs': SLEEP_AFTER_MS},
        base_idle='idle',
        clawd_layout={},
        clawd_hit=None,
    )
    one_shot = {states['waking'][0], reactions['tapLeft'], reactions['tapRight'],
                reactions['tickle']}
    for n, a in anims.items():
        a['loop'] = n not in one_shot
    return (cw, ch), 1, 8, anims, mapping


# ---------------------------------------------------------------- measuring


def ground(fr, scale):
    """Bottom edge (logical px) of the lowest opaque row, or None for an empty frame."""
    ys = np.nonzero((fr[..., 3] >= OPAQUE).any(axis=1))[0]
    return (int(ys[-1]) + 1) / scale if len(ys) else None


def mode(values):
    """Most common value; a tie goes to the smallest (the higher line: rest, not the bob)."""
    c = Counter(v for v in values if v is not None)
    best = max(c.values())
    return min(v for v, k in c.items() if k == best)


def measure(anims, scale, base_idle):
    idle = anims[base_idle]['frames']
    baseline = mode(ground(f, scale) for f in idle)
    xs = []
    union = np.zeros(idle[0].shape[:2], bool)
    for f in idle:
        m = f[..., 3] >= OPAQUE
        union |= m
        xs.append((np.nonzero(m)[1] + 0.5).mean() / scale)
    ax = round(float(np.mean(xs)) * 2) / 2
    ys, xs_ = np.nonzero(union)
    box = dict(x=int(xs_.min() // scale), y=int(ys.min() // scale))
    box['w'] = int(math.ceil((xs_.max() + 1) / scale)) - box['x']
    box['h'] = int(math.ceil((ys.max() + 1) / scale)) - box['y']
    # Per animation: frames standing exactly on the baseline, and the deepest dip below it
    # (tilted body corners, a squash, a bob: authored, not an offset).
    contact = {}
    for n, a in anims.items():
        g = [ground(f, scale) for f in a['frames']]
        contact[n] = (sum(1 for v in g if v == baseline), len(g),
                      max(0.0, max(v for v in g if v is not None) - baseline))
    return dict(anchor={'x': num(ax), 'baseline': num(baseline)}, contentBox=box, contact=contact)


def num(v):
    v = float(v)
    return int(v) if v.is_integer() else round(v, 2)


def body_cells(fr, scale):
    """The largest 8-connected blob of opaque logical cells (a cell is opaque when any of
    its scale x scale pixels has alpha >= OPAQUE), as a bool grid."""
    h, w = fr.shape[0] // scale, fr.shape[1] // scale
    grid = (fr[..., 3] >= OPAQUE).reshape(h, scale, w, scale).any(axis=(1, 3))
    seen = np.zeros_like(grid)
    best = []
    for y0, x0 in zip(*np.nonzero(grid)):
        if seen[y0, x0]:
            continue
        seen[y0, x0] = True
        stack, blob = [(int(y0), int(x0))], []
        while stack:
            y, x = stack.pop()
            blob.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w and grid[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
        if len(blob) > len(best):
            best = blob
    out = np.zeros_like(grid)
    for y, x in best:
        out[y, x] = True
    return out


def body_box(anim, scale):
    """Box of the cells that are body for at least OCCUPANCY of the animation's time,
    and the occupancy grid itself (share of time each cell is body)."""
    cache, occ = {}, None
    for fr, ms in zip(anim['frames'], anim['durs']):
        k = fr.tobytes()
        if k not in cache:
            cache[k] = body_cells(fr, scale)
        b = cache[k] * ms
        occ = b if occ is None else occ + b
    occ = occ / sum(anim['durs'])
    ys, xs = np.nonzero(occ >= OCCUPANCY)
    return {'x': int(xs.min()), 'y': int(ys.min()),
            'w': int(xs.max()) + 1 - int(xs.min()), 'h': int(ys.max()) + 1 - int(ys.min())}, occ


def catches(b, occ):
    """Share of an animation's body (cells x time) inside box b."""
    return occ[b['y']:b['y'] + b['h'], b['x']:b['x'] + b['w']].sum() / occ.sum()


def union_box(boxes):
    x0 = min(b['x'] for b in boxes)
    y0 = min(b['y'] for b in boxes)
    x1 = max(b['x'] + b['w'] for b in boxes)
    y1 = max(b['y'] + b['h'] for b in boxes)
    return {'x': x0, 'y': y0, 'w': x1 - x0, 'h': y1 - y0}


def reach(b, d):
    """How far (logical px) box b reaches past box d on its farthest side."""
    return max(d['x'] - b['x'], b['x'] + b['w'] - d['x'] - d['w'],
               d['y'] - b['y'], b['y'] + b['h'] - d['y'] - d['h'], 0)


def covered(b, d):
    """Share of box d that box b covers."""
    w = min(b['x'] + b['w'], d['x'] + d['w']) - max(b['x'], d['x'])
    h = min(b['y'] + b['h'], d['y'] + d['h']) - max(b['y'], d['y'])
    return max(0, w) * max(0, h) / (d['w'] * d['h'])


def hit_boxes(anims, scale, mapping, order):
    """Clawd's three classes plus per-animation overrides, all measured (decision 5)."""
    measured = {n: body_box(anims[n], scale) for n in order}
    boxes = {n: b for n, (b, _) in measured.items()}
    default = boxes[mapping['base_idle']]
    sleeping_anims = [n for n in order if n in mapping['states']['sleeping']]
    wide_anims, by_anim = [], {}
    for n in order:
        if n == mapping['base_idle'] or n in sleeping_anims:
            continue
        b, occ = measured[n]
        if covered(b, default) < VACATE or reach(b, default) > OWN_MARGIN:
            by_anim[n] = b
        elif reach(b, default) > WIDE_MARGIN or catches(default, occ) < CATCH:
            wide_anims.append(n)
    hits = {
        'default': default,
        'wide': union_box([default] + [boxes[n] for n in wide_anims]),
        'sleeping': union_box([boxes[n] for n in sleeping_anims]),
        'byAnim': by_anim,
        'wideAnims': wide_anims,
        'sleepingAnims': sleeping_anims,
    }
    for n in order:
        box = (by_anim.get(n) or (hits['sleeping'] if n in sleeping_anims else None)
               or (hits['wide'] if n in wide_anims else default))
        share = catches(box, measured[n][1])
        check(share >= CATCH, f'{n}: its hit box catches only {share:.0%} of the body')
    return hits, boxes


# ---------------------------------------------------------------- writing


def anim_box(frames, scale):
    """Union of non-transparent pixels, rounded out to whole logical px: (x, y, w, h) logical."""
    union = np.zeros(frames[0].shape[:2], bool)
    for f in frames:
        union |= f[..., 3] > 0
    ys, xs = np.nonzero(union)
    check(len(xs), 'animation is fully transparent')
    x0, y0 = int(xs.min() // scale), int(ys.min() // scale)
    x1, y1 = int(math.ceil((xs.max() + 1) / scale)), int(math.ceil((ys.max() + 1) / scale))
    return x0, y0, x1 - x0, y1 - y0


def save_png(a, path):
    """Lossless PNG: indexed + tRNS when the image has at most 256 RGBA colours."""
    flat = a.reshape(-1, 4)
    colors, inverse = np.unique(flat, axis=0, return_inverse=True)
    if len(colors) <= 256:
        im = Image.fromarray(inverse.reshape(a.shape[:2]).astype(np.uint8), 'P')
        im.putpalette(colors[:, :3].astype(np.uint8).tobytes())
        im.save(path, optimize=True, transparency=colors[:, 3].astype(np.uint8).tobytes())
    else:
        Image.fromarray(a, 'RGBA').save(path, optimize=True)
    back = read_rgba(path)
    check(np.array_equal(back, a), f'{path}: PNG round trip is not lossless')


def write_anim(name, anim, scale, out_dir):
    frames = anim['frames']
    bx, by, bw, bh = anim_box(frames, scale)
    fw, fh = bw * scale, bh * scale
    cells, index, seq = [], {}, []
    for f in frames:
        c = np.ascontiguousarray(f[by * scale:by * scale + fh, bx * scale:bx * scale + fw])
        k = c.tobytes()
        if k not in index:
            index[k] = len(cells)
            cells.append(c)
        seq.append(index[k])
    n = len(cells)
    max_cols = MAX_SHEET // fw
    check(max_cols >= 1, f'{name}: a {fw} px frame does not fit a {MAX_SHEET} px sheet')
    rows = math.ceil(n / max_cols)
    cols = math.ceil(n / rows)
    check(rows * fh <= MAX_SHEET, f'{name}: {rows} rows of {fh} px exceed {MAX_SHEET} px')
    sheet = np.zeros((rows * fh, cols * fw, 4), np.uint8)
    for i, c in enumerate(cells):
        r, k = divmod(i, cols)
        sheet[r * fh:(r + 1) * fh, k * fw:(k + 1) * fw] = c
    file = f'{name}.png'
    save_png(sheet, os.path.join(out_dir, file))
    return {
        'sheet': file, 'frameW': fw, 'frameH': fh, 'cols': cols,
        'box': {'x': bx, 'y': by, 'w': bw, 'h': bh},
        'loop': anim['loop'],
        'ms': sum(anim['durs']),
        'frames': [{'i': i, 'ms': d} for i, d in zip(seq, anim['durs'])],
    }


def anim_order(mapping, names):
    """States first (in STATES order, each followed by its idle pool / tiers / bonus),
    then reactions, then anything left."""
    order = []
    for s in STATES:
        order += mapping['states'][s]
        if s == 'idle':
            order += [x['anim'] for x in mapping['idle_pool']]
        order += [t['anim'] for t in mapping['tiers'].get(s, [])]
        order += mapping['bonus'].get(s, {}).get('anims', [])
    order += [mapping['reactions'][r] for r in REACTIONS]
    order += sorted(names)
    seen = []
    for n in order:
        if n in names and n not in seen:
            seen.append(n)
    return seen


def dumps(obj, indent=0):
    """JSON with one animation (and its frame list) per few lines."""
    pad = '  ' * indent
    compact = json.dumps(obj, ensure_ascii=False, separators=(', ', ': '))
    if not isinstance(obj, (dict, list)) or len(compact) <= 96 or (
            isinstance(obj, list) and obj and all(isinstance(x, dict) and 'i' in x for x in obj)) or (
            isinstance(obj, list) and all(isinstance(x, str) for x in obj)):
        return compact
    if isinstance(obj, list):
        inner = ',\n'.join(pad + '  ' + dumps(x, indent + 1) for x in obj)
        return '[\n' + inner + '\n' + pad + ']'
    inner = ',\n'.join(f'{pad}  {json.dumps(k, ensure_ascii=False)}: {dumps(v, indent + 1)}'
                       for k, v in obj.items())
    return '{\n' + inner + '\n' + pad + '}'


def build(pack_id, src, out_root, log=print):
    meta = PACKS[pack_id]
    loader = load_clawd if meta['kind'] == 'clawd' else load_whale_girl
    (cw, ch), scale, export, anims, mapping = loader(src, meta)
    for n, a in anims.items():
        check(len(a['frames']) == len(a['durs']) > 0, f'{n}: frame / duration count mismatch')
        check(all(f.shape == (ch * scale, cw * scale, 4) for f in a['frames']),
              f'{n}: frame size is not the canvas at scale {scale}')

    m = measure(anims, scale, mapping['base_idle'])
    out_dir = os.path.join(out_root, pack_id)
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith('.png') or f == 'pack.json':
            os.remove(os.path.join(out_dir, f))

    order = anim_order(mapping, set(anims))
    hits, bodies = hit_boxes(anims, scale, mapping, order)
    animations = {n: write_anim(n, anims[n], scale, out_dir) for n in order}
    pack = {
        'schema': SCHEMA,
        'id': pack_id,
        'name': meta['name'],
        'author': meta['author'],
        'license': meta['license'],
        'source': meta['source'],
        'pixelArt': True,
        'scale': scale,
        'canvas': {'w': cw, 'h': ch},
        'anchor': m['anchor'],
        'contentBox': m['contentBox'],
        'hitBoxes': hits,
        'animations': animations,
        'idlePool': {'everyMs': dict(IDLE_EVERY_MS), 'anims': mapping['idle_pool']},
        'states': mapping['states'],
        'bonus': mapping['bonus'],
        'tiers': mapping['tiers'],
        'timings': mapping['timings'],
        'reactions': mapping['reactions'],
        'roam': mapping['roam'],
        'sleep': mapping['sleep'],
    }
    with open(os.path.join(out_dir, 'pack.json'), 'w', encoding='utf-8') as fh:
        fh.write(dumps(pack) + '\n')

    # Report.
    total = sum(os.path.getsize(os.path.join(out_dir, f)) for f in os.listdir(out_dir))
    log(f'{pack_id}: {len(anims)} animations, {sum(len(a["durs"]) for a in anims.values())} frames '
        f'({sum(len(set(f["i"] for f in a["frames"])) for a in animations.values())} stored), '
        f'scale {scale} (source export {export}x), {total / 1024:.0f} KB')
    log(f'  anchor {m["anchor"]}  contentBox {m["contentBox"]}')
    cl = mapping['clawd_layout']
    if cl:
        log(f'  theme.json: centerX {cl.get("centerX")}  baselineY {cl.get("baselineY")}  '
            f'contentBox {cl.get("contentBox")}')
    log(f'  hitBoxes default {hits["default"]}  wide {hits["wide"]}  sleeping {hits["sleeping"]}')
    log(f'    wideAnims {hits["wideAnims"]}  byAnim {hits["byAnim"]}')
    ch_ = mapping['clawd_hit']
    if ch_:
        log(f'  theme.json hitBoxes {ch_["boxes"]}  wide files {ch_["wide"]}  file boxes {ch_["files"]}')
    log('  on baseline (frames) / deepest dip below it (logical px):')
    log('    ' + ', '.join(f'{n} {k}/{t} {num(round(d, 2))}' for n, (k, t, d) in m['contact'].items()))
    return pack


# ---------------------------------------------------------------- preview


def load_font(size):
    for p in ('/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc',
              '/usr/share/fonts/noto/NotoSans-Regular.ttf',
              '/usr/share/fonts/TTF/DejaVuSans.ttf'):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def pack_frames(pack, pack_dir, name):
    """Full-canvas RGBA frames of one animation, rebuilt from the written sheet."""
    a = pack['animations'][name]
    s = pack['scale']
    sheet = read_rgba(os.path.join(pack_dir, a['sheet']))
    W, H = pack['canvas']['w'] * s, pack['canvas']['h'] * s
    out = []
    for f in a['frames']:
        r, c = divmod(f['i'], a['cols'])
        cell = sheet[r * a['frameH']:(r + 1) * a['frameH'], c * a['frameW']:(c + 1) * a['frameW']]
        full = np.zeros((H, W, 4), np.uint8)
        x, y = a['box']['x'] * s, a['box']['y'] * s
        full[y:y + a['frameH'], x:x + a['frameW']] = cell
        out.append(full)
    return out


def roles(pack, name):
    out = [s for s, names in pack['states'].items() if name in names]
    out += ['idlePool' for x in pack['idlePool']['anims'] if x['anim'] == name]
    for s, ts in pack['tiers'].items():
        out += [f'{s} ≥{t["min"]}' for t in ts if t['anim'] == name]
    out += [f'{s} bonus' for s, b in pack['bonus'].items() if name in b['anims']]
    out += [f'reaction {r}' for r, n in pack['reactions'].items() if n == name]
    return out


def hit_box_of(pack, name):
    """The hit box an animation uses: byAnim, then sleeping, then wide, then default."""
    h = pack['hitBoxes']
    if name in h['byAnim']:
        return h['byAnim'][name], 'byAnim'
    if name in h['sleepingAnims']:
        return h['sleeping'], 'sleeping'
    if name in h['wideAnims']:
        return h['wide'], 'wide'
    return h['default'], 'default'


def render_preview(pack, pack_dir, out_png, zoom, per_row=24):
    s = pack['scale']
    cw, ch = pack['canvas']['w'], pack['canvas']['h']
    fw, fh = cw * zoom, ch * zoom
    resample = Image.NEAREST if zoom % s == 0 else Image.BOX
    gap, cap, head = 6, 20, 34
    f_title, f_head, f_cap = load_font(26), load_font(20), load_font(14)
    names = list(pack['animations'])
    cols = min(per_row, max(len(pack['animations'][n]['frames']) for n in names))
    width = 16 + cols * (fw + gap)
    blocks = []
    for n in names:
        k = len(pack['animations'][n]['frames'])
        rows = math.ceil(k / cols)
        blocks.append((n, rows))
    height = 70 + sum(head + r * (fh + cap + gap) + 10 for _, r in blocks)
    img = Image.new('RGBA', (width, height), (250, 250, 252, 255))
    d = ImageDraw.Draw(img)
    a0 = pack['anchor']
    how = '最近邻放大' if resample == Image.NEAREST else 'BOX 缩小'
    d.text((16, 12), f'{pack["name"]}  ·  {pack["id"]}  ·  scale {s}  ·  canvas {cw}×{ch}  ·  '
                     f'预览 {zoom} px/逻辑像素（{how}）', fill=(20, 22, 40), font=f_title)
    d.text((16, 42), f'anchor x {a0["x"]}  baseline {a0["baseline"]}  ·  contentBox {pack["contentBox"]}'
                     f'  ·  红线 = baseline，红点 = anchor.x，橙框 = 这段动画的命中框',
           fill=(90, 94, 120), font=f_cap)
    # checkerboard tile
    chk = np.zeros((fh, fw, 4), np.uint8)
    yy, xx = np.mgrid[0:fh, 0:fw]
    on = ((yy // 8 + xx // 8) % 2).astype(bool)
    chk[...] = (226, 229, 240, 255)
    chk[on] = (246, 247, 252, 255)
    checker = Image.fromarray(chk, 'RGBA')
    by_ = int(round(a0['baseline'] * zoom))
    ax_ = int(round(a0['x'] * zoom))
    y = 70
    for n, rows in blocks:
        a = pack['animations'][n]
        stored = len(set(f['i'] for f in a['frames']))
        loop = 'loop' if a['loop'] else 'once'
        hb, hk = hit_box_of(pack, n)
        d.text((16, y + 4), f'{n}', fill=(20, 22, 40), font=f_head)
        tx = 16 + d.textlength(n, font=f_head) + 14
        d.text((tx, y + 7), f'{"  ·  ".join(roles(pack, n)) or "—"}   |   {len(a["frames"])} 帧'
                            f'（存 {stored}）  ·  {a["ms"]} ms  ·  {loop}  ·  命中框 {hk}',
               fill=(63, 91, 216), font=f_cap)
        y += head
        for k, fr in enumerate(pack_frames(pack, pack_dir, n)):
            r, c = divmod(k, cols)
            x0, y0 = 16 + c * (fw + gap), y + r * (fh + cap + gap)
            tile = checker.copy()
            tile.alpha_composite(Image.fromarray(fr, 'RGBA').resize((fw, fh), resample))
            td = ImageDraw.Draw(tile)
            td.rectangle([hb['x'] * zoom, hb['y'] * zoom, (hb['x'] + hb['w']) * zoom - 1,
                          (hb['y'] + hb['h']) * zoom - 1], outline=(240, 130, 0, 200))
            td.line([(0, by_), (fw, by_)], fill=(230, 40, 60, 200))
            td.ellipse([ax_ - 2, by_ - 2, ax_ + 2, by_ + 2], fill=(230, 40, 60, 255))
            img.paste(tile, (x0, y0))
            f = a['frames'][k]
            d.text((x0 + 2, y0 + fh + 2), f'{k + 1}  {f["ms"]}ms', fill=(70, 74, 100), font=f_cap)
        y += rows * (fh + cap + gap) + 10
    os.makedirs(os.path.dirname(out_png), exist_ok=True)
    img.convert('RGB').save(out_png, optimize=True)
    return out_png


# ---------------------------------------------------------------- main


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--src', default=DEFAULT_SRC)
    ap.add_argument('--out', default=DEFAULT_OUT)
    ap.add_argument('--preview', default=DEFAULT_PREVIEW)
    ap.add_argument('--only', choices=sorted(PACKS))
    args = ap.parse_args(argv)
    try:
        for pid in ([args.only] if args.only else list(PACKS)):
            pack = build(pid, args.src, args.out)
            if args.preview:
                p = render_preview(pack, os.path.join(args.out, pid),
                                   os.path.join(args.preview, f'{pid}.png'), PACKS[pid]['preview_zoom'],
                                   PACKS[pid]['preview_per_row'])
                print(f'  preview {p}')
    except BuildError as e:
        print(f'error: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
