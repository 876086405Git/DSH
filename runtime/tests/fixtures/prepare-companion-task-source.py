#!/usr/bin/env python3
"""Prepare the finite F source test peers from an already patched runtime.

No downloads, dependency installation, engine boot, or silent skips. The task
and model source files and copied dependencies must match the supplied pins.
"""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tree_sha(directory):
    rows = [[p.relative_to(directory).as_posix(), sha(p.read_bytes())]
            for p in sorted(directory.rglob('*'))
            if p.is_file() and 'node_modules' not in p.relative_to(directory).parts]
    return sha(json.dumps(rows, separators=(',', ':'), ensure_ascii=True).encode())


def region(source, name):
    start = source.index('//#region lib/types/' + name + '.js')
    return source[start:source.index('//#endregion', start)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-modules', required=True, type=Path)
    parser.add_argument('--target', required=True, choices=['android', 'ohos'])
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    pins = json.loads((here / 'companion-task-source-pins.json').read_text())
    modules = args.node_modules.resolve()
    sources = {}
    for path, expected in pins['targets'][args.target].items():
        data = (modules / path).read_bytes()
        if sha(data) != expected:
            raise SystemExit('Source pin mismatch: ' + path)
        sources[path.split('/')[1]] = data.decode()
    for name, expected in pins['dependencies'].items():
        package = modules / name
        if json.loads((package / 'package.json').read_text())['version'] != expected['version'] \
                or tree_sha(package) != expected['tree_sha256']:
            raise SystemExit('Dependency pin mismatch: ' + name)
    model_sources = {}
    for name, binding in pins['model_sources'][args.target].items():
        data = (modules / name).read_bytes()
        if sha(data) != binding['sha256']:
            raise SystemExit('Model source pin mismatch: ' + name)
        model_sources[binding['destination']] = data
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    for name in pins['dependencies']:
        shutil.copytree(modules / name, out / 'node_modules' / name,
                        ignore=shutil.ignore_patterns('node_modules'))

    def package(name, code):
        directory = out / 'node_modules/@deepseek-ai' / name
        directory.mkdir(parents=True)
        (directory / 'package.json').write_text(json.dumps({
            'name': '@deepseek-ai/' + name, 'type': 'module', 'main': 'index.js'}))
        (directory / 'index.js').write_text(code)

    source = sources['dsh-storage']
    package('dsh-storage', source[source.index('//#region lib/types/error.js'):
        source.index('var Storage = class')] +
        '\nexport {StorageError,BackendRegistry,UNIT_NAME_RE,storageBackendServiceKey};\n')
    for name in ['dsh-storage-domain', 'dsh-storage-json']:
        code = sources[name].replace('import z from "@deepseek-ai/schemastery";\n', '')
        code, count = re.subn(r'const Config = z\.object\(\{.*?\}\);',
            'const Config = undefined;', code, count=1, flags=re.S)
        if count != 1:
            raise SystemExit('The pinned unused Config region changed: ' + name)
        package(name, code)
    package('dsh-atomic-write', sources['dsh-atomic-write'])
    sandbox = sources['dsh-sandbox']
    package('dsh-sandbox', 'const assertNever=value=>{throw new Error(String(value));};\n' +
        region(sandbox, 'locales') + '\n' + region(sandbox, 'escalation') +
        '\nexport {approveEscalation};\n')
    policy = sources['dsh-sandbox-policy']
    start = policy.index('function setSandboxMode(')
    package('dsh-sandbox-policy', policy[start:policy.index('//#endregion', start)] +
        '\nexport {setSandboxMode};\n')
    approval = sources['dsh-user-approval']
    package('dsh-user-approval', """import {randomUUID} from 'node:crypto';
import {z as z$1} from 'zod';
const schema=new Proxy(()=>schema,{get:()=>schema}); const z=schema;
class Service {static init=Symbol('init');constructor(ctx){this.ctx=ctx;}}
const scopeTarget=agent=>agent;
""" + region(approval, 'types') + '\n' + region(approval, 'index') +
        '\nexport {ApprovalService,setApprovalPolicy,approvalStateDefinition};\n')
    (out / 'task-runtime.mjs').write_text("""const dshGoRecall={guardSession(){}};
const errorChain=error=>String(error.message??error);
const SessionSeq=value=>value;
const assertNever=value=>{throw new Error(String(value));};
""" + region(sources['dsh-agent-loop'], 'agent') + '\nexport {ReactLoopAgent};\n')
    bridge = here.parents[2] / 'runtime/bridge/dsh-go-bridge/lib/companion'
    shutil.copytree(bridge, out / 'companion')
    (out / 'package.json').write_text('{"type":"module"}\n')
    for name, data in model_sources.items():
        destination = out / 'model-source' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    (out / 'model-source/package.json').write_text('{"type":"module"}\n')
    evidence = {'scope': pins['scope'], 'target': args.target,
        'sources': pins['targets'][args.target], 'dependencies': pins['dependencies'],
        'model_sources': pins['model_sources'][args.target],
        'bridge': {p.relative_to(bridge).as_posix(): sha(p.read_bytes())
                   for p in sorted(bridge.rglob('*.js'))}}
    (out / 'source-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(out)


if __name__ == '__main__':
    main()
