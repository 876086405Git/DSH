#!/usr/bin/env python3
"""Makes the packages that switch over TargetPlatform compile for HarmonyOS.

oh-flutter adds TargetPlatform.ohos, so an exhaustive switch in a pub.dev package
without a default stops compiling, and these packages have no OHOS fork. After a
first `pub get` this copies each one into app/ohos/.vendor (gitignored), sends ohos
down the android branch of every such switch, and points pubspec_overrides.yaml at
the copy. Run `pub get` again afterwards. See tooling/ohos/build-hap.sh.
"""
import json
import pathlib
import re
import shutil
from urllib.parse import urlparse
from urllib.request import url2pathname

PACKAGES = ('cupertino_ui', 'gpt_markdown', 'material_ui', 'xterm')

APP = pathlib.Path(__file__).resolve().parents[2] / 'app'
VENDOR = APP / 'ohos' / '.vendor'
OVERRIDES = APP / 'pubspec_overrides.yaml'

# Patterns only: `platform == TargetPlatform.android || ...` is a boolean and stays.
PATTERNS = (
    (re.compile(r'^(\s*)case TargetPlatform\.android:', re.M), r'\1case TargetPlatform.ohos:\n\1case TargetPlatform.android:'),
    (re.compile(r'(?<![=!]= )TargetPlatform\.android(\s*(?:\|\||=>))'), r'TargetPlatform.ohos || TargetPlatform.android\1'),
)


def patch(source):
    count = 0
    for pattern, replacement in PATTERNS:
        source, n = pattern.subn(replacement, source)
        count += n
    return source, count


def package_roots():
    config = json.loads((APP / '.dart_tool' / 'package_config.json').read_text())
    return {p['name']: pathlib.Path(url2pathname(urlparse(p['rootUri']).path)) for p in config['packages']}


def main():
    roots = package_roots()
    shutil.rmtree(VENDOR, ignore_errors=True)
    entries = []
    for name in PACKAGES:
        target = VENDOR / name
        shutil.copytree(roots[name], target, ignore=shutil.ignore_patterns('example', 'test', '.dart_tool'))
        total = 0
        for path in (target / 'lib').rglob('*.dart'):
            source, count = patch(path.read_text())
            if count:
                path.write_text(source)
                total += count
        print(f'{name}: {total} patterns')
        entries.append(f'  {name}:\n    path: ohos/.vendor/{name}\n')
    with OVERRIDES.open('a') as overrides:
        overrides.writelines(entries)


if __name__ == '__main__':
    main()
