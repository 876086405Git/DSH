"""小粉鱼 frames -> the bundled pink-fish pet pack (docs/design/pets.md section 3).

    python3 -I tool/pet_src/pink-fish/build.py <frames dir> assets/pets

<frames dir> holds one folder per delivery (`NNN/`), each with segment folders
`B<n>-<name>/` carrying 1024 px RGBA frames and a timing.json. The newest
delivery of a segment wins. Frames are reduced to 320 px (scale 2) and each
animation shares one 256-colour palette so its sheet is stored indexed.
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
from PIL import Image

TOOL = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, TOOL)
import make_pet_pack as T  # noqa: E402

# Pro's segment code -> (animation name in the pack)
SEGMENTS = {
    'B1': 'idle', 'B2': 'poke', 'B3': 'happy', 'B4': 'think', 'B5': 'type',
    'B6': 'sleep', 'B7': 'wave', 'B8': 'cry', 'B9': 'tickle', 'B10': 'dangle',
    'B11': 'swim', 'B12': 'annoyed', 'B13': 'sweep', 'B14': 'conduct',
    'B15': 'carry', 'B16': 'stretch', 'B17': 'look', 'B18': 'bubble', 'B1b': 'sway',
}
# Intros (C series): start on the master, end on the loop's first frame; played
# once on entering the state through `bonus` with chance 1.
INTROS = {
    'C4': ('think-in', 'thinking'), 'C5': ('type-in', 'working'), 'C6': ('sleep-in', 'sleeping'),
    'C7': ('wave-in', 'notification'), 'C8': ('cry-in', 'error'), 'C10': ('dangle-in', None),
    'C11': ('swim-in', 'roam'), 'C13': ('sweep-in', 'sweeping'), 'C14': ('conduct-in', 'juggling'),
    'C15': ('carry-in', 'carrying'),
}
SEGMENTS.update({code: name for code, (name, _) in INTROS.items()})
STATES = {
    'idle': ['idle'], 'thinking': ['think'], 'working': ['type'], 'juggling': ['conduct'],
    'error': ['cry'], 'attention': ['happy'], 'notification': ['wave'], 'sweeping': ['sweep'],
    'carrying': ['carry'], 'sleeping': ['sleep'], 'waking': ['stretch'], 'roam': ['swim'],
}
REACTIONS = {'tapLeft': 'poke', 'tapRight': 'poke', 'tickle': 'tickle', 'annoyed': 'annoyed', 'drag': 'dangle'}
IDLE_EXTRAS = ['look', 'bubble', 'sway']
ONE_SHOT = {name for name, _ in INTROS.values()} | {'poke', 'happy', 'tickle', 'annoyed', 'stretch', 'look', 'bubble'}  # play once, then back


def latest_segments(reply):
    """Every delivery of each segment code, newest first. The newest timing.json
    wins; a frame comes from the newest delivery that has it (a later delivery
    may only correct the timing)."""
    found = {}
    for z in sorted(glob.glob(os.path.join(reply, '[0-9][0-9][0-9]'))):
        for d in glob.glob(os.path.join(z, '[BC]*-*')):
            code = os.path.basename(d).split('-')[0]
            if code in SEGMENTS and os.path.exists(os.path.join(d, 'timing.json')):
                found.setdefault(code, []).insert(0, d)
    return found


def shrink(path, size):
    im = Image.open(path).convert('RGBA').convert('RGBa').resize((size, size), Image.LANCZOS)
    return np.asarray(im.convert('RGBA')).copy()


def quantize(a, colors):
    im = Image.fromarray(a, 'RGBA').quantize(colors, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    return np.asarray(im.convert('RGBA')).copy()


def quantize_together(frames, colors):
    """One palette for the whole animation, so its sheet can be stored indexed."""
    h, w = frames[0].shape[:2]
    mosaic = Image.fromarray(np.concatenate(frames, axis=0), 'RGBA')
    q = mosaic.quantize(colors, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    a = np.asarray(q.convert('RGBA')).copy()
    a[a[..., 3] == 0] = 0
    return [a[i * h:(i + 1) * h].copy() for i in range(len(frames))]


def frame_path(dirs, f):
    for d in dirs:
        for p in (os.path.join(d, f), os.path.join(d, 'frames', f)):
            if os.path.exists(p):
                return p
    raise FileNotFoundError(os.path.join(dirs[0], f))


def load_segment(dirs, size, colors):
    d = dirs[0]
    with open(os.path.join(d, 'timing.json'), encoding='utf-8') as fh:
        timing = json.load(fh)
    if isinstance(timing, list):                  # bare frame list: files are frames/ in order
        timing = {'frames': timing}
    # Bare frame lists index the whole sequence of frame names across deliveries.
    files = sorted({os.path.basename(f) for x in dirs for f in glob.glob(os.path.join(x, 'frames', '*.png'))})
    frames, durs = [], []
    for i, f in enumerate(timing['frames']):
        path = frame_path(dirs, f['file'] if 'file' in f else files[f.get('index', i)])
        frames.append(shrink(path, size))
        durs.append(int(f['duration_ms']))
    if colors:
        frames = quantize_together(frames, colors)
    return {'frames': frames, 'durs': durs}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('reply')
    ap.add_argument('out')
    ap.add_argument('--id', default='pink-fish')
    ap.add_argument('--size', type=int, default=320)
    ap.add_argument('--scale', type=int, default=2)
    ap.add_argument('--colors', type=int, default=256)
    ap.add_argument('--preview')
    a = ap.parse_args(argv)

    segs = latest_segments(a.reply)
    anims = {SEGMENTS[c]: load_segment(d, a.size, a.colors) for c, d in segs.items()}
    for n, anim in anims.items():
        anim['loop'] = n not in ONE_SHOT
    print('segments', {c: os.path.relpath(d[0], a.reply) for c, d in sorted(segs.items())})

    have = set(anims)
    states = {s: [n for n in v if n in have] for s, v in STATES.items()}
    states = {s: v for s, v in states.items() if v}
    reactions = {r: n for r, n in REACTIONS.items() if n in have}
    # One-shots play once; a looping extra plays two whole passes, ending on its first frame.
    pool = [{'anim': n, 'ms': (2 if anims[n]['loop'] else 1) * sum(anims[n]['durs']), 'weight': 1}
            for n in IDLE_EXTRAS if n in have]
    wanted = []
    for v in states.values():
        wanted += [n for n in v if n not in wanted]
    wanted += [p['anim'] for p in pool if p['anim'] not in wanted]
    wanted += [n for n in reactions.values() if n not in wanted]
    bonus = {state: {'anims': [name], 'chance': 1} for name, state in INTROS.values()
             if state and name in have and state in states}
    wanted += [b['anims'][0] for b in bonus.values() if b['anims'][0] not in wanted]

    mapping = dict(states={s: states.get(s, []) for s in T.STATES}, tiers={}, reactions=reactions,
                   timings={}, idle_pool=pool, bonus=bonus, roam={'anim': 'swim'}, base_idle='idle')
    m = T.measure(anims, a.scale, 'idle')
    hits, _ = T.hit_boxes(anims, a.scale, mapping, wanted)

    out_dir = os.path.join(a.out, a.id)
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith('.png') or f == 'pack.json':
            os.remove(os.path.join(out_dir, f))
    animations = {n: T.write_anim(n, anims[n], a.scale, out_dir) for n in wanted}
    canvas = a.size // a.scale
    pack = {
        'schema': 1,
        'id': a.id,
        'name': '小粉鱼',
        'author': 'ccch1mneyyy',
        'license': 'dsh-go 原创形象，作者授权 dsh-go 使用',
        'source': 'AI 生成的原图，动画帧由 GPT 生图逐帧绘制',
        'pixelArt': False,
        'scale': a.scale,
        'canvas': {'w': canvas, 'h': canvas},
        'anchor': m['anchor'],
        'contentBox': m['contentBox'],
        'hitBoxes': hits,
        'animations': animations,
        'idlePool': {'everyMs': dict(T.IDLE_EVERY_MS), 'anims': pool},
        'states': states,
        'bonus': bonus,
        'tiers': {},
        'timings': {},
        'reactions': reactions,
    }
    if 'swim' in have:
        pack['roam'] = {'anim': 'swim', 'faces': 'front'}
    pack['sleep'] = {'afterMs': 60000}
    with open(os.path.join(out_dir, 'pack.json'), 'w', encoding='utf-8') as fh:
        fh.write(T.dumps(pack) + '\n')
    total = sum(os.path.getsize(os.path.join(out_dir, f)) for f in os.listdir(out_dir))
    print(a.id, len(wanted), 'animations', sum(len(x['durs']) for x in anims.values()), 'frames',
          round(total / 1024), 'KB', 'anchor', m['anchor'], 'contentBox', m['contentBox'])
    if a.preview:
        print('preview', T.render_preview(pack, out_dir, a.preview, 1, 16))


if __name__ == '__main__':
    main()
