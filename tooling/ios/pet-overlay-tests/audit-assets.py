#!/usr/bin/env python3
"""Audit real bundled PNG cells; optional reference montage, not Swift output."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    records = []
    cells_checked = 0
    frames_checked = 0
    tiles = []
    for pack_id in ['deepy-whale', 'whale-girl']:
        directory = root / 'app/assets/pets' / pack_id
        pack_path = directory / 'pack.json'
        pack = json.loads(pack_path.read_text())
        assert pack['schema'] == 1 and pack['id'] == pack_id
        records.append({'path': str(pack_path.relative_to(root)), 'sha256': sha(pack_path)})
        scale = pack['scale']
        seen = set()
        for name, anim in pack['animations'].items():
            path = directory / anim['sheet']
            assert path.parent == directory and path.suffix == '.png'
            sheet = Image.open(path).convert('RGBA')
            w, h, cols = anim['frameW'], anim['frameH'], anim['cols']
            box = anim['box']
            assert w == box['w'] * scale and h == box['h'] * scale
            assert sheet.width <= 4096 and sheet.height <= 4096
            assert sheet.width == cols * w and sheet.height % h == 0
            records.append({'path': str(path.relative_to(root)), 'sha256': sha(path),
                            'width': sheet.width, 'height': sheet.height})
            for frame in anim['frames']:
                i, ms = frame['i'], frame['ms']
                assert type(i) is int and i >= 0 and type(ms) is int and ms > 0
                x, y = (i % cols) * w, (i // cols) * h
                assert x + w <= sheet.width and y + h <= sheet.height
                frames_checked += 1
                seen.add((name, i))
            if name in ['idle', 'thinking', 'typing', 'music', 'conducting', 'happy', 'notification', 'sleeping']:
                # This montage reconstructs the pack's art canvas directly at
                # source scale. It does not pretend to be a UIKit/PiP capture.
                frame = anim['frames'][len(anim['frames']) // 2]
                i = frame['i']
                x, y = (i % cols) * w, (i // cols) * h
                sprite = sheet.crop((x, y, x + w, y + h))
                canvas = Image.new('RGBA', (pack['canvas']['w'] * scale, pack['canvas']['h'] * scale))
                canvas.alpha_composite(sprite, (int(box['x'] * scale), int(box['y'] * scale)))
                zoom = 3 if scale == 1 else 1
                canvas = canvas.resize((canvas.width * zoom, canvas.height * zoom), Image.Resampling.NEAREST)
                tile = Image.new('RGB', (320, 330), '#edf4f7')
                tile.paste(canvas, ((320 - canvas.width) // 2, 42 + (270 - canvas.height) // 2), canvas)
                draw = ImageDraw.Draw(tile)
                draw.text((12, 9), f'{pack_id} / {name}', fill='#172b3a')
                draw.text((12, 25), f'cell {i}; source scale {scale}; reference only', fill='#526675')
                tiles.append(tile)
        cells_checked += len(seen)
    montage = Image.new('RGB', (320 * 4, 330 * ((len(tiles) + 3) // 4)), 'white')
    for index, tile in enumerate(tiles):
        montage.paste(tile, ((index % 4) * 320, (index // 4) * 330))
    montage_path = output / 'asset-reference-montage.png'
    montage.save(montage_path)
    receipt = {
        'scope': 'Real bundled asset geometry/cell audit; montage is a source-art reference, not executed Swift or PiP.',
        'framesChecked': frames_checked,
        'uniqueCellsChecked': cells_checked,
        'files': records,
        'montageSha256': sha(montage_path),
    }
    (output / 'asset-audit.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'PASS: {frames_checked} timed frame references, {cells_checked} unique cells, {len(records)} source files')
    print('Swift/UIKit/PiP were not executed by this audit.')


if __name__ == '__main__':
    main()
