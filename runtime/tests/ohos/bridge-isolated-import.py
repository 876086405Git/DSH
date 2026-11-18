#!/usr/bin/env python3
"""Import the actual bridge copy without any ancestor node_modules directory."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['node', 'bridge', 'out']:
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    node, source, out = args.node.resolve(), args.bridge.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    utc = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat()

    def save(name, value):
        (out / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

    def inventory(root):
        result = {}
        for path in sorted(root.rglob('*')):
            assert not path.is_symlink(), 'The isolated bridge must contain actual files'
            assert path.name != 'node_modules', 'The source bridge must not carry dependencies'
            if path.is_file():
                result[path.relative_to(root).as_posix()] = {'bytes': path.stat().st_size, 'sha256': sha(path)}
        return result

    report = {'status': 'RUNNING', 'startUTC': utc(), 'source': str(source),
              'node': {'path': str(node), 'sha256': sha(node)},
              'scope': 'Strict standalone module loading only; Host services and configuration execution are separate functional gates'}
    save('report.json', report)
    temporary = Path(tempfile.mkdtemp(prefix='dsh-bridge-isolated-', dir='/tmp'))
    try:
        expected = inventory(source)
        assert all(name in expected for name in ['lib/index.js', 'package.json', 'cordis.patch.yml'])
        target = temporary / 'bridge'
        shutil.copytree(source, target)
        assert inventory(target) == expected
        save('source-files.json', expected)
        save('copy-files.json', inventory(target))
        ancestors = [target / 'lib', target, temporary, *temporary.parents]
        report['ancestorChecks'] = [{'path': str(path / 'node_modules'),
                                     'absent': not os.path.lexists(path / 'node_modules')} for path in ancestors]
        assert all(item['absent'] for item in report['ancestorChecks'])
        script = "import assert from 'node:assert/strict';\n"
        script += "assert.equal(process.version, 'v24.22.1');\n"
        script += "assert.equal(typeof WebAssembly, 'undefined');\n"
        script += 'const bridge = await import(' + json.dumps((target / 'lib/index.js').as_uri()) + ');\n'
        script += "assert.equal(bridge.name, 'dsh-go-bridge'); assert.equal(typeof bridge.apply, 'function');\n"
        script += "console.log(JSON.stringify({status:'PASS_ISOLATED_IMPORT', node:process.version, wasm:typeof WebAssembly, name:bridge.name, apply:typeof bridge.apply}));\n"
        (out / 'probe.mjs').write_text(script)
        environment = {key: os.environ[key] for key in ['PATH'] if key in os.environ}
        environment.update(LANG='C.UTF-8', LC_ALL='C.UTF-8', TZ='UTC')
        command = {'argv': [str(node), '--jitless', '--input-type=module', '--eval', script],
                   'cwd': str(temporary), 'env': environment, 'startUTC': utc(), 'timeoutSeconds': 30}
        save('command.json', command)
        process = subprocess.run(command['argv'], cwd=temporary, env=environment,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        (out / 'stdout.log').write_bytes(process.stdout)
        (out / 'stderr.log').write_bytes(process.stderr)
        command.update(exitCode=process.returncode, endUTC=utc())
        save('command.json', command)
        assert process.returncode == 0
        observation = json.loads(process.stdout)
        assert observation['status'] == 'PASS_ISOLATED_IMPORT'
        assert inventory(source) == expected and inventory(target) == expected
        report.update(status='PASS_ISOLATED_IMPORT', observation=observation,
                      files=len(expected), inputsUnchanged=True, copyUnchanged=True)
    except Exception as error:
        report.update(status='FAIL_ISOLATED_IMPORT', error=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        shutil.rmtree(temporary)
        report.update(endUTC=utc(), temporary=str(temporary), temporaryRemoved=not temporary.exists())
        save('report.json', report)
    print(json.dumps({'status': report['status'], 'files': report['files'],
                      'temporaryRemoved': report['temporaryRemoved']}), flush=True)


if __name__ == '__main__':
    main()
