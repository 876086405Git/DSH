#!/usr/bin/env python3
"""The licensed whale-girl companion pack in Android release builds.

The pack stays out of the repository (docs/design/companion.md), so a fresh
checkout builds without it unless the release machine puts it back.

  tooling/companion_pack.py place SRC   app/assets/companion/whale-girl.zip from SRC,
                                        with the repository's character.json (the credit)
  tooling/companion_pack.py check APK   exit 1 unless APK carries the credited pack
"""
import importlib.util
import io
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ASSET = REPO / 'app/assets/companion/whale-girl.zip'
IN_APK = 'assets/flutter_assets/assets/companion/whale-girl.zip'
CHARACTER = 'character/character.json'


def _credited(pack: Path) -> bytes:
    spec = importlib.util.spec_from_file_location('bundle_companion_pack', REPO / 'tooling/ohos/bundle-companion-pack.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.credited(pack)


def place(src: Path) -> None:
    pending = ASSET.with_suffix('.zip.tmp')
    try:
        pending.write_bytes(_credited(src))
        pending.replace(ASSET)
    finally:
        pending.unlink(missing_ok=True)
    print(f'companion pack: {ASSET.relative_to(REPO)} from {src}')


def check(apk: Path) -> None:
    character = (REPO / 'tooling/companion/whale-girl.character.json').read_bytes()
    with zipfile.ZipFile(apk) as outer:
        if IN_APK not in outer.namelist():
            sys.exit(f'{apk.name}: no companion pack ({IN_APK})')
        with zipfile.ZipFile(io.BytesIO(outer.read(IN_APK))) as pack:
            if pack.read(CHARACTER) != character:
                sys.exit(f'{apk.name}: the companion pack has its own {CHARACTER}, not the credited one')


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('place', 'check'):
        sys.exit(__doc__)
    (place if sys.argv[1] == 'place' else check)(Path(sys.argv[2]))
