#!/usr/bin/env python3
"""Load real Dart module bodies with explicit host Flutter/OS/service boundaries."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
from urllib.parse import urljoin

parser = argparse.ArgumentParser()
parser.add_argument('--reference', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--deps-config', type=Path, required=True)
parser.add_argument('--app-after', type=Path)
parser.add_argument('--connection-after', type=Path)
parser.add_argument('--real-companion', action='store_true')
parser.add_argument('--real-diagnostics', action='store_true')
args = parser.parse_args()
here = Path(__file__).resolve().parent
reference = args.reference.resolve()
out = args.out.resolve()
assert not out.exists(), out
out.mkdir(parents=True)
source_records = []
sha = lambda data: hashlib.sha256(data).hexdigest()

client = out / 'client'
shutil.copytree(reference / 'packages/dsh_client/lib', client / 'lib')
if args.connection_after:
    shutil.copyfile(args.connection_after, client / 'lib/src/connection.dart')
for path in sorted((client / 'lib').rglob('*.dart')):
    source_records.append({'path': 'packages/dsh_client/' + str(path.relative_to(client)),
                           'sha256': sha(path.read_bytes()), 'transform': None})

app_root = (args.app_after or reference).resolve()
app_files = ['speech/' + name for name in ['speech_audio.dart', 'speech_out.dart', 'deepseek_speech.dart']]
app_files.append('state/android_features.dart')
if (app_root / 'app/lib/speech/speech_compat.dart').exists():
    app_files.append('speech/speech_compat.dart')
if args.real_companion:
    app_files += ['companion/companion_voice.dart', 'companion/companion_voice_source.dart']
if args.real_diagnostics:
    app_files += ['diagnostics/diagnostics_channel.dart', 'diagnostics/system_ime_evidence.dart']
for name in app_files:
    source = app_root / 'app/lib' / name
    if not source.exists():
        source = reference / 'app/lib' / name
    data = source.read_text()
    transformed = data
    substitutions = []
    for old in [
        '../diagnostics/diagnostics_channel.dart', '../companion/companion_voice.dart',
        '../companion/companion_voice_source.dart', '../state/account_state.dart',
        '../state/connection_state.dart', '../state/settings_state.dart',
    ]:
        if args.real_companion and '/companion/' in old:
            continue
        if args.real_diagnostics and '/diagnostics/' in old:
            continue
        literal = f"import '{old}';"
        if literal in transformed:
            transformed = transformed.replace(literal, "import '../host_boundary.dart';")
            substitutions.append({'from': literal, 'to': "import '../host_boundary.dart';"})
    for literal in ["import 'dart:io' show Platform;", "import 'dart:io';"]:
        if literal in transformed:
            replacement = "import '../platform_boundary.dart' show Platform;"
            if literal == "import 'dart:io';":
                replacement = "import 'dart:io' hide Platform;\n" + replacement
            transformed = transformed.replace(literal, replacement)
            substitutions.append({'from': literal, 'to': replacement})
    # Several real app services share one explicit host boundary module. Keep
    # one import of it so host analysis has no artificial duplicate-import warning.
    seen_imports = set()
    lines = []
    for line in transformed.splitlines(keepends=True):
        if line.startswith('import '):
            if line in seen_imports:
                continue
            seen_imports.add(line)
        lines.append(line)
    transformed = ''.join(lines)
    without_imports = lambda text: re.sub(r'^import .*;\n', '', text, flags=re.M)
    assert without_imports(data) == without_imports(transformed), 'a method body changed during host preparation'
    target = out / 'app/lib' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(transformed)
    source_records.append({'path': 'app/lib/' + name, 'sourcePath': str(source),
                           'sha256': sha(data.encode()), 'hostSha256': sha(transformed.encode()),
                           'bodySha256': sha(without_imports(data).encode()), 'importSubstitutions': substitutions})
    for part in re.findall(r"^part '([^']+)';", data, flags=re.M):
        part_source = source.parent / part
        shutil.copyfile(part_source, target.parent / part)
        source_records.append({'path': str((target.parent / part).relative_to(out)), 'sourcePath': str(part_source),
                               'sha256': sha(part_source.read_bytes()), 'transform': None})

fixtures = here / 'host-fixtures'
for name in ['host_boundary.dart', 'platform_boundary.dart']:
    shutil.copyfile(fixtures / name, out / 'app/lib' / name)
if args.real_companion:
    target = out / 'app/lib/host_boundary.dart'
    target.write_text(target.read_text().split('enum CompanionVoiceSource')[0])
fixture_packages = [('flutter', ['services.dart', 'foundation.dart']),
                    ('flutter_riverpod', ['flutter_riverpod.dart'])]
if args.real_companion:
    fixture_packages += [(name, [name + '.dart']) for name in
                         ['shared_preferences', 'flutter_secure_storage', 'path_provider', 'file_picker']]
for package, names in fixture_packages:
    folder = out / package / 'lib'
    folder.mkdir(parents=True)
    for name in names:
        shutil.copyfile(fixtures / name, folder / name)
config_path = args.deps_config.resolve()
config = json.loads(config_path.read_text())
# Use only these real locked HTTP dependencies. The host framework boundaries
# below must not collide with entries in a real application's package_config.
http_packages = {'async', 'collection', 'http', 'http_parser', 'meta', 'path',
                 'source_span', 'string_scanner', 'term_glyph', 'typed_data', 'web'}
config['packages'] = [package for package in config['packages'] if package['name'] in http_packages]
assert {package['name'] for package in config['packages']} == http_packages
for package in config['packages']:
    package['rootUri'] = urljoin(config_path.as_uri(), package['rootUri'])
config['packages'] += [{'name': name, 'rootUri': (out / folder).as_uri() + '/',
                        'packageUri': 'lib/', 'languageVersion': '3.13'}
                       for name, folder in [('dsh_client', 'client'), ('dsh_app', 'app')] +
                                           [(name, name) for name, _ in fixture_packages]]
(out / '.dart_tool').mkdir()
(out / '.dart_tool/package_config.json').write_text(json.dumps(config, indent=2) + '\n')
(out / 'SOURCES.json').write_text(json.dumps({'scope': 'actual Dart bodies; Flutter framework, app state services and OS transport are explicit host boundaries',
                                            'realCompanionBodies': args.real_companion,
                                            'realDiagnosticsBodies': args.real_diagnostics,
                                            'files': source_records}, indent=2) + '\n')
print(json.dumps({'out': str(out), 'sourceFiles': len(source_records), 'methodBodiesPreserved': True}))
