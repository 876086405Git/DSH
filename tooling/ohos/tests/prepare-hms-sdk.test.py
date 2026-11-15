#!/usr/bin/env python3
"""Real preparer filesystem boundaries on tiny SDK fixtures, not SDK type validation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--helper', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
helper = args.helper.resolve()
stubs = helper.parent
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
commands, checks = [], []
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def setup(name, linked=False):
    root = out / name
    sdk, work = root / 'sdk', root / 'work'
    work.mkdir(parents=True)
    for part in ['ets', 'js', 'native', 'toolchains']:
        (sdk / part).mkdir(parents=True)
        (sdk / part / 'oh-uni-package.json').write_text(json.dumps({
            'name': 'Ets', 'path': part, 'apiVersion': 26, 'version': '26.0.0.38'}))
    for rel in ['kits', 'build-tools/ets-loader/kit_configs']:
        (sdk / 'ets' / rel).mkdir(parents=True)
    if linked:
        (sdk / 'api-shared').mkdir()
        (sdk / 'ets/api').symlink_to(sdk / 'api-shared', target_is_directory=True)
    else:
        (sdk / 'ets/api').mkdir()
    (sdk / 'ets/api/PublicGuard.d.ts').write_text('export declare function publicGuard(value: string): void;\n')
    return sdk, work

def run(name, sdk, work):
    argv = ['python3', '-I', str(helper), str(sdk), str(work), str(stubs)]
    p = subprocess.run(argv, capture_output=True, timeout=20)
    (out / (name + '.stdout')).write_bytes(p.stdout)
    (out / (name + '.stderr')).write_bytes(p.stderr)
    commands.append({'name': name, 'argv': argv, 'exitCode': p.returncode})
    return p

def record(name, passed, **observed):
    checks.append({'name': name, 'passed': bool(passed), **observed})

sdk, work = setup('plain')
original = sha(sdk / 'ets/api/PublicGuard.d.ts')
first = run('plain-first', sdk, work)
assert first.returncode == 0
cached = Path(first.stdout.decode().strip())
repeat = run('plain-repeat', sdk, work)
record('ordinary prepare/reuse', repeat.returncode == 0 and repeat.stdout == first.stdout)
stub = cached / '26.0.0/ets/api/@hms.collaboration.systemShare.d.ts'
good = stub.read_bytes()
stub.write_bytes(good + b'\n// changed fixture\n')
p = run('changed-stub', sdk, work)
record('changed stub rejected', p.returncode != 0)
stub.write_bytes(good)
guard = cached / '26.0.0/ets/api/PublicGuard.d.ts'
guard.write_text('export declare function publicGuard(value: number): void;\n')
p = run('changed-public', sdk, work)
record('changed public declaration rejected', p.returncode != 0,
       inputSHA256=original, cachedSHA256=sha(guard), exitCode=p.returncode)
guard.write_bytes((sdk / 'ets/api/PublicGuard.d.ts').read_bytes())
extra = cached / '26.0.0/ets/api/Unexpected.d.ts'
extra.write_text('// unexpected public API\n')
p = run('extra-public', sdk, work)
record('extra cached public declaration rejected', p.returncode != 0)
extra.unlink()
guard.unlink()
p = run('missing-public', sdk, work)
record('missing copied public declaration rejected', p.returncode != 0)

sdk, work = setup('linked-api', linked=True)
before = {p.name: sha(p) for p in (sdk / 'api-shared').iterdir()}
p = run('linked-api', sdk, work)
after = {p.name: sha(p) for p in (sdk / 'api-shared').iterdir()}
private = Path(p.stdout.decode().strip()) if p.returncode == 0 else None
record('SDK directory symlink never writes through', p.returncode == 0 and before == after,
       inputBefore=before, inputAfter=after, exitCode=p.returncode)
record('private API copy has no directory link', private is not None and not (private / '26.0.0/ets/api').is_symlink())

sdk, work = setup('existing-declaration')
p = sdk / 'ets/api/@hms.collaboration.systemShare.d.ts'
p.write_text('// original official declaration fixture\n')
identity = sha(p)
result = run('existing-declaration', sdk, work)
record('official declaration collision rejected unchanged', result.returncode != 0 and sha(p) == identity)

sdk, work = setup('cyclic-link')
(sdk / 'ets/api/cycle').symlink_to(sdk / 'ets', target_is_directory=True)
result = run('cyclic-link', sdk, work)
record('cyclic SDK layout rejected', result.returncode != 0)

report = {'scope': 'Actual helper on isolated minimal SDK filesystem fixtures; no actual SDK compiler/device claim',
          'helperSHA256': sha(helper), 'testSHA256': sha(Path(__file__)),
          'pass': sum(x['passed'] for x in checks), 'fail': sum(not x['passed'] for x in checks),
          'checks': checks, 'commands': commands}
(out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: report[k] for k in ['helperSHA256', 'pass', 'fail']}))
raise SystemExit(0 if report['fail'] == 0 else 1)
