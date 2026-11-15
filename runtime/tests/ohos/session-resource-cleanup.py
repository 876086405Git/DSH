#!/usr/bin/env python3
"""Real OH deletion route/SDK cleanup on the existing Linux host target prefix.

Prepare only the two real deletion variants and a small private execution view.
The prefix is the full host target used by publication-platform, including its
original native flock package. This does not admit an omit-optional payload or
run a complete compose. Production payload retention is checked separately.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import subprocess
import traceback


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def prepare(source, prefix, out):
    private = out / 'private'
    private.mkdir()
    (private / 'work').mkdir()
    view = private / 'view'
    (view / 'node_modules').mkdir(parents=True)
    (view / 'package.json').write_text('{"type":"module","private":true}\n')
    copied, copied_bytes = [], 0

    def copy(origin, target, role):
        nonlocal copied_bytes
        data = origin.read_bytes()
        copied_bytes += len(data)
        if copied_bytes > 8 * 1024 * 1024:
            raise ValueError('Private test view exceeded its 8 MiB copy bound')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        copied.append({'origin': str(origin), 'destination': str(target.relative_to(view)),
                       'role': role, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})

    owned = '@deepseek-ai/dsh-session-persistence-jsonl'
    for item in sorted((prefix / 'node_modules').iterdir()):
        if item.name.startswith('.'):
            continue
        target = view / 'node_modules' / item.name
        if item.name.startswith('@'):
            target.mkdir()
            for package in sorted(item.iterdir()):
                if item.name + '/' + package.name == owned:
                    origin = package.resolve()
                    for member in sorted(origin.rglob('*')):
                        if member.is_file():
                            copy(member, target / package.name / member.relative_to(origin), 'owned-jsonl-package')
                else:
                    target.joinpath(package.name).symlink_to(package.resolve())
        else:
            target.symlink_to(item.resolve())
    for member in sorted((source / 'runtime/bridge/dsh-go-bridge').rglob('*')):
        if member.is_file():
            copy(member, view / member.relative_to(source), 'exact-shared-bridge-package')

    script = source / 'runtime/ohos/package/compose-runtime.py'
    spec = importlib.util.spec_from_file_location('session_resource_cleanup_composition', script)
    composition = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(composition)
    generated = out / 'generated-deletion'
    variants = composition.deletion_variants(source, prefix, generated)
    for row in variants['files']:
        origin = generated / row['file']
        if sha(origin) != row['sha256']:
            raise ValueError('Generated deletion variant identity changed')
        target = view / row['destination']
        before = sha(target)
        copy(origin, target, 'actual-generated-OH-variant')
        copied[-1]['beforeSha256'] = before
    return {
        'scope': 'Finite real deletion variants/private view; no full compose or npm preparation',
        'source': str(source), 'prefix': str(prefix), 'view': str(view),
        'copyBytes': copied_bytes, 'copyLimitBytes': 8 * 1024 * 1024,
        'variants': variants, 'copied': copied, 'dependencyLinksAreReadOnly': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'prefix', 'node', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    source, prefix, node, out = (getattr(args, name).resolve() for name in ['source', 'prefix', 'node', 'out'])
    out.mkdir(parents=True, exist_ok=False)
    actor = source / 'runtime/tests/ohos/session-resource-cleanup.test.mjs'
    input_paths = [source / path for path in [
        'runtime/tests/ohos/session-resource-cleanup.py',
        'runtime/tests/ohos/session-resource-cleanup.test.mjs',
        'runtime/ohos/package/compose-runtime.py',
        'runtime/ohos/package/session-deletion-ohos.diff',
        'runtime/session-deletion/core.mjs',
        'runtime/lib/rtbuild.py',
    ]]
    input_paths += sorted(path for path in (source / 'runtime/bridge/dsh-go-bridge').rglob('*') if path.is_file())
    before = {str(path): sha(path) for path in input_paths}
    record = {'startedUTC': utc(), 'source': str(source), 'prefix': str(prefix),
              'scope': 'Actual authenticated bridge, JSONL-v2, Agent/default title and public SDK cleanup; real Linux flock and loopback WS. No device or physical-close SLA.',
              'sourceBefore': before, 'node': {'path': str(node), 'sha256': sha(node)}, 'exitCode': 2}
    view = None
    try:
        view = prepare(source, prefix, out)
        (out / 'VIEW.json').write_text(json.dumps(view, ensure_ascii=False, indent=2) + '\n')
        private = out / 'private'
        env = {key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL', 'TZ'] if key in os.environ}
        env.update(HOME=str(private / 'home'), DSH_HOME=str(private / 'dsh-home'), DSH_TELEMETRY_DISABLED='1',
                   DSH_SESSION_CLEANUP_SOURCE=str(source), DSH_SESSION_CLEANUP_VIEW=view['view'],
                   DSH_SESSION_CLEANUP_OUTPUT=str(out))
        argv = [str(node), '--jitless', '--experimental-import-meta-resolve', '--test', '--test-isolation=none',
                '--test-reporter=tap', str(actor)]
        record.update(argv=argv, cwd=str(private / 'work'), environment=env)
        with (out / 'test.log').open('xb') as stdout, (out / 'stderr.log').open('xb') as stderr:
            try:
                child = subprocess.run(argv, cwd=private / 'work', env=env, stdout=stdout, stderr=stderr, timeout=35)
                record['exitCode'] = child.returncode
            except subprocess.TimeoutExpired:
                record.update(exitCode=124, outerTimeoutSeconds=35)
        observation = out / 'OBSERVATION.json'
        if observation.exists():
            actual = json.loads(observation.read_text())
            record['observationSHA256'] = sha(observation)
            record['observationStatus'] = actual['status']
            record['nativeModules'] = [{'path': path, 'sha256': sha(path)} for path in actual.get('actualNativeModules', [])]
    except Exception:
        record['failure'] = traceback.format_exc()
    finally:
        after = {str(path): sha(path) for path in input_paths}
        record.update(sourceAfter=after, sourceUnchanged=after == before,
                      nodeUnchanged=sha(node) == record['node']['sha256'], finishedUTC=utc())
        if view:
            record['copiedInputsAfter'] = [{**row, 'unchanged': sha(row['origin']) == row['sha256']} for row in view['copied']]
            record['copiedInputsUnchanged'] = all(row['unchanged'] for row in record['copiedInputsAfter'])
        if not record['sourceUnchanged'] or not record['nodeUnchanged'] or record.get('copiedInputsUnchanged') is False:
            record['exitCode'] = 2
        (out / 'RUN.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: record.get(key) for key in ['exitCode', 'observationStatus', 'sourceUnchanged', 'copiedInputsUnchanged']}))
    raise SystemExit(record['exitCode'])


if __name__ == '__main__':
    main()
