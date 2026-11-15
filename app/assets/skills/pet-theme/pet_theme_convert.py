#!/usr/bin/env python3
"""Turns a clawd-on-desk theme into a dsh-Go pet pack.

    python3 tool/pet_theme_convert.py --theme DIR --out DIR

The theme directory holds theme.json, assets/*.apng and, for idle/roam/drag,
assets/*.svg. The art is not in this repo (CC BY-NC-SA 4.0 fan art): clone the
theme and point --theme at it. Output is a schema-1 pack.json plus one PNG per
animation, ready to zip and import (docs/design/pets.md section 3).

Mapping comes from theme.json: states and their extra animations, workingTiers,
jugglingTiers, idleAnimations, reactions, timings. Clawd states dsh-Go has no
place for (dizzy, yawning, dozing, collapsing, mini-*) are left out.

Two numbers are chosen, not derived (docs/design/pets.md section 3.8):

- canvas 144x144 (6x the 24-unit viewBox), area-averaged down from the theme's
  12x export, drawn with pixelArt:false. The art is hard-edged pixel art but its
  animation moves in sub-pixel steps; at 2x with the pixel-art integer upscale
  each step covers less than one canvas pixel and the motion looks like a
  stutter. 144 + area average + smooth filtering stays continuous (measured
  centroid jitter 1.609% vs the source art own 1.610%).
- tickle2, tickle3... instead of a list: older apps read only the plain first
  name and ignore the numbered ones, so one pack works on both.

SVG animations are rasterised by pet_svg_frames.py, whose keyframe numbers mirror
the theme svg.py.
"""
import argparse
import json
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_pet_pack as T              # noqa: E402
from pet_svg_frames import rasterise    # noqa: E402

CANVAS = 144                            # canvas and sheet pixels; 6x per theme unit
BLOCK = 288 // CANVAS                   # the theme exports at 12x -> 288
SLEEP_AFTER_MS = 60000                  # the theme mouseSleepTimeout is a desktop number
ROAM_FACES = 'front'                    # clawd walks facing the viewer

DGO_STATES = ['idle', 'thinking', 'working', 'juggling', 'error', 'attention',
              'notification', 'sweeping', 'carrying', 'sleeping', 'waking', 'roam']
# Held until the person deals with it, never auto-returned (pets.md section 12 #7).
HOLDING = {'notification'}
# When each SVG animation is sampled: (t seconds, how long that frame shows).
SVG_TIMES = {
    'idle': [(0.0, 5217), (5.217, 183)],                            # blink, 5.4 s
    'roam': [(0.00, 150), (0.15, 150), (0.30, 150), (0.45, 150)],   # 0.6 s steps
    'drag': [(i * 0.225, 225) for i in range(8)],                   # 1.8 s sway
}
RENAMES = {'drag': 'react-drag'}


def down(f):
    """288x288 RGBA -> 144x144: 2x2 area average with premultiplied alpha.

    Averaging keeps the sub-pixel motion the theme authored; the pack is drawn
    with smooth filtering, so those in-between pixels become continuous movement
    instead of a one-pixel hop.
    """
    a = f.astype(np.float32)
    a[a[..., 3] == 0] = 0
    alpha = a[..., 3] / 255.0
    out = np.zeros((CANVAS, CANVAS, 4), np.float32)
    out[..., :3] = (a[..., :3] * alpha[..., None]).reshape(CANVAS, BLOCK, CANVAS, BLOCK, 3).mean(axis=(1, 3))
    out[..., 3] = a[..., 3].reshape(CANVAS, BLOCK, CANVAS, BLOCK).mean(axis=(1, 3))
    safe = np.maximum(out[..., 3:4], 1e-6)
    out[..., :3] = np.where(out[..., 3:4] > 0, out[..., :3] * 255.0 / safe, 0)
    out = out.round().clip(0, 255).astype(np.uint8)
    out[out[..., 3] == 0] = 0
    return out


def anim_name(file):
    """theme.json file name -> the animation name in pack.json."""
    stem = os.path.splitext(os.path.basename(file))[0]
    return RENAMES.get(stem, stem)


def load_apng(theme_dir, name):
    frames, durs = T.read_apng(os.path.join(theme_dir, 'assets', name + '.apng'))
    return [down(f) for f in frames], list(durs)


def load_svg(theme_dir, name):
    if name not in SVG_TIMES:
        raise T.BuildError(name + '.svg: no CSS keyframe table for it in SVG_TIMES')
    path = os.path.join(theme_dir, 'assets', name + '.svg')
    return [down(rasterise(path, name, t)) for t, _ in SVG_TIMES[name]], [ms for _, ms in SVG_TIMES[name]]


def map_theme(theme, log=print):
    """theme.json -> dsh-Go mapping: states, tiers, idlePool, bonus, reactions, timings."""
    def names_of(files):
        return [anim_name(f) for f in files or []]

    states = {}
    for state in DGO_STATES:
        names = names_of(theme.get('states', {}).get(state))
        if names:
            states[state] = names
    if 'idle' not in states:
        raise T.BuildError('theme.json: no idle animation')

    tiers = {}
    for key, state in (('workingTiers', 'working'), ('jugglingTiers', 'juggling')):
        rows = theme.get(key) or []
        if not rows:
            continue
        tiers[state] = sorted([{'min': int(t['minSessions']), 'anim': anim_name(t['file'])} for t in rows],
                             key=lambda tier: -tier['min'])
        state_names = {anim_name(f) for f in theme.get('states', {}).get(state) or []}
        for t in rows:
            primary = anim_name(t['file'])
            extra = [anim_name(f) for f in (t.get('files') or [])
                     if anim_name(f) != primary and anim_name(f) not in state_names]
            if extra:
                log('  note: ' + key + ' ' + str(t['minSessions']) + ': ' + ', '.join(extra)
                    + ' not exported (dsh-Go keeps one animation per tier)')

    idle_pool = []
    for item in theme.get('idleAnimations') or []:
        name = anim_name(item['file'])
        if name == states['idle'][0]:
            continue
        idle_pool.append({'anim': name, 'ms': int(item['duration']), 'weight': 1})

    # A state with tiers never falls back to its own extra animations in the app,
    # so list them as an explicit bonus; other states get the fallback for free.
    bonus = {}
    for state, names in states.items():
        if state in tiers and len(names) > 1:
            bonus[state] = {'anims': names[1:], 'chance': 0.3}

    reactions = {}
    r = theme.get('reactions') or {}
    if r.get('clickLeft'):
        reactions['tapLeft'] = anim_name(r['clickLeft']['file'])
    if r.get('clickRight'):
        reactions['tapRight'] = anim_name(r['clickRight']['file'])
    double = r.get('double') or {}
    doubles = double.get('files') or ([double['file']] if double.get('file') else [])
    for i, f in enumerate(doubles):
        reactions['tickle' if i == 0 else 'tickle' + str(i + 1)] = anim_name(f)
    if r.get('annoyed'):
        reactions['annoyed'] = anim_name(r['annoyed']['file'])
    if r.get('drag'):
        reactions['drag'] = anim_name(r['drag']['file'])

    tm = theme.get('timings') or {}
    timings = {
        'minDisplay': {s: int(ms) for s, ms in (tm.get('minDisplay') or {}).items() if s in DGO_STATES},
        'autoReturn': {s: int(ms) for s, ms in (tm.get('autoReturn') or {}).items()
                       if s in DGO_STATES and s not in HOLDING},
    }
    if tm.get('wakeDuration'):
        timings['wakeMs'] = int(tm['wakeDuration'])
    return states, tiers, idle_pool, bonus, reactions, timings


def referenced(states, tiers, idle_pool, bonus, reactions, roam):
    """Every animation the returned pack points at, in drawing order."""
    names = []
    for state in DGO_STATES:
        names += states.get(state, [])
        names += [t['anim'] for t in tiers.get(state, [])]
        names += bonus.get(state, {}).get('anims', [])
        if state == 'idle':
            names += [x['anim'] for x in idle_pool]
    names += [reactions[k] for k in ('tapLeft', 'tapRight', 'annoyed', 'drag') if k in reactions]
    names += [v for k, v in reactions.items() if k.startswith('tickle')]
    if roam:
        names.append(roam['anim'])
    seen = []
    for n in names:
        if n not in seen:
            seen.append(n)
    return seen


def load_anims(theme_dir, theme, wanted):
    """Decode (or rasterise) every wanted animation once."""
    theme_states = theme.get('states') or {}
    theme_reactions = theme.get('reactions') or {}
    drag_file = (theme_reactions.get('drag') or {}).get('file', '')
    anims = {}
    for name in wanted:
        if name == 'idle' and any(f.endswith('.svg') for f in theme_states.get('idle') or []):
            frames, durs = load_svg(theme_dir, 'idle')
        elif name == 'roam' and any(f.endswith('.svg') for f in theme_states.get('roam') or []):
            frames, durs = load_svg(theme_dir, 'roam')
        elif name == 'react-drag' and drag_file.endswith('.svg'):
            frames, durs = load_svg(theme_dir, 'drag')
        else:
            frames, durs = load_apng(theme_dir, name)
        anims[name] = {'frames': frames, 'durs': durs, 'loop': True}
    for name in anims:
        # One-shot states and every reaction: the app holds the last frame or
        # returns to the state, so these must not loop.
        anims[name]['loop'] = name not in ('wake', 'hello', 'right') and not name.startswith('react-')
    return anims


def build(theme_dir, out_root, pack_id=None, name=None, source=None, preview=None, log=print):
    theme = json.load(open(os.path.join(theme_dir, 'theme.json'), encoding='utf-8'))
    states, tiers, idle_pool, bonus, reactions, timings = map_theme(theme, log)
    roam = {'anim': states['roam'][0], 'faces': ROAM_FACES} if 'roam' in states else None
    wanted = referenced(states, tiers, idle_pool, bonus, reactions, roam)
    anims = load_anims(theme_dir, theme, wanted)
    for anim in wanted:
        if len(anims[anim]['frames']) != len(anims[anim]['durs']) or not anims[anim]['frames']:
            raise T.BuildError(anim + ': frame / duration count mismatch')

    mapping = dict(states=states, tiers=tiers, reactions=reactions, timings=timings,
                   idle_pool=idle_pool, bonus=bonus,
                   roam=roam or {'anim': states['idle'][0]},
                   sleep={'afterMs': SLEEP_AFTER_MS}, base_idle='idle')
    m = T.measure(anims, 1, 'idle')
    hits, _ = T.hit_boxes(anims, 1, mapping, wanted)

    pid = pack_id or re.sub(r'[^a-z0-9-]+', '-', os.path.basename(os.path.normpath(theme_dir)).lower()).strip('-')
    if not pid:
        raise T.BuildError('cannot derive a pack id; pass --id')
    out_dir = os.path.join(out_root, pid)
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith('.png') or f == 'pack.json':
            os.remove(os.path.join(out_dir, f))
    animations = {n: T.write_anim(n, anims[n], 1, out_dir) for n in wanted}

    pack = {
        'schema': 1,
        'id': pid,
        'name': name or theme.get('name') or pid,
        'author': theme.get('author'),
        'license': theme.get('license'),
        'source': source,
        'pixelArt': False,
        'scale': 1,
        'canvas': {'w': CANVAS, 'h': CANVAS},
        'anchor': m['anchor'],
        'contentBox': m['contentBox'],
        'hitBoxes': hits,
        'animations': animations,
        'idlePool': {'everyMs': dict(T.IDLE_EVERY_MS), 'anims': idle_pool},
        'states': states,
        'bonus': bonus,
        'tiers': tiers,
        'timings': timings,
        'reactions': reactions,
    }
    if roam:
        pack['roam'] = roam
    pack['sleep'] = {'afterMs': SLEEP_AFTER_MS}
    with open(os.path.join(out_dir, 'pack.json'), 'w', encoding='utf-8') as fh:
        fh.write(T.dumps(pack) + chr(10))

    total = sum(os.path.getsize(os.path.join(out_dir, f)) for f in os.listdir(out_dir))
    frames = sum(len(a['durs']) for a in anims.values())
    log(pid + ': ' + str(len(wanted)) + ' animations, ' + str(frames) + ' frames, '
        + str(round(total / 1024)) + ' KB')
    log('  anchor ' + str(m['anchor']) + '  contentBox ' + str(m['contentBox']))
    log('  states ' + str(sorted(states)))
    log('  bonus ' + (str({k: v['anims'] for k, v in bonus.items()}) if bonus else 'none (app fallback)'))
    log('  reactions ' + str(reactions))
    log('  hitBoxes default ' + str(hits['default']) + '  wide ' + str(hits['wide']))
    if preview:
        p = T.render_preview(pack, out_dir, os.path.join(preview, pid + '.png'), 4, 24)
        log('  preview ' + p)
    return pack


def main(argv=None):
    ap = argparse.ArgumentParser(description='Convert a clawd-on-desk theme to a dsh-Go pet pack.')
    ap.add_argument('--theme', required=True, help='theme directory (theme.json + assets/)')
    ap.add_argument('--out', required=True, help='output directory (gets <id>/)')
    ap.add_argument('--id', default=None, help='pack id; default: the theme directory name')
    ap.add_argument('--input-name', dest='name', default=None, help='pet name; default: theme.json name')
    ap.add_argument('--source', default=None, help='where the art came from (shown in the pet page)')
    ap.add_argument('--preview', default=None, help='write a per-animation preview PNG here')
    args = ap.parse_args(argv)
    try:
        build(args.theme, args.out, args.id, args.name, args.source, args.preview)
    except T.BuildError as e:
        print('error: ' + str(e), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
