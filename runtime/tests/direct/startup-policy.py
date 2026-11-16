#!/usr/bin/env python3
"""Run actual DshProcess policy under a real non-root UID, with bounded API faults."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
here = Path(__file__).resolve().parent
repo = here.parents[2]
base = Path(tempfile.mkdtemp(prefix='dsh-direct-startup-'))
base.chmod(0o755)
owned = base / 'owned'
owned.mkdir()
uid = 65534 if os.geteuid() == 0 else os.geteuid()
gid = 65534 if os.geteuid() == 0 else os.getegid()
if os.geteuid() == 0:
    os.chown(owned, uid, gid)
identity = {'user': uid, 'group': gid, 'extra_groups': []} if os.geteuid() == 0 else {}
jar = base / 'startup.jar'
runtime = repo / 'app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime'
sources = [runtime / name for name in ['DshProcess.kt', 'LogRedactor.kt', 'CrashClassifier.kt', 'ProotTempFiles.kt', 'LaunchDiagnostics.kt', 'DirectLaunch.kt', 'L2sMigration.kt', 'RuntimeProcessOwnership.kt', 'SpeechGuest.kt', 'TawcrootLaunch.kt', 'TawcrootLinks.kt']]
sources += list((here / 'startup-probe').glob('*.kt'))
sources += [here / 'cleanup-probe' / name for name in ['AndroidContext.kt', 'AndroidOs.kt', 'AndroidProcess.kt', 'UnusedPhoneContract.kt']]
(out / 'inputs.json').write_text(json.dumps([{'path': str(p.relative_to(repo)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sources], indent=2) + '\n')
records = []
try:
    command = ['bash', str(here / 'compile-startup-probe.sh'), str(jar)]
    start = datetime.now(timezone.utc).isoformat()
    compiled = subprocess.run(command, text=True, capture_output=True, timeout=120)
    (out / 'compile.stdout.log').write_text(compiled.stdout)
    (out / 'compile.stderr.log').write_text(compiled.stderr)
    (out / 'compile-command.json').write_text(json.dumps({'argv': command, 'started_utc': start,
        'finished_utc': datetime.now(timezone.utc).isoformat(), 'exit': compiled.returncode}, indent=2) + '\n')
    assert compiled.returncode == 0, compiled.stderr
    cases = [('StartupPolicyProbeKt', case) for case in [
        'default-unknown', 'safe-unknown', 'l2s-fallback-unknown', 'direct-unknown',
        'default-owned', 'default-captured-unknown', 'default-owned-reaped',
        'fresh-default-alias', 'prior-direct-alias', 'carried-direct-alias', 'symlink-config-no-alias',
    ]]
    cases += [('PidHintProbeKt', case) for case in ['stale-hint', 'captured-hidden', 'visible-owned']]
    cases += [('StartupObservationProbeKt', case) for case in [
        'direct-ambient', 'tawc-ambient', 'direct-captured', 'tawc-captured', 'proot-links-ambient',
    ]]
    cases += [('ProcessRetryProbeKt', case) for case in ['ambient-retry', 'captured-retry']]
    cases += [('ProcessScopeProbeKt', case) for case in [
        'alias-captured', 'other-root-isolated', 'exited-retry', 'foreign-uid-retired',
    ]]
    cases += [('ProcessCaptureProbeKt', case) for case in [
        'guest-capture-retry', 'empty-cell-recapture', 'capture-serialized-with-reap',
    ]]
    cases += [('ProotTempCleanupProbeKt', case) for case in [
        'stale', 'other-runtime', 'observation-gap', 'pid-denied',
        'store-symlink', 'candidate-symlink',
    ]]
    for probe, case in cases:
        command = ['java', '-cp', str(jar), 'io.github.ccch1mneyyy.dsh_app.runtime.' + probe,
                   str(owned), case]
        start = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(command, env={'PATH': '/usr/bin:/bin', 'HOME': str(owned)}, cwd=owned,
                                text=True, capture_output=True, timeout=40, **identity)
        (out / (case + '.stdout.log')).write_text(result.stdout)
        (out / (case + '.stderr.log')).write_text(result.stderr)
        record = {'case': case, 'argv': command, 'uid': uid, 'gid': gid, 'identity': identity,
                  'started_utc': start, 'finished_utc': datetime.now(timezone.utc).isoformat(), 'exit': result.returncode}
        records.append(record)
        (out / 'commands.json').write_text(json.dumps(records, indent=2) + '\n')
        print(json.dumps({'case': case, 'exit': result.returncode}), flush=True)
        if result.returncode != 0:
            print(result.stdout, flush=True)
            print(result.stderr, flush=True)
    summary = {'scope': 'production start/cleanup; actual non-root JVM; injected Android API faults; launcher records argv, not a complete PRoot engine',
               'passed': sum(r['exit'] == 0 for r in records), 'failed': sum(r['exit'] != 0 for r in records)}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    raise SystemExit(0 if summary['failed'] == 0 else 1)
finally:
    shutil.rmtree(base)
