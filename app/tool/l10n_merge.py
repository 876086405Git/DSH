#!/usr/bin/env python3
"""Merges the per-area ARB parts and regenerates the L10n class.

  lib/l10n/parts/<area>_zh.arb  +  lib/l10n/parts/<area>_en.arb
      -> lib/l10n/app_zh.arb (template) + lib/l10n/app_en.arb
      -> flutter gen-l10n -> lib/l10n/gen/

Checks, all fatal (exit 1, nothing written):
  - every part is a JSON object with no duplicate keys, identifiers are lowerCamel;
  - a key appears in only one part, and in both languages of that part;
  - the placeholders of a key are the same in zh and en, and match its
    "@key" metadata when placeholders are declared (including an empty map);
  - plural / select blocks have unique cases and an `other` case;
  - plural categories are valid, and no exact selector shares a block with its
    category (`=1` and `one`). This is a structural preflight, not a full ICU
    compiler; `flutter gen-l10n` remains the authoritative syntax check.

Usage: tool/l10n_merge.py [--check] [--no-gen] [--part AREA] [--locale LOCALE ...]
  --check      validate only (no writes, no gen-l10n)
  --no-gen     write the merged ARBs but skip `flutter gen-l10n`
  --part AREA  validate only AREA in every selected locale (implies --check);
               keys clashing with other parts are still reported
  --locale    opt in to an additional complete static locale, e.g. --locale ru;
               repeat for more locales. zh/en are always required.

Unselected locale fragments are not loaded. Partial drafts never become a
supported language by file discovery. Extra root-directory *.arb files are refused
by a full check/build because Flutter would otherwise discover them implicitly.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from collections import OrderedDict

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L10N = os.path.join(APP, 'lib', 'l10n')
PARTS = os.path.join(L10N, 'parts')
LANGS = ('zh', 'en')
KEY_RE = re.compile(r'^[a-z][a-zA-Z0-9]*$')
IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
PLURAL_CASES = frozenset(('zero', 'one', 'two', 'few', 'many', 'other'))
# gen-l10n folds these into one argument: the later case replaces the earlier
# with only a warning, so `one{{n} x} =1{1 x}` renders 21 as "1 x" in Russian.
PLURAL_TWINS = {'=0': 'zero', 'zero': '=0', '=1': 'one', 'one': '=1', '=2': 'two', 'two': '=2'}
LOCALE_RE = re.compile(r'^[a-z]{2,3}(?:_[A-Z][a-z]{3})?(?:_(?:[A-Z]{2}|[0-9]{3}))?$')


def parse_message(msg: str):
    """Returns (placeholders, errors) for an ICU message (relax-syntax rules)."""
    names, errors = set(), []
    i, n = 0, len(msg)

    def parse_body(i, depth):
        # Parses until the closing brace of this level (depth>0) or end.
        while i < n:
            c = msg[i]
            if c == '{':
                m = IDENT.match(msg, i + 1)
                if not m:
                    i += 1  # relax-syntax: literal brace
                    continue
                name = m.group(0)
                j = m.end()
                while j < n and msg[j] == ' ':
                    j += 1
                if j < n and msg[j] == '}':
                    names.add(name)
                    i = j + 1
                    continue
                if j < n and msg[j] == ',':
                    # {name, plural|select, cases...}
                    k = msg.find(',', j + 1)
                    if k < 0:
                        errors.append(f'unterminated {{{name}, …')
                        return n
                    kind = msg[j + 1:k].strip()
                    if kind not in ('plural', 'select'):
                        errors.append(f'unknown ICU kind "{kind}" in {{{name}}}')
                        return n
                    names.add(name)
                    i, cases = parse_cases(k + 1, kind)
                    if 'other' not in cases:
                        errors.append(f'{kind} {{{name}}} has no "other" case')
                    continue
                i += 1  # relax-syntax: `{word` not a placeholder -> literal
                continue
            if c == '}':
                if depth > 0:
                    return i
                i += 1  # relax-syntax: stray close brace is literal
                continue
            i += 1
        if depth > 0:
            errors.append('unbalanced braces')
        return i

    def parse_cases(i, kind):
        cases = []
        while i < n:
            while i < n and msg[i] in ' \n\t':
                i += 1
            if i < n and msg[i] == '}':
                return i + 1, cases
            m = re.compile(r'(=\d+|[A-Za-z0-9_]+)\s*\{').match(msg, i)
            if not m:
                errors.append(f'bad plural/select case near "{msg[i:i + 20]}"')
                return n, cases
            case = m.group(1)
            if case in cases:
                errors.append(f'duplicate {kind} case "{case}"')
            if kind == 'plural' and not case.startswith('=') and case not in PLURAL_CASES:
                errors.append(f'unknown plural category "{case}"')
            if kind == 'plural' and PLURAL_TWINS.get(case) in cases:
                errors.append(f'plural cases "{case}" and "{PLURAL_TWINS[case]}" are the same case to gen-l10n')
            cases.append(case)
            j = parse_body(m.end(), 1)
            i = j + 1
        errors.append('unterminated plural/select')
        return n, cases

    parse_body(0, 0)
    return names, errors


def unique_object(pairs):
    result = OrderedDict()
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate key "{key}"')
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f'non-JSON constant {value}')


def load(path):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f, object_pairs_hook=unique_object, parse_constant=reject_constant)
        if not isinstance(data, dict):
            raise ValueError('ARB root must be an object')
        return data
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f'✗ {os.path.relpath(path, APP)}: invalid JSON: {e}')


def metadata_errors(data, lang):
    errors = []
    for key, meta in data.items():
        if not key.startswith('@') or key.startswith('@@'):
            continue
        if key[1:] not in data:
            errors.append(f'{lang}: orphan metadata "{key}"')
        if not isinstance(meta, dict):
            errors.append(f'{lang}: "{key}" metadata must be an object')
            continue
        if 'placeholders' not in meta:
            continue
        placeholders = meta['placeholders']
        if not isinstance(placeholders, dict):
            errors.append(f'{lang}: "{key}" placeholders must be an object')
            continue
        for name, spec in placeholders.items():
            if not isinstance(spec, dict):
                errors.append(f'{lang}: "{key}" placeholder "{name}" must be an object')
        message = data.get(key[1:])
        if isinstance(message, str):
            names, _ = parse_message(message)
            if set(placeholders) != names:
                errors.append(f'{lang}: "{key}" placeholders {sorted(placeholders)} ≠ message {sorted(names)}')
    return errors


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--no-gen', action='store_true')
    parser.add_argument('--part', metavar='AREA')
    parser.add_argument('--locale', action='append', default=[], metavar='LOCALE')
    args = parser.parse_args(argv)
    for locale in args.locale:
        if not LOCALE_RE.fullmatch(locale):
            parser.error(f'invalid locale {locale!r}; use canonical ARB form, e.g. ru, es_MX, zh_Hant')
        if locale in LANGS or args.locale.count(locale) > 1:
            parser.error(f'locale {locale!r} is already selected (zh/en are always included)')
    langs = LANGS + tuple(sorted(args.locale))
    for locale in args.locale:
        base_locale = locale.split('_', 1)[0]
        if base_locale not in langs:
            parser.error(f'locale {locale!r} needs its base locale; also select --locale {base_locale}')
    only = args.part
    check_only = args.check or only is not None
    no_gen = args.no_gen
    errors = []
    areas = set()
    # Match selected suffixes longest first: an area may itself contain '_'.
    for filename in os.listdir(PARTS):
        if filename.startswith('._'):  # macOS AppleDouble metadata, not an ARB input.
            continue
        for lang in sorted(langs, key=len, reverse=True):
            suffix = f'_{lang}.arb'
            if filename.endswith(suffix):
                areas.add(filename[:-len(suffix)])
                break
    areas = sorted(areas)
    if not areas:
        errors.append('no ARB parts for the selected locales')
    if only is not None:
        # The part under check goes last so clashes are reported against it.
        if only not in areas:
            parser.error(f'no part named {only}')
        areas = [a for a in areas if a != only] + [only]
    merged = {lang: OrderedDict([('@@locale', lang)]) for lang in langs}
    owner = {}
    for area in areas:
        data = {}
        for lang in langs:
            p = os.path.join(PARTS, f'{area}_{lang}.arb')
            if not os.path.exists(p):
                errors.append(f'{area}: missing {area}_{lang}.arb')
                data[lang] = OrderedDict()
                continue
            data[lang] = load(p)
            errors += [f'{area}: {e}' for e in metadata_errors(data[lang], lang)]
            if '@@locale' in data[lang] and data[lang]['@@locale'] != lang:
                errors.append(f'{area}: {lang}: @@locale must equal "{lang}"')
        zh = data['zh']
        zkeys = [k for k in zh if not k.startswith('@')]
        for k in zkeys:
            if not KEY_RE.fullmatch(k):
                errors.append(f'{area}: bad key "{k}" (lowerCamel identifiers only)')
            if k in owner:
                errors.append(f'{area}: key "{k}" already defined in {owner[k]}')
            owner.setdefault(k, area)
        for lang in langs[1:]:
            for k in zkeys:
                if k not in data[lang]:
                    errors.append(f'{area}: "{k}" has zh but no {lang}')
            for k in data[lang]:
                if not k.startswith('@') and k not in zh:
                    errors.append(f'{area}: "{k}" has {lang} but no zh')
        for k in zkeys:
            source_names = None
            for lang in langs:
                if k not in data[lang]:
                    continue
                value = data[lang][k]
                if not isinstance(value, str):
                    errors.append(f'{area}: "{k}" {lang} value must be a string')
                    continue
                if not value.strip():
                    errors.append(f'{area}: "{k}" {lang} is empty')
                names, message_errors = parse_message(value)
                errors += [f'{area}: "{k}" {lang}: {e}' for e in message_errors]
                if lang == 'zh':
                    source_names = names
                elif source_names is not None and names != source_names:
                    errors.append(f'{area}: "{k}" placeholders differ: zh {sorted(source_names)} '
                                  f'{lang} {sorted(names)}')
                merged[lang][k] = value
                if lang == 'zh':
                    meta = zh.get('@' + k) or {}
                    if meta:
                        merged['zh']['@' + k] = meta
    if only is not None:
        errors = [e for e in errors if e.startswith(only + ':')]
    else:
        selected_outputs = {f'app_{lang}.arb' for lang in langs}
        unexpected = sorted(f for f in os.listdir(L10N)
                            if f.endswith('.arb') and not f.startswith('._') and f not in selected_outputs)
        if unexpected:
            errors.append('unselected merged catalogs: ' + ', '.join(unexpected) +
                          '; use a clean checkout or remove these generated files deliberately')
    if errors:
        print('\n'.join('✗ ' + e for e in errors))
        print(f'✗ {len(errors)} problem(s); nothing written.')
        return 1
    count = len(owner)
    locales_note = f' ({", ".join(langs)})' if args.locale else ''
    print(f'✓ {len(areas)} parts, {count} keys{locales_note}')
    if check_only:
        return 0
    for lang in langs:
        # LF on every platform: Windows would write CRLF, and CI diffs against LF.
        with open(os.path.join(L10N, f'app_{lang}.arb'), 'w', encoding='utf-8', newline='\n') as f:
            json.dump(merged[lang], f, ensure_ascii=False, indent=2)
            f.write('\n')
    if no_gen:
        return 0
    flutter = os.environ.get('FLUTTER') or shutil.which('flutter')
    if not flutter:
        print('✗ flutter not found: put it on PATH or set FLUTTER')
        return 1
    r = subprocess.run([flutter, 'gen-l10n'], cwd=APP)
    if r.returncode != 0:
        print('✗ flutter gen-l10n failed')
        return r.returncode
    print('✓ gen-l10n → lib/l10n/gen/')
    return 0


if __name__ == '__main__':
    # CLI output is UTF-8 even when redirected through a legacy-codepage pipe.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8', errors=stream.errors)
    sys.exit(main(sys.argv[1:]))
