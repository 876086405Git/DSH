#!/usr/bin/env python3
"""Check the user guide against the app, then build the dsh-go-guide skill.

    python3 app/tool/guide_sync.py           # check, then write app/assets/skills/dsh-go-guide/
    python3 app/tool/guide_sync.py --check   # check only, write nothing; exit 1 on any problem

The guide lives in docs/guide/ (SKILL.md, README.md, zh/*.md, en/*.md) and ships
as the dsh-go-guide skill: the app installs it into the on-device engine
(lib/ui_config/ui_skill.dart), flat in app/assets/skills/dsh-go-guide/ with
manifest.json mapping each file back to its place. Rules for the pages:

- zh/ and en/ hold the same pages. README.md says `> dsh-go <version>`, the
  version name in app/pubspec.yaml (without `+N`).
- A UI path is a code span `A › B › C` on the line right after
  `<!-- nav: keyA,keyB,keyC -->`, which names each label's ARB key
  (app/lib/l10n/parts/*_<locale>.arb); a `›` without that line fails.
- **Bold** is for UI text only: each must be a label of that locale, from the
  ARB or the Android string resources.
- Relative links resolve; `dshgo://open/<id>` names a page or a row a link
  may open: app/lib/links/page_links.dart and the settings index
  (app/lib/ui/settings/index/spots.dart).
- Chinese pages say 对话, never 会话, and never 实验.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SKILL = 'dsh-go-guide'
LOCALES = ('zh', 'en')
NAV = re.compile(r'^<!-- nav: ([A-Za-z][A-Za-z0-9_]*(?:,[A-Za-z][A-Za-z0-9_]*)*) -->$')
SPAN = re.compile(r'`([^`\n]+)`')
BOLD = re.compile(r'\*\*([^*\n]+)\*\*')
LINK = re.compile(r'\]\(([^)\s]+)\)')
VERSION_LINE = re.compile(r'^> dsh-go (\S+)$', re.MULTILINE)
BANNED = {'zh': ('会话', '实验'), 'en': ()}


def source_files(directory: Path, pattern: str):
    """Exclude macOS metadata on external disks from source/generated inputs."""
    return (path for path in directory.glob(pattern) if not path.name.startswith('._'))


def read_arb(directory: Path, locale: str) -> dict[str, str]:
    labels: dict[str, str] = {}
    files = sorted(source_files(directory, f'*_{locale}.arb'))
    if not files:
        raise ValueError(f'{directory}: no *_{locale}.arb')
    for file in files:
        for key, value in json.loads(file.read_text(encoding='utf-8')).items():
            if key.startswith('@') or not isinstance(value, str):
                continue
            if key in labels:
                raise ValueError(f'{file.name}: duplicate key {key}')
            labels[key] = value
    return labels


def read_android(res: Path, locale: str) -> set[str]:
    folder = res / ('values-zh' if locale == 'zh' else 'values')
    out: set[str] = set()
    for file in sorted(source_files(folder, '*.xml')):
        for node in ET.parse(file).getroot().iter('string'):
            text = ''.join(node.itertext())
            out.add(text.replace("\\'", "'").replace('\\"', '"'))
    return out


def read_page_ids(links: Path, index: Path) -> set[str]:
    """Page link ids: 全部功能's own pages (page_links.dart) and every page and
    row link of the settings index (ui/settings/index/spots.dart)."""
    text = links.read_text(encoding='utf-8')
    ids: set[str] = set()
    catalog = re.search(r'catalogPageLinks = <String>\{(.*?)\};', text, re.S)
    if not catalog:
        raise ValueError(f'{links}: catalogPageLinks not found')
    ids.update(re.findall(r"'([a-z0-9-]+)'", catalog[1]))
    spots = index.read_text(encoding='utf-8')
    pages = re.findall(r'links: const \[(.*?)\]', spots, re.S)
    rows = re.findall(r"\blink: '([a-z0-9-]+)'", spots)
    if not pages:
        raise ValueError(f'{index}: no page links found')
    for group in pages:
        ids.update(re.findall(r"'([a-z0-9-]+)'", group))
    ids.update(rows)
    return ids


def app_version(pubspec: Path) -> str:
    match = re.search(r'^version:\s*([^\s+]+)', pubspec.read_text(encoding='utf-8'), re.M)
    if not match:
        raise ValueError(f'{pubspec}: no version')
    return match[1]


def check_page(path: Path, guide: Path, locale: str, arb: dict[str, str], labels: set[str],
               ids: set[str]) -> list[str]:
    name = path.relative_to(guide).as_posix()
    lines = path.read_text(encoding='utf-8').splitlines()
    errors: list[str] = []
    annotated: set[int] = set()
    for i, line in enumerate(lines):
        if '<!--' not in line:
            continue
        match = NAV.match(line)
        if not match:
            errors.append(f'{name}:{i + 1}: malformed annotation (want <!-- nav: key1,key2 -->)')
            continue
        values = []
        for key in match[1].split(','):
            value = arb.get(key)
            if value is None:
                errors.append(f'{name}:{i + 1}: no {locale} ARB key {key}')
            elif not value or any(c in value for c in '{}`›\n'):
                errors.append(f'{name}:{i + 1}: {key} is not a plain label')
            else:
                values.append(value)
        if len(values) != len(match[1].split(',')):
            continue
        expected = ' › '.join(values)
        if i + 1 >= len(lines) or expected not in SPAN.findall(lines[i + 1]):
            errors.append(f'{name}:{i + 2}: want `{expected}` on the line after the annotation')
            continue
        annotated.add(i + 1)
        extra = [s for s in SPAN.findall(lines[i + 1]) if '›' in s and s != expected]
        if extra:
            errors.append(f'{name}:{i + 2}: one path per line; unannotated {extra}')
    for i, line in enumerate(lines):
        if '›' in line and i not in annotated:
            errors.append(f'{name}:{i + 1}: path without a nav annotation')
        for bold in BOLD.findall(line):
            if bold not in labels:
                errors.append(f'{name}:{i + 1}: **{bold}** is not a {locale} UI label')
        for word in BANNED[locale]:
            if word in line:
                errors.append(f'{name}:{i + 1}: avoid 「{word}」')
    return errors + check_links(path, guide, ids)


def check_links(path: Path, guide: Path, ids: set[str]) -> list[str]:
    name = path.relative_to(guide).as_posix()
    errors: list[str] = []
    for i, line in enumerate(path.read_text(encoding='utf-8').splitlines()):
        for target in LINK.findall(line):
            if target.startswith('dshgo://'):
                page = re.fullmatch(r'dshgo://open/([a-z0-9-]+)', target)
                if not page or page[1] not in ids:
                    errors.append(f'{name}:{i + 1}: {target} is not a page link the app opens')
            elif not re.match(r'(https?|mailto):', target):
                file = (path.parent / target.split('#')[0]).resolve()
                if not file.is_file() or guide.resolve() not in file.parents:
                    errors.append(f'{name}:{i + 1}: broken link {target}')
    return errors


def check_skill(text: str) -> list[str]:
    front = re.match(r'---\n([\s\S]*?)\n---\n', text)
    if not front:
        return ['SKILL.md: must start with --- front matter']
    lines = front[1].splitlines()
    errors = []
    if not any(line.startswith('# dsh-go:managed') for line in lines):
        errors.append('SKILL.md: front matter needs the # dsh-go:managed line')
    for key in ('name', 'description', 'whenToUse'):
        if not any(line.startswith(f'{key}: ') for line in lines):
            errors.append(f'SKILL.md: front matter needs {key}')
    if f'name: {SKILL}' not in lines:
        errors.append(f'SKILL.md: name must be {SKILL}')
    for line in lines:
        # Plain YAML scalars: one more `: ` or ` #` and DSH can't read the skill.
        key, _, value = line.partition(': ')
        if not line.startswith('#') and (': ' in value or ' #' in value or value[:1] in '\'"[]{}&*!|>%@`'):
            errors.append(f'SKILL.md: {key} must be a plain one-line value (no ": ", " #" or leading quote)')
    return errors


def guide_files(guide: Path) -> dict[str, Path]:
    files = {'SKILL.md': guide / 'SKILL.md', 'README.md': guide / 'README.md'}
    for locale in LOCALES:
        for page in sorted(source_files(guide / locale, '*.md')):
            files[f'{locale}/{page.name}'] = page
    return files


def check(repo: Path, guide: Path) -> list[str]:
    errors: list[str] = []
    for required in ('SKILL.md', 'README.md'):
        if not (guide / required).is_file():
            return [f'{guide}: missing {required}']
    pages = {locale: {p.name for p in source_files(guide / locale, '*.md')} for locale in LOCALES}
    if not pages['zh']:
        errors.append(f'{guide}/zh: no pages')
    if pages['zh'] != pages['en']:
        errors.append(f'zh/en pages differ: only zh {sorted(pages["zh"] - pages["en"])}, '
                      f'only en {sorted(pages["en"] - pages["zh"])}')
    for other in guide.rglob('*'):
        if other.name.startswith('._'):
            continue
        rel = other.relative_to(guide).as_posix()
        if other.is_file() and rel not in guide_files(guide):
            errors.append(f'{rel}: not part of the guide (SKILL.md, README.md, zh/*.md, en/*.md)')
    version = app_version(repo / 'app/pubspec.yaml')
    stated = VERSION_LINE.findall((guide / 'README.md').read_text(encoding='utf-8'))
    if stated != [version]:
        errors.append(f'README.md: want one line `> dsh-go {version}` (app/pubspec.yaml), found {stated}')
    errors += check_skill((guide / 'SKILL.md').read_text(encoding='utf-8'))
    ids = read_page_ids(repo / 'app/lib/links/page_links.dart', repo / 'app/lib/ui/settings/index/spots.dart')
    res = repo / 'app/android/app/src/main/res'
    for locale in LOCALES:
        arb = read_arb(repo / 'app/lib/l10n/parts', locale)
        labels = set(arb.values()) | read_android(res, locale)
        for page in sorted(source_files(guide / locale, '*.md')):
            errors += check_page(page, guide, locale, arb, labels, ids)
    for name in ('SKILL.md', 'README.md'):
        errors += check_links(guide / name, guide, ids)
    return errors


def assets(guide: Path) -> dict[str, bytes]:
    files = guide_files(guide)
    manifest = {target.replace('/', '-'): target for target in files}
    out = {flat: files[target].read_bytes() for flat, target in manifest.items()}
    out['manifest.json'] = (json.dumps({'name': SKILL, 'files': manifest}, ensure_ascii=False, indent=2)
                            + '\n').encode()
    return out


def sync(directory: Path, files: dict[str, bytes], write: bool) -> list[str]:
    current = {p.name for p in source_files(directory, '*') if p.is_file()} if directory.is_dir() else set()
    stale = sorted(current - files.keys())
    changed = sorted(n for n, data in files.items()
                     if not (directory / n).is_file() or (directory / n).read_bytes() != data)
    if not write:
        return [f'{directory}: out of date ({", ".join(stale + changed)}); run python3 app/tool/guide_sync.py']\
            if stale or changed else []
    directory.mkdir(parents=True, exist_ok=True)
    for name in stale:
        (directory / name).unlink()
    for name in changed:
        (directory / name).write_bytes(files[name])
    return []


def run(repo: Path, write: bool) -> list[str]:
    guide = repo / 'docs/guide'
    errors = check(repo, guide)
    if errors:
        return errors
    return sync(repo / 'app/assets/skills' / SKILL, assets(guide), write)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='check only, write nothing')
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        errors = run(args.repo, write=not args.check)
    except (OSError, ValueError, ET.ParseError) as error:
        errors = [str(error)]
    for error in errors:
        print(f'guide: {error}', file=sys.stderr)
    if errors:
        return 1
    count = len(guide_files(args.repo / 'docs/guide'))
    print(f'guide: {count} files {"checked" if args.check else "checked and built"}')
    return 0


if __name__ == '__main__':
    # CLI output is UTF-8 even when redirected through a legacy-codepage pipe.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8', errors=stream.errors)
    raise SystemExit(main())
