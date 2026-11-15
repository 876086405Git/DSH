#!/usr/bin/env python3
"""Puts the whale-girl companion pack into a HarmonyOS build's Flutter assets.

Android release builds carry the pack because the release machine drops
app/assets/companion/whale-girl.zip in before `flutter build`
(docs/design/companion.md). A HarmonyOS HAP takes its flutter_assets from the
Actions AOT artifact, built without the zip (it stays out of the repository),
so this adds it afterwards: the pack with the repository's character.json in
place of its own (the credit lives there), at the path companion_pack.dart
loads, and its entry in AssetManifest.bin, which hasBundledCompanionPack reads.

  tooling/ohos/bundle-companion-pack.py --aot DIR --pack ZIP --out DIR

--aot is the ohos-aot-<sha> artifact (arm64-v8a/, flutter_assets/); --out
gets a copy of it with the pack added, to hand to check-arkts.sh --aot.
"""
import argparse
import io
import shutil
import struct
import sys
import zipfile
from pathlib import Path

ASSET = 'assets/companion/whale-girl.zip'
CHARACTER = 'character/character.json'
REPO = Path(__file__).resolve().parents[2]

# Flutter's StandardMessageCodec, as far as AssetManifest.bin uses it.
NULL, TRUE, FALSE, INT32, INT64, FLOAT64, STRING, LIST, MAP = 0, 1, 2, 3, 4, 6, 7, 12, 13


def read_size(data, at):
    first = data[at]
    if first < 254:
        return first, at + 1
    if first == 254:
        return struct.unpack_from('<H', data, at + 1)[0], at + 3
    return struct.unpack_from('<I', data, at + 1)[0], at + 5


def decode(data, at=0):
    kind = data[at]
    at += 1
    if kind == NULL:
        return None, at
    if kind in (TRUE, FALSE):
        return kind == TRUE, at
    if kind == INT32:
        return struct.unpack_from('<i', data, at)[0], at + 4
    if kind == INT64:
        return struct.unpack_from('<q', data, at)[0], at + 8
    if kind == FLOAT64:
        at += -at % 8
        return struct.unpack_from('<d', data, at)[0], at + 8
    if kind == STRING:
        size, at = read_size(data, at)
        return data[at:at + size].decode('utf-8'), at + size
    if kind == LIST:
        size, at = read_size(data, at)
        items = []
        for _ in range(size):
            item, at = decode(data, at)
            items.append(item)
        return items, at
    if kind == MAP:
        size, at = read_size(data, at)
        items = {}
        for _ in range(size):
            key, at = decode(data, at)
            items[key], at = decode(data, at)
        return items, at
    raise ValueError(f'unexpected codec type {kind} at {at - 1}')


def write_size(out, size):
    if size < 254:
        out.append(size)
    elif size <= 0xFFFF:
        out.append(254)
        out += struct.pack('<H', size)
    else:
        out.append(255)
        out += struct.pack('<I', size)


def encode(value, out):
    if value is None:
        out.append(NULL)
    elif value is True or value is False:
        out.append(TRUE if value else FALSE)
    elif isinstance(value, int):
        if -2**31 <= value < 2**31:
            out.append(INT32)
            out += struct.pack('<i', value)
        else:
            out.append(INT64)
            out += struct.pack('<q', value)
    elif isinstance(value, float):
        out.append(FLOAT64)
        out += bytes(-len(out) % 8)
        out += struct.pack('<d', value)
    elif isinstance(value, str):
        raw = value.encode('utf-8')
        out.append(STRING)
        write_size(out, len(raw))
        out += raw
    elif isinstance(value, list):
        out.append(LIST)
        write_size(out, len(value))
        for item in value:
            encode(item, out)
    elif isinstance(value, dict):
        out.append(MAP)
        write_size(out, len(value))
        for key, item in value.items():
            encode(key, out)
            encode(item, out)
    else:
        raise TypeError(type(value))
    return out


def credited(pack: Path) -> bytes:
    """The pack with the repository's character.json, order, dates and deflate kept."""
    character = (REPO / 'tooling/companion/whale-girl.character.json').read_bytes()
    out = io.BytesIO()
    with zipfile.ZipFile(pack) as source, zipfile.ZipFile(out, 'w') as target:
        names = source.namelist()
        if CHARACTER not in names:
            raise ValueError(f'{pack} has no {CHARACTER}')
        for info in source.infolist():
            data = character if info.filename == CHARACTER else source.read(info)
            target.writestr(info, data, compress_type=info.compress_type)
    return out.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--aot', type=Path, required=True)
    parser.add_argument('--pack', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        sys.exit(f'{args.out} already exists')
    manifest_path = args.aot / 'flutter_assets/AssetManifest.bin'
    original = manifest_path.read_bytes()
    manifest, end = decode(original)
    # Only rewrite a manifest this codec reproduces byte for byte.
    if end != len(original) or bytes(encode(manifest, bytearray())) != original:
        sys.exit('AssetManifest.bin does not round-trip; not touching it')
    if ASSET in manifest:
        sys.exit(f'{ASSET} is already in this build')
    pack = credited(args.pack)
    shutil.copytree(args.aot, args.out)
    (args.out / 'flutter_assets' / ASSET).write_bytes(pack)
    manifest[ASSET] = [{'asset': ASSET}]
    (args.out / 'flutter_assets/AssetManifest.bin').write_bytes(bytes(encode(manifest, bytearray())))
    print(f'{ASSET}: {len(pack)} bytes; AssetManifest.bin {len(manifest) - 1} → {len(manifest)} assets')


if __name__ == '__main__':
    main()
