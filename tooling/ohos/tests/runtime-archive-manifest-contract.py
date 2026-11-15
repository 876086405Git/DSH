#!/usr/bin/env python3
"""Compare the Python audit with the actual RuntimeCore JSON consumer in Node.

Only type syntax is erased by Node when it loads the byte-identical .mts copy.
This is a JSON-domain contract test, not an ArkTS/device result.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    helper = root / 'tooling/ohos/runtime_archive_audit.py'
    spec = importlib.util.spec_from_file_location('actual_runtime_archive_audit', helper)
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    entries = audit.required_entries()
    base = {'schema': 1, 'runtimeVersion': 'actual-core-parity', 'dshVersion': '', 'nodeVersion': '24.22.1',
            'files': [{'path': name, 'size': 0, 'sha256': hashlib.sha256(b'').hexdigest()} for name in entries]}
    cases = []

    def add(name, value, expected=None):
        cases.append({'name': name, 'json': json.dumps(value, ensure_ascii=False, separators=(',', ':')), 'expected': expected})

    def top(name, key, value, expected=None):
        candidate = copy.deepcopy(base); candidate[key] = value; add(name, candidate, expected)

    def file(name, key, value, expected=None):
        candidate = copy.deepcopy(base); candidate['files'][0][key] = value; add(name, candidate, expected)

    add('valid-integer-one-and-empty-dshVersion', base, True)
    for value in [None, [], 'text', True, 1]: add('non-object-' + repr(value), value, False)
    for name, value, expected in [('float-one', 1.0, True), ('boolean', True, False),
                                   ('false', False, False), ('string', '1', False), ('zero', 0, False),
                                   ('two', 2, False), ('array', [], False), ('object', {}, False)]:
        top('schema-' + name, 'schema', value, expected)
    for key in ['schema', 'runtimeVersion', 'dshVersion', 'nodeVersion', 'files']:
        value = copy.deepcopy(base); del value[key]; add('missing-' + key, value, False)
    for key, values in [('runtimeVersion', ['', None, 1, [], '\0', '\n']),
                        ('dshVersion', ['', None, 1, []]),
                        ('nodeVersion', ['', '24.22.0', 24.22, None]),
                        ('files', [[], {}, None, [None], [1], ['item'], [[]]])]:
        for value in values: top(key + '-' + repr(value), key, value)
    for name, value in [('float-integer', 1.0), ('negative-zero', -0.0), ('boolean', True),
                        ('false', False), ('negative', -1), ('fraction', 1.5), ('string', '1'),
                        ('maximum-safe-integer', (1 << 53) - 1), ('unsafe-integer', 1 << 53),
                        ('nan', float('nan')), ('infinity', float('inf'))]:
        file('size-' + name, 'size', value)
    for value in ['a' * 64, 'A' * 64, 'a' * 63, 'a' * 65, 'a' * 64 + '\n', 1, None]:
        file('sha-' + repr(value), 'sha256', value)
    for value in ['', '/absolute', '../parent', 'a//b', 'a/./b', 'a/../b', 'a\\b', 'a\0b',
                  'x.node', 'x.so', 'x.so.1.2', 'client.node.js', 'lib.so.\u0661', 'lib.\u017fo', 'plain\nname',
                  'x.node\n', 'x.so.1\n', 'x.so.1\r\n']:
        candidate = copy.deepcopy(base)
        candidate['files'].append({'path': value, 'size': 0, 'sha256': '0' * 64})
        add('extra-path-' + repr(value), candidate)
    duplicate = copy.deepcopy(base); duplicate['files'].append(copy.deepcopy(duplicate['files'][0]))
    add('duplicate-path', duplicate, False)
    conflict = copy.deepcopy(base)
    conflict['files'].extend([{'path': name, 'size': 0, 'sha256': '0' * 64} for name in ['collision', 'collision/child']])
    add('file-directory-conflict', conflict, False)
    for entry in entries:
        value = copy.deepcopy(base); value['files'] = [item for item in value['files'] if item['path'] != entry]
        add('missing-required-' + entry, value, False)
    top('non-json-constant-in-unused-field', 'unused', float('nan'), False)
    # These are syntactically valid JSON numbers, unlike the NaN/Infinity tokens.
    cases.append({'name': 'unused-numeric-overflow', 'json': json.dumps(base)[:-1] + ',"unused":1e999}', 'expected': True})
    cases.append({'name': 'schema-exponent-one', 'json': json.dumps(base).replace('"schema": 1', '"schema": 1e0'), 'expected': True})

    core_path = root / 'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets'
    script = """import fs from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
const {validateManifest}=await import(pathToFileURL(process.argv[1]));
const cases=JSON.parse(await fs.readFile(process.argv[2],'utf8'));
const results=cases.map(item=>{try{validateManifest(JSON.parse(item.json));return {name:item.name,accepted:true};}
 catch(error){return {name:item.name,accepted:false,error:error.code??error.name};}});
process.stdout.write(JSON.stringify(results));
"""
    with tempfile.TemporaryDirectory(prefix='archive-actual-core-') as directory:
        directory = Path(directory)
        core_copy = directory / 'RuntimeCore.mts'; core_copy.write_bytes(core_path.read_bytes())
        inputs = directory / 'cases.json'; inputs.write_text(json.dumps(cases, ensure_ascii=False))
        command = [str(args.node.resolve()), '--input-type=module', '-e', script, str(core_copy), str(inputs)]
        execution = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if execution.returncode != 0:
        raise RuntimeError(execution.stderr)
    actual = json.loads(execution.stdout)
    results = []
    for case, core in zip(cases, actual, strict=True):
        assert case['name'] == core['name']
        try:
            audit.validate_manifest(audit.parse_manifest(case['json'].encode('utf-8')))
            accepted, message = True, None
        except (ValueError, TypeError, KeyError, UnicodeError) as error:
            accepted, message = False, str(error)
        results.append({'name': case['name'], 'json': case['json'], 'coreAccepted': core['accepted'],
                        'auditAccepted': accepted, 'coreError': core.get('error'), 'auditError': message,
                        'expected': case['expected']})
    divergences = [row for row in results if row['coreAccepted'] != row['auditAccepted'] or
                   (row['expected'] is not None and row['coreAccepted'] != row['expected'])]
    sha = lambda file: hashlib.sha256(file.read_bytes()).hexdigest()
    report = {'cases': len(results), 'divergences': divergences, 'results': results,
              'requiredEntries': entries, 'auditSHA256': sha(helper), 'coreSHA256': sha(core_path),
              'hostSHA256': sha(root / 'app/ohos/entry/src/main/cpp/host_core.cpp'),
              'nodeSHA256': sha(args.node.resolve()), 'nodeArgv': command, 'nodeExitCode': execution.returncode,
              'scope': 'Python audit versus exact RuntimeCore source in real Node24 type stripping; no Ark/device execution'}
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'cases': len(results), 'divergences': len(divergences), 'report': str(args.report)}))
    raise SystemExit(1 if divergences else 0)


if __name__ == '__main__':
    main()
