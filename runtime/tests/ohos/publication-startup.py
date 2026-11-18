#!/usr/bin/env python3
"""Real Node startup controls; native fixtures remain Linux-only evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    for name in ('node', 'simulation', 'linked-lib', 'out'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    runtime = Path(__file__).resolve().parents[2]
    publication = runtime / 'ohos/publication'
    preload, index = publication / 'preload.mjs', publication / 'index.mjs'
    probe = "console.log(JSON.stringify({platform:process.platform,installed:!!globalThis[Symbol.for('dsh.go.ohos.publication')]}))"
    imported = 'import {installPublication} from ' + json.dumps(index.as_uri()) + ';'
    worker_probe = """import { Worker } from 'node:worker_threads';
const worker = new Worker("import {parentPort,isMainThread} from 'node:worker_threads'; parentPort.postMessage({installed:!!globalThis[Symbol.for('dsh.go.ohos.publication')],isMainThread});", {eval:true,env:{...process.env,DSH_HOME:'/not-an-authorized-home'}});
const [result] = await Promise.all([
new Promise((resolve,reject)=>{worker.once('message',resolve);worker.once('error',reject);}),
new Promise((resolve,reject)=>{worker.once('exit',code=>code===0?resolve():reject(new Error('worker exit '+code)));})]);
console.log(JSON.stringify(result));"""
    concurrent = imported + "const first=installPublication();const second=installPublication();const rows=await Promise.allSettled([first,second]);console.log(JSON.stringify({first:rows[0].value?.installed,second:rows[1].reason?.code}));"
    missing_marker = imported + "const real=process._linkedBinding;process._linkedBinding=name=>{const result=real(name);if(name!=='dsh_ohos_publication')return result;const copy={...result};delete copy.getOwnershipMarker;return copy;};await installPublication();"
    cases = [
        ('ordinary-linux', False, False, True, 'absent', {}, probe, {'platform': 'linux', 'installed': False}, None),
        ('environment-alone', False, False, True, 'absent', {'DSH_GO_OHOS_SIM': '1', 'DSH_GO_OHOS_SIM_PLATFORM': 'openharmony'}, probe, {'platform': 'linux', 'installed': False}, None),
        ('strict-linked', True, True, True, 'valid', {}, probe, {'platform': 'openharmony', 'installed': True}, None),
        ('strict-missing-binding', True, False, True, 'valid', {}, probe, None, 'ERR_OHOS_PUBLICATION_BINDING_MISSING'),
        ('injected-missing-marker-member', True, True, False, 'valid', {}, missing_marker, None, 'ERR_OHOS_PUBLICATION_BINDING_INVALID'),
        ('duplicate-install', True, True, True, 'valid', {}, imported + 'await installPublication();', None, 'ERR_OHOS_PUBLICATION_DUPLICATE'),
        ('concurrent-install', True, True, False, 'valid', {}, concurrent, {'first': True, 'second': 'ERR_OHOS_PUBLICATION_DUPLICATE'}, None),
        ('wrong-node-version', True, False, False, 'valid', {}, imported + "Object.defineProperty(process.versions,'node',{value:'24.0.0'});await installPublication();", None, 'ERR_OHOS_PUBLICATION_NODE_VERSION'),
        ('worker-inherited-preload', True, True, True, 'valid', {}, worker_probe, {'installed': False, 'isMainThread': False}, None),
    ]
    for kind in ('absent', 'relative', 'root', 'missing', 'file'):
        cases.append(('invalid-home-' + kind, True, True, True, kind, {}, probe, None, 'ERR_OHOS_PUBLICATION_DATA_DIRECTORY'))
    cases += [
        ('canonical-home-symlink', True, True, True, 'home-symlink', {}, probe, {'platform': 'openharmony', 'installed': True}, None),
        ('ledger-directory-symlink', True, True, True, 'ledger-symlink', {}, probe, None, 'ERR_OHOS_LEDGER_DIRECTORY'),
        ('ledger-directory-public', True, True, True, 'ledger-public', {}, probe, None, 'ERR_OHOS_LEDGER_DIRECTORY'),
        ('ledger-corrupt', True, True, True, 'ledger-corrupt', {}, probe, None, 'ERR_OHOS_LEDGER_CORRUPT'),
    ]
    rows = []
    with tempfile.TemporaryDirectory(prefix='dsh-publication-startup-') as base:
        for name, simulation, linked, install, home_kind, additions, source, expected, error in cases:
            case = Path(base) / name
            case.mkdir(mode=0o700)
            home = case / 'app-data'
            home.mkdir(mode=0o700)
            configured = str(home)
            if home_kind == 'relative': configured = 'relative-app-home'
            elif home_kind == 'root': configured = '/'
            elif home_kind == 'missing': configured = str(case / 'missing-home')
            elif home_kind == 'file':
                f = case / 'regular-file'; f.write_text('keep'); configured = str(f)
            elif home_kind == 'home-symlink':
                link = case / 'home-alias'; link.symlink_to(home, target_is_directory=True); configured = str(link)
            elif home_kind == 'ledger-symlink':
                outside = case / 'other-directory'; outside.mkdir(mode=0o700)
                (home / 'ohos-ownership').symlink_to(outside, target_is_directory=True)
            elif home_kind == 'ledger-public':
                p = home / 'ohos-ownership'; p.mkdir(mode=0o700); p.chmod(0o755)
            elif home_kind == 'ledger-corrupt':
                p = home / 'ohos-ownership'; p.mkdir(mode=0o700); (p / 'ledger.json').write_text('{incomplete')
            env = os.environ.copy()
            for key in ('LD_PRELOAD', 'DSH_GO_OHOS_SIM', 'DSH_GO_OHOS_SIM_PLATFORM', 'DSH_GO_OHOS_SIM_ADDONS', 'NODE_OPTIONS', 'DSH_HOME'):
                env.pop(key, None)
            if home_kind != 'absent': env['DSH_HOME'] = configured
            env.update(additions)
            argv = [str(args.node.resolve()), '--jitless']
            if simulation:
                argv += ['--import', str(args.simulation.resolve())]
                env['DSH_GO_OHOS_SIM_PLATFORM'] = 'openharmony'
            if linked: env['LD_PRELOAD'] = str(args.linked_lib.resolve())
            if install: argv += ['--import', str(preload)]
            argv += ['--input-type=module', '--eval', source]
            result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=15)
            try:
                passed = result.returncode != 0 and error in result.stderr if error else result.returncode == 0 and json.loads(result.stdout) == expected
            except (ValueError, TypeError): passed = False
            rows.append({'case': name, 'passed': passed, 'exit': result.returncode, 'argv': argv, 'configuredHome': env.get('DSH_HOME'), 'stdout': result.stdout, 'stderr': result.stderr})
            print(name, 'PASS' if passed else 'FAIL')
    inputs = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in (args.node, args.simulation, args.linked_lib, preload, index, publication / 'atomic.mjs', publication / 'ledger.mjs', Path(__file__).resolve())}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({'scope': 'Linux startup controls with own linked fixture; no SDK/target ABI claim', 'inputs': inputs, 'cases': rows}, indent=2) + '\n')
    return 0 if all(row['passed'] for row in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
