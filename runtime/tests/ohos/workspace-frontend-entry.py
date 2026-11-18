#!/usr/bin/env python3
"""Explicit-input public frontend check. Never prepares or alters a payload."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import stat
import subprocess
import time

HERE = Path(__file__).resolve().parent


def identity(path):
    path = Path(path)
    value = hashlib.sha256()
    with path.open('rb') as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            value.update(block)
    info = path.stat()
    return {'path': str(path), 'resolvedPath': str(path.resolve()), 'bytes': info.st_size,
            'sha256': value.hexdigest(), 'mode': oct(stat.S_IMODE(info.st_mode))}


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'payload', 'node', 'typescript-prefix', 'native-directory', 'publication-fixture', 'out']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--provenance-file', '--overlay-receipt', dest='provenance_file', type=Path)
    parser.add_argument('--jitless', action='store_true')
    args = parser.parse_args()
    source, payload, node, native, output = [value.resolve() for value in
        [args.source, args.payload, args.node, args.native_directory, args.out]]
    if output.exists():
        raise SystemExit('--out must be a fresh directory; never overwrite an earlier result')
    product_paths = [
        'runtime/ohos/preload.mjs', 'runtime/ohos/process/index.mjs',
        'runtime/ohos/process/command-router.mjs', 'runtime/ohos/process/runtime.mjs',
        'runtime/ohos/process/worker.mjs', 'runtime/ohos/process/filesystem.mjs',
        'runtime/ohos/process/files/authority.mjs', 'runtime/ohos/process/files/grant-fs.mjs',
        'runtime/ohos/process/files/process-authority.mjs',
    ]
    # The helper can legitimately be absent from a baseline red. Its presence
    # and exact bytes are recorded without synthesizing a substitute.
    helper = payload / 'runtime/ohos/process/files/workspace-paths.mjs'
    paths = [HERE / name for name in ['workspace-frontend-entry.mjs', 'workspace-frontend-instrumentation.mjs', 'workspace-frontend-entry.py']]
    paths += [payload / name for name in product_paths]
    if helper.exists():
        paths.append(helper)
    paths += [payload / ('node_modules/@deepseek-ai/' + name + '/lib/index.js') for name in [
        'cordis', 'dsh-storage-domain', 'dsh-workspace', 'dsh-working-directory', 'dsh-fs-local', 'dsh-subprocess',
    ]]
    paths += [payload / 'node_modules/@deepseek-ai/dsh/lib/bin.js']
    paths += [source / name for name in [
        'runtime/ohos/sim/preload.mjs', 'runtime/tests/ohos/authorized-workspaces-fixture.mjs',
        'runtime/tests/ohos/entry-ability-fixture.mjs',
        'app/ohos/entry/src/main/ets/plugins/AuthorizedWorkspacesPlugin.ets',
        'app/ohos/entry/src/main/ets/plugins/NativeFilePolicy.ets',
        'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets',
    ]]
    paths += [native / name for name in ['libdsh_host.so', 'libdsh_workspace_grants.so',
        'workspace-publisher.node', 'libdsh_flock.so', 'libdsh_require_builtin.so']]
    paths += [node, args.publication_fixture.resolve(), args.typescript_prefix.resolve() / 'node_modules/typescript/package.json']
    if args.provenance_file:
        paths.append(args.provenance_file.resolve())
    before = [identity(path) for path in paths]
    output.mkdir(mode=0o700)
    for name in ['home', 'tmp', 'physical', 'temporary', 'linux-tools']:
        (output / name).mkdir(mode=0o700)
    config = {'source': str(source), 'payload': str(payload), 'nativeDirectory': str(native),
              'physical': str(output / 'physical'), 'temporary': str(output / 'temporary'),
              'result': str(output / 'REPORT.json')}
    save(output / 'CONFIG.json', config)
    environment = {
        'PATH': os.pathsep.join([str(node.parent), os.defpath]), 'HOME': str(output / 'home'),
        'TMPDIR': str(output / 'tmp'), 'LANG': 'C.UTF-8',
        'LD_PRELOAD': str(native / 'libdsh_host.so') + ':' + str(args.publication_fixture.resolve()),
        'DSH_HOME': str(output / 'home'), 'NARB_DISABLE_NATIVE_CACHE': '1',
        'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(native),
        'DSH_GO_OHOS_LINUX_DIRECTORY': str(output / 'linux-tools'),
        'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony',
        'OHOS_933_CONFIG': str(output / 'CONFIG.json'),
        'OHOS_TYPESCRIPT_PREFIX': str(args.typescript_prefix.resolve()),
        'OHOS_WORKSPACE_GRANTS_ADDON': str(native / 'workspace-publisher.node'),
    }
    command = [str(node), *(['--jitless'] if args.jitless else []), '--max-old-space-size=256',
               '--import', str(HERE / 'workspace-frontend-instrumentation.mjs'),
               '--import', str(payload / 'runtime/ohos/preload.mjs'),
               '--import', str(HERE / 'workspace-frontend-entry.mjs'),
               str(payload / 'node_modules/@deepseek-ai/dsh/lib/bin.js'), '--profile', 'web', '--dump-config']
    save(output / 'INPUTS.json', {'scope': 'Explicit input identities; an attached provenance file is recorded, not validated as a composer receipt',
        'source': str(source), 'payload': str(payload), 'helperPresent': helper.exists(),
        'provenanceFile': str(args.provenance_file.resolve()) if args.provenance_file else None,
        'files': before})
    save(output / 'COMMAND.json', {'argv': command, 'cwd': str(output), 'environment': environment,
        'boundary': 'Only this fixed environment is passed to the Node child. No ambient environment is copied.'})
    started = time.monotonic()
    timed_out = False
    with (output / 'stdout').open('wb') as stdout, (output / 'stderr').open('wb') as stderr:
        try:
            result = subprocess.run(command, cwd=output, env=environment,
                                    stdout=stdout, stderr=stderr, timeout=90)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code, timed_out = 124, True
    elapsed = time.monotonic() - started
    after = [identity(path) for path in paths]
    save(output / 'SOURCE-AFTER.json', after)
    report_path = output / 'REPORT.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    passed = code == 0 and before == after and report.get('pass') is True
    classification = 'PASS_SCOPED_FRONTEND' if passed else (
        'TIMEOUT_UNCLASSIFIED' if timed_out else
        'INPUT_DRIFT' if before != after else
        'PREPARATION_FAILED' if not report or report.get('setupError') else
        'BEHAVIOR_RED' if any(not row.get('pass') for row in report.get('cases', [])) else
        'PROCESS_OR_CLEANUP_FAILED')
    summary = {'pass': passed, 'classification': classification, 'exitCode': code,
               'seconds': elapsed, 'sameInputsAfter': before == after,
               'cases': len(report.get('cases', [])),
               'passedCases': sum(row.get('pass') is True for row in report.get('cases', [])),
               'report': identity(report_path) if report_path.exists() else None,
               'stdout': identity(output / 'stdout'), 'stderr': identity(output / 'stderr'),
               'scope': 'No full DSH chat, OH SDK, device, Linux guest or durable-storage claim; this check does not establish overall composition provenance.'}
    save(output / 'RESULT.json', summary)
    print(json.dumps({'out': str(output), **{key: summary[key] for key in
        ['pass', 'classification', 'exitCode', 'seconds', 'cases', 'passedCases', 'sameInputsAfter']}}))
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
