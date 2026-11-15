#!/usr/bin/env python3
"""Turns pet art into a dsh-Go pet pack (docs/design/pets.md section 3).

    python3 tool/pet_theme_convert.py --input DIR --out DIR [--id ID] [--input-name NAME]

Any of these inputs work; the kind is detected from what is in the directory:

- a clawd-on-desk theme (theme.json + assets/*.apng and, for idle/roam/drag,
  assets/*.svg). Mapping comes from theme.json.
- a folder of images: animated GIF / APNG / WebP, single PNGs, one file per
  animation or subfolders of numbered frames (Aseprite-style exports too).
  Animations are matched to states by name; unmatched ones become idle extras.
- a single image: one still pet.

Everything is packed as 144x144 canvas drawn with pixelArt:false, except art
that is already small hard-edged pixel art, which keeps its size and is drawn
crisply. Reasons in docs/design/pets.md section 3.8.

Reactions use numbered names (tickle, tickle2...) so one pack imports on both
old and new apps.
"""
import argparse
import json
import os
import re
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_pet_pack as T              # noqa: E402
from pet_svg_frames import rasterise    # noqa: E402

CANVAS = 144                            # canvas and sheet pixels for smooth art
SMOOTH_CANVAS = 144
CRISP_MAX = 256                         # art this small and hard-edged keeps its size
SLEEP_AFTER_MS = 60000
ROAM_FACES = 'front'

DGO_STATES = ['idle', 'thinking', 'working', 'juggling', 'error', 'attention',
              'notification', 'sweeping', 'carrying', 'sleeping', 'waking', 'roam']
HOLDING = {'notification'}

# When each clawd SVG animation is sampled: (seconds, how long that frame shows).
SVG_TIMES = {
    'idle': [(0.0, 5217), (5.217, 183)],                            # blink, 5.4 s
    'roam': [(0.00, 150), (0.15, 150), (0.30, 150), (0.45, 150)],   # 0.6 s steps
    'drag': [(i * 0.225, 225) for i in range(8)],                   # 1.8 s sway
}
RENAMES = {'drag': 'react-drag'}

# Name -> state, checked on the file (and folder) name, exact first then as a
# substring, in this order. English and Chinese words people actually use.
STATE_WORDS = [
    ('idle', ['idle', 'wait', 'breathe', 'stand', 'default', 'still', '待机', '默认', '站立', '呼吸']),
    ('thinking', ['think', 'thinking', 'ponder', '思考', '想']),
    ('working', ['work', 'working', 'type', 'typing', 'code', 'coding', 'busy', 'task', '干活', '工作', '打字', '忙']),
    ('juggling', ['juggle', 'juggling', 'subagent', 'multi', '分身', '子代理']),
    ('error', ['error', 'fail', 'failed', 'bug', 'crash', '报错', '错误', '失败']),
    ('attention', ['done', 'success', 'finish', 'finished', 'celebrate', 'win', 'complete', '完成', '成功', '庆祝']),
    ('notification', ['notify', 'notification', 'alert', 'ask', 'pending', '提示', '提醒', '等你', '通知']),
    ('sweeping', ['compact', 'sweep', 'clean', '压缩', '清理']),
    ('carrying', ['carry', 'carrying', 'upload', '携带', '搬运']),
    ('sleeping', ['sleep', 'sleeping', 'sleepy', 'zzz', '睡觉', '睡', '休息']),
    ('waking', ['wake', 'waking', 'morning', '醒', '起床']),
    ('roam', ['walk', 'roam', 'run', 'move', '游走', '走', '散步']),
]
REACTION_WORDS = [
    ('tapLeft', ['poke', 'tap', 'hello', 'hi', 'wave', '戳', '点', '打招呼']),
    ('tapRight', ['praise', 'ok', 'good', 'right', '对', '赞']),
    ('tickle', ['tickle', 'laugh', 'fun', '挠', '痒']),
    ('annoyed', ['annoy', 'angry', 'mad', '烦', '生气']),
    ('drag', ['drag', 'hold', 'grab', '拖', '拎']),
]


def resize_rgba(im, size, resample):
    """Resize premultiplied, so transparent pixels do not bleed dark edges in."""
    a = np.array(im.convert('RGBA'), dtype=np.float32)
    alpha = a[..., 3:4] / 255.0
    premul = np.concatenate([a[..., :3] * alpha, a[..., 3:4]], axis=2)
    small = Image.fromarray(premul.round().clip(0, 255).astype(np.uint8), 'RGBA').resize(size, resample)
    b = np.array(small, dtype=np.float32)
    al = b[..., 3:4] / 255.0
    out = np.concatenate([np.where(al > 0, b[..., :3] / np.maximum(al, 1e-6), 0), b[..., 3:4]], axis=2)
    out = out.round().clip(0, 255).astype(np.uint8)
    out[out[..., 3] == 0] = 0
    return out


def down(f):
    """A clawd theme frame (288x288) -> CANVAS x CANVAS: 2x2 area average, premultiplied.

    Written out rather than a PIL resize so the output is byte-identical to the
    art the pack was reviewed with.
    """
    a = f.astype(np.float32)
    a[a[..., 3] == 0] = 0
    alpha = a[..., 3] / 255.0
    out = np.zeros((CANVAS, CANVAS, 4), np.float32)
    out[..., :3] = (a[..., :3] * alpha[..., None]).reshape(CANVAS, 2, CANVAS, 2, 3).mean(axis=(1, 3))
    out[..., 3] = a[..., 3].reshape(CANVAS, 2, CANVAS, 2).mean(axis=(1, 3))
    safe = np.maximum(out[..., 3:4], 1e-6)
    out[..., :3] = np.where(out[..., 3:4] > 0, out[..., :3] * 255.0 / safe, 0)
    out = out.round().clip(0, 255).astype(np.uint8)
    out[out[..., 3] == 0] = 0
    return out


def anim_name(file):
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
    """theme.json -> dsh-Go mapping."""
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
        for t in rows:
            state_names = {anim_name(f) for f in theme.get('states', {}).get(state) or []}
            extra = [anim_name(f) for f in (t.get('files') or [])
                     if anim_name(f) != anim_name(t['file']) and anim_name(f) not in state_names]
            if extra:
                log('  note: ' + key + ' ' + str(t['minSessions']) + ': ' + ', '.join(extra)
                    + ' not exported (dsh-Go keeps one animation per tier)')

    idle_pool = []
    for item in theme.get('idleAnimations') or []:
        name = anim_name(item['file'])
        if name == states['idle'][0]:
            continue
        idle_pool.append({'anim': name, 'ms': int(item['duration']), 'weight': 1})

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
    theme_states = theme.get('states') or {}
    drag_file = (theme.get('reactions', {}).get('drag') or {}).get('file', '')
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
        anims[name] = {'frames': frames, 'durs': durs}
    for name in anims:
        anims[name]['loop'] = name not in ('wake', 'hello', 'right') and not name.startswith('react-')
    return anims


# ---------------------------------------------------------------- image input

IMAGE_EXTS = ('.png', '.gif', '.webp', '.apng', '.jpg', '.jpeg', '.bmp')


def image_frames(path):
    """Every frame of an image file (GIF / APNG / WebP animate; PNG is one)."""
    im = Image.open(path)
    out = []
    for i in range(getattr(im, 'n_frames', 1)):
        im.seek(i)
        out.append((np.array(im.convert('RGBA')), int(im.info.get('duration') or 100)))
    return out


def sanitize(name):
    """A folder or file name as a pack animation name."""
    # Letters of any script: 待机 and 思考 stay two names, each its own state.
    cleaned = re.sub(r'[^\w-]+', '-', name.lower()).strip('-')
    return cleaned or 'anim'


def state_of(stem, table):
    """The state a name points at: an exact word first, then a substring."""
    low = stem.lower()
    for name, words in table:
        if low in words:
            return name
    for name, words in table:
        for word in words:
            if word in low:
                return name
    return None


def collect_images(input_path):
    """Folder -> {animation name: [(frame, ms)]}; also subfolders of frames."""
    anims = {}
    for entry in sorted(os.listdir(input_path)):
        path = os.path.join(input_path, entry)
        if os.path.isdir(path):
            seq = sorted(f for f in os.listdir(path) if f.lower().endswith(IMAGE_EXTS))
            if seq:
                anims[sanitize(entry)] = [image_frames(os.path.join(path, f))[0] for f in seq]
        elif entry.lower().endswith(IMAGE_EXTS):
            anims[sanitize(os.path.splitext(entry)[0])] = image_frames(path)
    return anims


def collect_aseprite(input_path):
    """An Aseprite JSON export (meta.frameTags) next to its sheet -> animations."""
    for entry in sorted(os.listdir(input_path)):
        if not entry.lower().endswith('.json'):
            continue
        try:
            data = json.load(open(os.path.join(input_path, entry), encoding='utf-8'))
        except (ValueError, OSError):
            continue
        meta = data.get('meta') or {}
        tags = meta.get('frameTags') or []
        frames = data.get('frames')
        if not tags or not frames:
            continue
        rows = list(frames.values()) if isinstance(frames, dict) else list(frames)
        sheet_name = meta.get('image') or os.path.splitext(entry)[0] + '.png'
        sheet = np.array(Image.open(os.path.join(input_path, sheet_name)).convert('RGBA'))
        anims = {}
        for tag in tags:
            name = sanitize(tag.get('name') or 'anim')
            seq = []
            for i in range(int(tag['from']), int(tag['to']) + 1):
                row = rows[i]
                box = row.get('frame') or {}
                x, y = int(box.get('x', 0)), int(box.get('y', 0))
                w, h = int(box.get('w', 0)), int(box.get('h', 0))
                seq.append((sheet[y:y + h, x:x + w], int(row.get('duration') or 100)))
            if seq:
                anims[name] = seq
        if anims:
            return anims
    return None


def place(frame, width, height, crisp):
    """Bottom-aligned, horizontally centred on the shared canvas."""
    im = Image.fromarray(frame, 'RGBA')
    if crisp:
        canvas = Image.new('RGBA', (width, height), (0, 0, 0, 0))
        canvas.alpha_composite(im, ((width - im.width) // 2, height - im.height))
        return np.array(canvas)
    ratio = min(width / im.width, height / im.height)
    nw = max(1, round(im.width * ratio))
    nh = max(1, round(im.height * ratio))
    scaled = Image.fromarray(resize_rgba(im, (nw, nh), Image.LANCZOS), 'RGBA')
    canvas = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    canvas.alpha_composite(scaled, ((width - nw) // 2, height - nh))
    return np.array(canvas)


def fit_canvas(anims, force_crisp=False):
    """One canvas for every frame; hard-edged small art keeps its size."""
    frames = [frame for seq in anims.values() for frame, _ in seq]
    width = max(f.shape[1] for f in frames)
    height = max(f.shape[0] for f in frames)
    hard = all(bool(((f[..., 3] == 0) | (f[..., 3] == 255)).all()) for f in frames)
    crisp = force_crisp or (max(width, height) <= CRISP_MAX and hard)
    if not crisp:
        width = height = SMOOTH_CANVAS
    out = {}
    for name, seq in anims.items():
        out[name] = {
            'frames': [place(frame, width, height, crisp) for frame, _ in seq],
            'durs': [ms for _, ms in seq],
        }
    return width, height, out, crisp


def generic_mapping(anims):
    """Animation names -> dsh-Go states, reactions and idle extras."""
    states = {}
    reactions = {}
    extras = []
    order = list(anims)
    for name in order:
        reaction = state_of(name, REACTION_WORDS)
        state = state_of(name, STATE_WORDS)
        if state:
            states.setdefault(state, []).append(name)
        elif reaction:
            if reaction in reactions:
                i = 2
                while reaction + str(i) in reactions:
                    i += 1
                reactions[reaction + str(i)] = name
            else:
                reactions[reaction] = name
        else:
            extras.append(name)
    if 'idle' not in states:
        states['idle'] = [order[0]]
        extras = [n for n in extras if n != order[0]]
    roam = {'anim': states['roam'][0], 'faces': ROAM_FACES} if 'roam' in states else None
    idle_pool = [{'anim': n, 'ms': 2 * sum(anims[n]['durs']), 'weight': 1} for n in extras]
    return states, reactions, idle_pool, roam


def build_generic(anims, out_root, pack_id, name, source_url, crisp, preview, log):
    width, height, fitted, pixel_art = fit_canvas(anims, crisp)
    states, reactions, idle_pool, roam = generic_mapping(fitted)
    wanted = referenced(states, {}, idle_pool, {}, reactions, roam)
    selected = {n: fitted[n] for n in wanted}
    for n, anim in selected.items():
        anim['loop'] = n not in ('wake', 'hello', 'right') and not n.startswith('react-')

    base = states['idle'][0]
    hit_states = {state: states.get(state, []) for state in DGO_STATES}
    mapping = dict(states=hit_states, tiers={}, reactions=reactions, timings={},
                   idle_pool=idle_pool, bonus={},
                   roam=roam or {'anim': base},
                   sleep={'afterMs': SLEEP_AFTER_MS}, base_idle=base)
    m = T.measure(selected, 1, base)
    hits, _ = T.hit_boxes(selected, 1, mapping, wanted)

    out_dir = os.path.join(out_root, pack_id)
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith('.png') or f == 'pack.json':
            os.remove(os.path.join(out_dir, f))
    animations = {n: T.write_anim(n, selected[n], 1, out_dir) for n in wanted}

    pack = {
        'schema': 1,
        'id': pack_id,
        'name': name or pack_id,
        'author': None,
        'license': None,
        'source': source_url,
        'pixelArt': pixel_art,
        'scale': 1,
        'canvas': {'w': width, 'h': height},
        'anchor': m['anchor'],
        'contentBox': m['contentBox'],
        'hitBoxes': hits,
        'animations': animations,
        'idlePool': {'everyMs': dict(T.IDLE_EVERY_MS), 'anims': idle_pool},
        'states': states,
        'bonus': {},
        'tiers': {},
        'timings': {},
        'reactions': reactions,
    }
    if roam:
        pack['roam'] = roam
    pack['sleep'] = {'afterMs': SLEEP_AFTER_MS}
    with open(os.path.join(out_dir, 'pack.json'), 'w', encoding='utf-8') as fh:
        fh.write(T.dumps(pack) + chr(10))

    total = sum(os.path.getsize(os.path.join(out_dir, f)) for f in os.listdir(out_dir))
    frames = sum(len(a['durs']) for a in selected.values())
    log(pack_id + ': ' + str(len(wanted)) + ' animations, ' + str(frames) + ' frames, '
        + str(round(total / 1024)) + ' KB' + (' (crisp ' + str(width) + 'px)' if pixel_art else ''))
    log('  states ' + str(sorted(states)) + '  reactions ' + str(reactions))
    if idle_pool:
        log('  idle extras ' + str([x['anim'] for x in idle_pool]))
    if preview:
        log('  preview ' + T.render_preview(pack, out_dir, os.path.join(preview, pack_id + '.png'), 4, 24))
    return pack


def build_clawd(theme_dir, out_root, pack_id, name, source_url, preview, log):
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

    pid = pack_id or safe_id(theme_dir)
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
        'source': source_url,
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
    log('  states ' + str(sorted(states)))
    if bonus:
        log('  bonus ' + str({k: v['anims'] for k, v in bonus.items()}))
    log('  reactions ' + str(reactions))
    if preview:
        log('  preview ' + T.render_preview(pack, out_dir, os.path.join(preview, pid + '.png'), 4, 24))
    return pack


def safe_id(input_path):
    pid = re.sub(r'[^a-z0-9-]+', '-', os.path.basename(os.path.normpath(input_path)).lower()).strip('-')
    if not pid:
        raise T.BuildError('cannot name the pack; pass --id')
    return pid


def build(input_path, out_root, pack_id=None, name=None, source_url=None, preview=None, crisp=False, log=print):
    if os.path.isfile(os.path.join(input_path, 'theme.json')):
        return build_clawd(input_path, out_root, pack_id, name, source_url, preview, log)
    anims = collect_aseprite(input_path) or collect_images(input_path)
    if not anims:
        raise T.BuildError('no pet art in ' + input_path + ': give a clawd-on-desk theme, '
                           'a folder of GIF/PNG/WebP files or frame folders, or an Aseprite export')
    return build_generic(anims, out_root, pack_id or safe_id(input_path), name, source_url,
                         crisp, preview, log)


def main(argv=None):
    ap = argparse.ArgumentParser(description='Turn pet art into a dsh-Go pet pack.')
    ap.add_argument('--input', '--theme', dest='input', required=True,
                    help='theme directory, image folder, or Aseprite export')
    ap.add_argument('--out', required=True, help='output directory (gets <id>/)')
    ap.add_argument('--id', default=None, help='pack id; default: the input directory name')
    ap.add_argument('--input-name', dest='name', default=None, help='pet name; default: theme.json name or the id')
    ap.add_argument('--source', default=None, help='where the art came from (shown in the pet page)')
    ap.add_argument('--crisp', action='store_true', help='keep pixel-art sizes and draw crisply')
    ap.add_argument('--preview', default=None, help='write a per-animation preview PNG here')
    args = ap.parse_args(argv)
    try:
        build(args.input, args.out, args.id, args.name, args.source, args.preview, args.crisp)
    except T.BuildError as e:
        print('error: ' + str(e), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
