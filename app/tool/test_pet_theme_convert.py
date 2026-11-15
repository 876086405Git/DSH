#!/usr/bin/env python3
"""Checks pet_theme_convert against a synthetic clawd-on-desk theme.

Run from app/ (Pillow and numpy):

    python3 -I tool/test_pet_theme_convert.py

No art from the real themes is used: frames are flat colours, enough to check
the mapping, the packing rules and the downscale. The SVG path is covered by
rendering a minimal hand-drawn idle.svg.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_pet_pack as T              # noqa: E402
import pet_theme_convert as C          # noqa: E402
from pet_svg_frames import rasterise    # noqa: E402

SIZE = 288


def frame(colour, top):
    """A 288x288 frame: a coloured box starting at [top]."""
    a = np.zeros((SIZE, SIZE, 4), np.uint8)
    a[top:top + 160, 60:220] = (colour[0], colour[1], colour[2], 255)
    return a


def write_apng(path, frames):
    ims = [Image.fromarray(f) for f in frames]
    ims[0].save(path, save_all=True, append_images=ims[1:], duration=70, loop=0)


IDLE_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="-4.5 -7 24 24" width="288" height="288">
  <defs><style>
    .lid { animation: lid 5.4s infinite step-end; }
    @keyframes lid { 0% { opacity: 1; } 96.6% { opacity: 0; } }
  </style></defs>
  <g fill="#d77757"><rect x="2" y="6" width="11" height="7"/></g>
  <g fill="#1a1a1a"><g class="lid"><rect x="4" y="8" width="1" height="1"/><rect x="10" y="8" width="1" height="1"/></g>
    <rect x="4" y="9" width="1" height="1"/><rect x="10" y="9" width="1" height="1"/></g>
</svg>
"""


class Fixture:
    """A tiny theme directory."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix='pet-theme-')
        os.makedirs(os.path.join(self.dir, 'assets'))
        frames = [frame((200, 60, 40), 20 + i * 8) for i in range(4)]
        for name in ('idle', 'think', 'think2', 'work', 'team2', 'jug', 'jug2', 'err',
                     'done', 'done2', 'notify', 'sleep', 'wake', 'roam', 'idle-look',
                     'hello', 'right', 'rmrf', 'det', 'notfound', 'dragx'):
            write_apng(os.path.join(self.dir, 'assets', name + '.apng'), frames)
        with open(os.path.join(self.dir, 'assets', 'idle.svg'), 'w', encoding='utf-8') as fh:
            fh.write(IDLE_SVG)
        theme = {
            'name': 'Test Clawd',
            'author': 'tester',
            'license': 'CC0',
            'viewBox': {'x': -4.5, 'y': -7, 'width': 24, 'height': 24},
            'states': {
                'idle': ['idle.svg'],
                'thinking': ['think.apng', 'think2.apng'],
                'working': ['work.apng'],
                'juggling': ['jug.apng', 'jug2.apng'],
                'error': ['err.apng'],
                'attention': ['done.apng', 'done2.apng'],
                'notification': ['notify.apng'],
                'sleeping': ['sleep.apng'],
                'waking': ['wake.apng'],
                'roam': ['roam.apng'],
            },
            'workingTiers': [
                {'minSessions': 1, 'file': 'work.apng'},
                {'minSessions': 2, 'file': 'team2.apng',
                 'files': ['team2.apng', 'idle-look.apng']},
            ],
            'jugglingTiers': [{'minSessions': 1, 'file': 'jug.apng'}],
            'idleAnimations': [{'file': 'idle-look.apng', 'duration': 4000}],
            'reactions': {
                'clickLeft': {'file': 'hello.apng'},
                'clickRight': {'file': 'right.apng'},
                'double': {'files': ['rmrf.apng', 'det.apng']},
                'annoyed': {'file': 'notfound.apng'},
                'drag': {'file': 'dragx.apng'},
            },
            'timings': {
                'minDisplay': {'attention': 1000, 'error': 1000, 'dizzy': 5000},
                'autoReturn': {'attention': 1000, 'error': 1000, 'notification': 1000},
                'wakeDuration': 1000,
            },
        }
        with open(os.path.join(self.dir, 'theme.json'), 'w', encoding='utf-8') as fh:
            json.dump(theme, fh)
        self.out = tempfile.mkdtemp(prefix='pet-pack-')


class DownscaleTest(unittest.TestCase):
    def test_area_average_keeps_colour_and_alpha(self):
        a = np.zeros((SIZE, SIZE, 4), np.uint8)
        a[:, :, 0] = 200
        a[:, :, 3] = 255
        a[:144, :, 3] = 0          # top half transparent
        out = C.down(a)
        self.assertEqual(out.shape, (144, 144, 4))
        self.assertEqual(int(out[10, 10, 3]), 0)
        self.assertEqual(tuple(int(v) for v in out[100, 10]), (200, 0, 0, 255))


class RasteriseTest(unittest.TestCase):
    def test_idle_blinks(self):
        d = tempfile.mkdtemp(prefix='pet-svg-')
        try:
            path = os.path.join(d, 'idle.svg')
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(IDLE_SVG)
            open_ = rasterise(path, 'idle', 0.0)
            blink = rasterise(path, 'idle', 5.3)
            self.assertEqual(open_.shape, (SIZE, SIZE, 4))
            self.assertGreater(int((open_[:, :, 3] > 0).sum()), 0)
            # The lids (2 squarish pixels at 12x) are the only difference.
            self.assertGreater(int((np.abs(open_.astype(int) - blink.astype(int)).sum(axis=2) > 0).sum()), 0)
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_unknown_animation_fails_loudly(self):
        d = tempfile.mkdtemp(prefix='pet-svg-')
        try:
            path = os.path.join(d, 'idle.svg')
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(IDLE_SVG)
            with self.assertRaises(ValueError):
                rasterise(path, 'whatever', 0.0)
        finally:
            shutil.rmtree(d, ignore_errors=True)


class MappingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = Fixture()
        cls.pack = C.build(cls.fixture.dir, cls.fixture.out, 'test-clawd', log=lambda *_: None)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.fixture.dir, ignore_errors=True)
        shutil.rmtree(cls.fixture.out, ignore_errors=True)

    def test_pack_shape(self):
        pack = self.pack
        self.assertEqual(pack['schema'], 1)
        self.assertEqual(pack['canvas'], {'w': 144, 'h': 144})
        self.assertIs(pack['pixelArt'], False)
        self.assertEqual(pack['scale'], 1)
        self.assertEqual(pack['author'], 'tester')
        self.assertEqual(pack['license'], 'CC0')
        self.assertEqual(pack['sleep'], {'afterMs': 60000})

    def test_states_keep_their_extra_animations(self):
        states = self.pack['states']
        self.assertEqual(states['thinking'], ['think', 'think2'])
        self.assertEqual(states['attention'], ['done', 'done2'])
        # dizzy is not a dsh-Go state: it must not leak into the pack.
        self.assertNotIn('dizzy', states)

    def test_tiers_are_high_first_and_drop_duplicate_variants(self):
        self.assertEqual(self.pack['tiers']['working'],
                         [{'min': 2, 'anim': 'team2'}, {'min': 1, 'anim': 'work'}])
        self.assertEqual(self.pack['tiers']['juggling'], [{'min': 1, 'anim': 'jug'}])

    def test_bonus_is_only_where_tiers_would_hide_it(self):
        # juggling has tiers and two animations: the extra one needs an explicit bonus.
        self.assertEqual(self.pack['bonus'], {'juggling': {'anims': ['jug2'], 'chance': 0.3}})

    def test_reactions_use_numbered_names(self):
        self.assertEqual(self.pack['reactions'], {
            'tapLeft': 'hello', 'tapRight': 'right',
            'tickle': 'rmrf', 'tickle2': 'det',
            'annoyed': 'notfound', 'drag': 'dragx',
        })

    def test_timings_follow_the_carriers(self):
        timings = self.pack['timings']
        self.assertEqual(timings['minDisplay'], {'attention': 1000, 'error': 1000})
        # notification holds until handled: no autoReturn.
        self.assertEqual(timings['autoReturn'], {'attention': 1000, 'error': 1000})
        self.assertEqual(timings['wakeMs'], 1000)

    def test_idle_pool_and_every_animation_present(self):
        self.assertEqual(self.pack['idlePool']['anims'], [{'anim': 'idle-look', 'ms': 4000, 'weight': 1}])
        names = set(self.pack['animations'])
        for wanted in ('idle', 'think', 'think2', 'work', 'team2', 'jug', 'jug2', 'done',
                       'done2', 'notify', 'sleep', 'wake', 'roam', 'idle-look', 'hello',
                       'right', 'rmrf', 'det', 'notfound', 'dragx'):
            self.assertIn(wanted, names)

    def test_frames_keep_their_own_durations(self):
        anim = self.pack['animations']['think']
        self.assertEqual(len(anim['frames']), 4)
        self.assertEqual([f['ms'] for f in anim['frames']], [70, 70, 70, 70])
        # One-shot states and reactions must not loop.
        self.assertFalse(self.pack['animations']['wake']['loop'])
        self.assertFalse(self.pack['animations']['hello']['loop'])
        self.assertTrue(self.pack['animations']['think']['loop'])

    def test_every_frame_sits_inside_its_sheet(self):
        """The same bound the app checks on import (pet_pack_validator.dart)."""
        out = os.path.join(self.fixture.out, 'test-clawd')
        for name, anim in self.pack['animations'].items():
            with Image.open(os.path.join(out, anim['sheet'])) as sheet:
                w, h = sheet.size
            last = max(f['i'] for f in anim['frames'])
            self.assertLessEqual(anim['cols'], w // anim['frameW'], name)
            self.assertLess(last // anim['cols'], h // anim['frameH'], name)


class GenericInputTest(unittest.TestCase):
    """Art that is not a clawd theme: images, frame folders, Aseprite, one still."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='pet-art-')
        self.out = tempfile.mkdtemp(prefix='pet-pack-')

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)
        shutil.rmtree(self.out, ignore_errors=True)

    def _solid(self, w, h, colour, dy=0):
        a = np.zeros((h, w, 4), np.uint8)
        a[dy:dy + h - 4, 2:w - 2] = (colour[0], colour[1], colour[2], 255)
        return Image.fromarray(a, 'RGBA')

    def _gif(self, name, n, colour):
        frames = [self._solid(64, 64, colour, i) for i in range(n)]
        frames[0].save(os.path.join(self.dir, name + '.gif'), save_all=True,
                       append_images=frames[1:], duration=120, loop=0)

    def test_animated_images_become_states(self):
        self._gif('idle', 3, (90, 160, 220))
        self._gif('error', 2, (220, 80, 70))
        self._gif('hello', 2, (120, 200, 120))
        self._solid(64, 64, (10, 10, 10)).save(os.path.join(self.dir, 'sticker.png'))
        pack = C.build(self.dir, self.out, 'test')
        self.assertEqual(pack['states']['idle'], ['idle'])
        self.assertEqual(pack['states']['error'], ['error'])
        self.assertEqual(pack['reactions']['tapLeft'], 'hello')
        self.assertEqual([x['anim'] for x in pack['idlePool']['anims']], ['sticker'])
        self.assertIs(pack['pixelArt'], True)
        self.assertEqual(len(pack['animations']['idle']['frames']), 3)

    def test_frame_folder(self):
        walk = os.path.join(self.dir, 'walk')
        os.makedirs(walk)
        for i in range(4):
            self._solid(64, 64, (200, 160, 90), i).save(os.path.join(walk, '%02d.png' % (i + 1)))
        pack = C.build(self.dir, self.out, 'walk-pet')
        self.assertEqual(pack['states']['roam'], ['walk'])
        self.assertEqual(len(pack['animations']['walk']['frames']), 4)

    def test_aseprite_export(self):
        sheet = Image.new('RGBA', (64 * 3, 64), (0, 0, 0, 0))
        for i in range(3):
            sheet.alpha_composite(self._solid(64, 64, (240, 200, 120), i), (i * 64, 0))
        sheet.save(os.path.join(self.dir, 'sprite.png'))
        frames = {'f%d' % i: {'frame': {'x': i * 64, 'y': 0, 'w': 64, 'h': 64}, 'duration': 90}
                  for i in range(3)}
        data = {'frames': frames, 'meta': {'image': 'sprite.png',
                'frameTags': [{'name': 'idle', 'from': 0, 'to': 1},
                              {'name': 'thinking', 'from': 2, 'to': 2}]}}
        json.dump(data, open(os.path.join(self.dir, 'sprite.json'), 'w'))
        pack = C.build(self.dir, self.out, 'ase')
        self.assertEqual(len(pack['animations']['idle']['frames']), 2)
        self.assertEqual(len(pack['animations']['thinking']['frames']), 1)
        self.assertEqual([f['ms'] for f in pack['animations']['idle']['frames']], [90, 90])

    def test_chinese_names_keep_their_own_states(self):
        self._solid(48, 48, (240, 60, 80)).save(os.path.join(self.dir, '待机.png'))
        self._solid(48, 48, (50, 150, 230)).save(os.path.join(self.dir, '思考.png'))
        pack = C.build(self.dir, self.out, 'zh')
        self.assertEqual(pack['states']['idle'], ['待机'])
        self.assertEqual(pack['states']['thinking'], ['思考'])

    def test_single_still_becomes_idle(self):
        self._solid(48, 48, (160, 120, 200)).save(os.path.join(self.dir, 'solo.png'))
        pack = C.build(self.dir, self.out, 'solo')
        self.assertEqual(pack['states'], {'idle': ['solo']})
        self.assertEqual(pack['idlePool']['anims'], [])
        self.assertEqual(pack['canvas'], {'w': 48, 'h': 48})

    def test_large_soft_art_gets_the_smooth_canvas(self):
        im = Image.new('RGBA', (300, 300), (0, 0, 0, 0))
        ImageDraw.Draw(im).ellipse((50, 50, 250, 250), fill=(255, 0, 0, 128))
        im.save(os.path.join(self.dir, 'soft.png'))
        pack = C.build(self.dir, self.out, 'soft')
        self.assertIs(pack['pixelArt'], False)
        self.assertEqual(pack['canvas'], {'w': 144, 'h': 144})


if __name__ == '__main__':
    unittest.main()
