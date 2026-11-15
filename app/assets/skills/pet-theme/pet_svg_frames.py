#!/usr/bin/env python3
"""把 clawd-dev-life 主题渲染成 dsh-Go 宠物包的过渡层。

- APNG -> 逐帧解码 -> 6x6 块降采样到 48x48 画布（1 逻辑单位 = 2 画布像素）
- idle.svg / roam.svg / drag.svg -> 复算它们的 CSS 动画，渲染到 288x288 再同样降采样
"""
import math, os, sys
import xml.etree.ElementTree as ET
import numpy as np

VB = (-4.5, -7.0, 24.0, 24.0)   # theme.json viewBox
RENDER = 288                     # 12 px per viewBox unit

# ---------------------------------------------------------------- easing
def bezier(t, x1=0.42, y1=0.0, x2=0.58, y2=1.0):
    """CSS cubic-bezier(x1,y1,x2,y2) at time fraction t -> progress."""
    if t <= 0: return 0.0
    if t >= 1: return 1.0
    lo, hi = 0.0, 1.0
    for _ in range(40):
        s = (lo + hi) / 2
        x = 3*(1-s)**2*s*x1 + 3*(1-s)*s*s*x2 + s**3
        if x < t: lo = s
        else: hi = s
    s = (lo + hi) / 2
    return 3*(1-s)**2*s*y1 + 3*(1-s)*s*s*y2 + s**3

EASE_IN_OUT = lambda t: bezier(t)
EASE_OUT = lambda t: bezier(t, 0.0, 0.0, 0.58, 1.0)

# ---------------------------------------------------------------- matrices (a,b,c,d,e,f): x' = a x + c y + e
I = (1., 0., 0., 1., 0., 0.)
def mul(m, n):
    a1,b1,c1,d1,e1,f1 = m; a2,b2,c2,d2,e2,f2 = n
    return (a1*a2+b1*c2, a1*b2+b1*d2, c1*a2+d1*c2, c1*b2+d1*d2,
            e1*a2+f1*c2+e2, e1*b2+f1*d2+f2)
def translate(tx, ty): return (1.,0.,0.,1.,tx,ty)
def scale_about(sx, sy, ox, oy): return (sx,0.,0.,sy, ox-sx*ox, oy-sy*oy)
def rotate_about(deg, ox, oy):
    r = math.radians(deg); c, s = math.cos(r), math.sin(r)
    return (c, s, -s, c, ox - c*ox + s*oy, oy - s*ox - c*oy)
    a,b,c,d,e,f = m
    det = a*d - b*c
    ia, ib, ic, id_ = d/det, -b/det, -c/det, a/det
    return (ia, ib, ic, id_, -(ia*e + ic*f), -(ib*e + id_*f))

def invert(m):
    a, b, c, d, e, f = m
    det = a * d - b * c
    ia, ib, ic, id_ = d / det, -b / det, -c / det, a / det
    return (ia, ib, ic, id_, -(ia * e + ic * f), -(ib * e + id_ * f))

def hex_rgba(s):
    s = s.lstrip('#')
    if len(s) == 3: s = ''.join(c*2 for c in s)
    return (int(s[0:2],16), int(s[2:4],16), int(s[4:6],16), 255)

# ---------------------------------------------------------------- animation table
# 参数抄自 clawd-stickers dev-life/theme/svg.py 的 CSS（见各动画注释）。
def kf(pairs, easing):
    """keyframes: [(time_fraction, value)], 循环内插值."""
    pts = sorted(pairs)
    def at(t):
        t = t % 1.0
        prev = pts[-1]
        for cur in pts:
            if t < cur[0]:
                span = cur[0] - prev[0]
                u = 0.0 if span <= 0 else (t - prev[0]) / span
                return prev[1] + (cur[1] - prev[1]) * easing(u)
            prev = cur
        return pts[-1][1]
    return at

def kf_step(pairs):
    """step-end: 保持前一关键帧的值."""
    pts = sorted(pairs)
    def at(t):
        t = t % 1.0
        val = pts[-1][1]
        for p in pts:
            if t >= p[0]: val = p[1]
            else: break
        return val
    return at

def clamp_cycle(t, duration):
    return (t % duration) / duration

# 每个动画名 -> 函数(t_seconds) -> (matrix, opacity)
def build_anims():
    idle_lid = kf_step([(0.0, 1.0), (0.966, 0.0)])
    breath = kf([(0.0,1.0),(0.5,0.965),(1.0,1.0)], EASE_IN_OUT)
    bob = kf([(0.0,0.0),(0.5,-0.6),(1.0,0.0)], EASE_IN_OUT)
    step = kf_step([(0.0,-1.0),(0.5,0.0)])
    shadow_scale = kf([(0.0,1.0),(0.5,0.9),(1.0,1.0)], EASE_IN_OUT)
    sway = kf([(0.0,-7.0),(1.0,7.0)], EASE_IN_OUT)
    kick = kf_step([(0.0,-1.0),(0.5,0.0)])
    flail = lambda t: 1.0 if clamp_cycle(t, .24) < .5 else -1.0
    drop_t = kf([(0.0,0.0),(1.0,1.0)], EASE_OUT)
    drag_shadow = kf([(0.0,-1.0),(1.0,1.0)], EASE_IN_OUT)
    return {
      'idle': {
        'lid': lambda t: (I, idle_lid(clamp_cycle(t, 5.4))),
        'breath': lambda t: (scale_about(1.0, breath(clamp_cycle(t, 2.7)), 7.5, 15.0), 1.0),
      },
      'roam': {
        'lid': lambda t: (I, idle_lid(clamp_cycle(t, 5.4))),
        'bob': lambda t: (translate(0.0, bob(clamp_cycle(t, .3))), 1.0),
        'step-a': lambda t: (translate(0.0, step(clamp_cycle(t, .6))), 1.0),
        'step-b': lambda t: (translate(0.0, step(clamp_cycle(t + .3, .6))), 1.0),
        'shadow': lambda t: (scale_about(1.0, shadow_scale(clamp_cycle(t, .3)), 7.5, 15.5), 1.0),
      },
      'drag': {
        'sway': lambda t: (mul(rotate_about(sway(clamp_cycle(t, 1.8)), 7.5, 4.0), translate(0.0, -1.0)), 1.0),
        'kick-a': lambda t: (translate(0.0, kick(clamp_cycle(t, .24))), 1.0),
        'kick-b': lambda t: (translate(0.0, kick(clamp_cycle(t + .12, .24))), 1.0),
        'flail-a': lambda t: (translate(0.0, flail(t)), 1.0),
        'flail-b': lambda t: (translate(0.0, flail(t + .12)), 1.0),
        'drop-l': lambda t: (translate(-3.0*drop_t(clamp_cycle(t, .8)), 2.0*drop_t(clamp_cycle(t, .8))), 1.0 - drop_t(clamp_cycle(t, .8))),
        'drop-r': lambda t: (translate(-3.0*drop_t(clamp_cycle(t + .4, .8)), 2.0*drop_t(clamp_cycle(t + .4, .8))), 1.0 - drop_t(clamp_cycle(t + .4, .8))),
        'shadow': lambda t: (mul(translate(drag_shadow(clamp_cycle(t, 1.8)), 0.0), scale_about(0.9, 1.0, 7.5, 15.5)), 1.0),
      },
    }
ANIMS = build_anims()

# ---------------------------------------------------------------- SVG rasteriser
def rasterise(svg_path, anim_name, t):
    if anim_name not in ANIMS:
        raise ValueError('unknown SVG animation ' + repr(anim_name) + '; known: ' + ', '.join(ANIMS))
    """Render one frame at RENDER x RENDER RGBA using the CSS animation table."""
    root = ET.parse(svg_path).getroot()
    ns = '{http://www.w3.org/2000/svg}'
    vb_elem = root.attrib.get('viewBox', '').split()
    vx, vy, vw, vh = [float(x) for x in vb_elem]
    sx = RENDER / vw
    # output pixel centre -> user coords
    ys, xs = np.mgrid[0:RENDER, 0:RENDER]
    ux = (xs + 0.5) / sx + vx
    uy = (ys + 0.5) / sx + vy
    img = np.zeros((RENDER, RENDER, 4), np.float32)

    def paint_rect(m, opacity, colour, rx, ry, rw, rh):
        nonlocal img
        inv = invert(m)
        # 反变换到本地坐标
        lx = inv[0]*ux + inv[2]*uy + inv[4]
        ly = inv[1]*ux + inv[3]*uy + inv[5]
        inside = (lx >= rx) & (lx < rx + rw) & (ly >= ry) & (ly < ry + rh)
        if not inside.any(): return
        if opacity >= 1.0:
            img[inside] = colour
        else:
            a = colour[3] if len(colour) > 3 else 255
            src = (colour[0], colour[1], colour[2], a)
            dst = img[inside]
            sa = (src[3] / 255.0) * opacity
            da = dst[:, 3] / 255.0
            oa = sa + da * (1 - sa)
            # 逐通道
            out = np.zeros_like(dst)
            for i in range(3):
                num = src[i] * sa + dst[:, i] * da * (1 - sa)
                out[:, i] = np.where(oa > 0, num / np.maximum(oa, 1e-9), 0)
            out[:, 3] = oa * 255
            img[inside] = out

    def walk(node, parent_m, parent_colour, parent_opacity, t):
        tag = node.tag.replace(ns, '')
        if tag in ('defs', 'style'): return
        cls = node.attrib.get('class', '').split()
        m = parent_m
        op = parent_opacity
        for c in cls:
            if c in ANIMS[anim_name]:
                am, ao = ANIMS[anim_name][c](t)
                m = mul(m, am)
                op *= ao
        colour = node.attrib.get('fill', parent_colour)
        if 'opacity' in node.attrib:
            op *= float(node.attrib['opacity'])
        if tag == 'rect':
            paint_rect(m, op, hex_rgba(colour) if colour else (0,0,0,255),
                       float(node.attrib['x']), float(node.attrib['y']),
                       float(node.attrib['width']), float(node.attrib['height']))
        for child in node:
            walk(child, m, colour, op, t)

    walk(root, I, '#000000', 1.0, t)
    return img.astype(np.uint8)

# ---------------------------------------------------------------- downsample
    base = '/tmp/clawd-stickers/dev-life/theme/clawd-dev-life/assets'
    jobs = [
        ('idle', 'idle.svg', [(0.0, 5217), (5.217, 183)]),
        ('roam', 'roam.svg', [(0.0,150),(0.15,150),(0.30,150),(0.45,150)]),
        ('drag', 'drag.svg', [(i*0.225, 225) for i in range(8)]),
    ]
    os.makedirs('/tmp/clawd_pack/out', exist_ok=True)
    for anim, f, frames in jobs:
        tiles = []
        for t, ms in frames:
            hi = rasterise(os.path.join(base, f), anim, t)
            lo = downsample(hi)
            tiles.append((lo, hi, ms))
        # 拼预览：上排 288 原渲染，下排 48 降采样放大
        n = len(tiles)
        canvas = Image.new('RGBA', (n*300, 620), (245,246,250,255))
        for i, (lo, hi, ms) in enumerate(tiles):
            canvas.alpha_composite(Image.fromarray(hi, 'RGBA'), (i*300+6, 10))
            big = Image.fromarray(lo, 'RGBA').resize((288,288), Image.NEAREST)
            canvas.alpha_composite(big, (i*300+6, 320))
            from PIL import ImageDraw
            d = ImageDraw.Draw(canvas)
            d.text((i*300+8, 300), f'{anim} t={frames[i][0]:.2f}s  {ms}ms', fill=(30,30,40))
        canvas.convert('RGB').save(f'/tmp/clawd_pack/out/{anim}_preview.png')
        print('preview', anim, f)
