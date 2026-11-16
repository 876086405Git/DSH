#!/usr/bin/env python3
"""The guest agent's per-job App directory mounts on the real Linux kernel.

The actual validate_start and mount_workspaces run in an unprivileged user and
mount namespace (unshare -Urm). The 9P base mounts are stood in for by bind
mounts of tmpfs directories, so the 9P mount itself is not exercised here; the
private job namespace, bind views at the host paths, read-only remount and the
detached base are.
"""
import argparse
import errno
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


def load(source):
    spec = importlib.util.spec_from_file_location('actual_guest_agent', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validation(agent):
    command = {'argv': ['true'], 'cwd': '/w', 'env': {}}
    good = {'tag': 'dsh1', 'source': 'a/b', 'target': '/data/work', 'readOnly': True}
    rows = [('absent', {}, []), ('valid', {'mounts': [good]}, [good])]
    bad = [dict(good, tag='dsh4'), dict(good, tag='x'), dict(good, source='../up'), dict(good, source='/abs'),
           dict(good, source='a//b'), dict(good, target='rel'), dict(good, target='/'), dict(good, target='/a/../b'),
           dict(good, readOnly=1), dict(good, extra=True), {k: v for k, v in good.items() if k != 'readOnly'}]
    rows += [('invalid-%d' % index, {'mounts': [item]}, None) for index, item in enumerate(bad)]
    rows += [('too-many', {'mounts': [good] * 5}, None), ('not-a-list', {'mounts': good}, None)]
    result = []
    for name, extra, expected in rows:
        try:
            observed = agent.validate_start({**command, **extra})['mounts']
        except ValueError:
            observed = None
        result.append({'case': name, 'pass': observed == expected})
    return result


def job(agent, mounts, report):
    """Stand-in for the job leader: mount, then look around as the job would."""
    agent.mount_workspaces(mounts)
    rw, ro = mounts[0]['target'], mounts[1]['target']
    Path(rw, 'written-by-job.txt').write_text('from the job view\n')
    try:
        Path(ro, 'denied.txt').write_text('x')
        read_only = 'writable'
    except OSError as error:
        read_only = errno.errorcode.get(error.errno)
    facts = {'rwSees': sorted(os.listdir(rw)), 'roSees': sorted(os.listdir(ro)), 'readOnlyWrite': read_only,
             'baseDetached': [not os.path.ismount(os.path.join(agent.EXPORTS, tag)) for tag in ('dsh0', 'dsh1')]}
    report.write_text(json.dumps(facts))


def child(source, root):
    agent = load(source)
    root = Path(root)
    exported = [root / 'export0', root / 'export1']
    # Each stand-in export is its own filesystem, as each 9P mount is in the guest.
    for path in exported:
        path.mkdir()
        agent.mount('tmpfs', str(path), 'tmpfs', 0)
    (exported[0] / 'session').mkdir()
    (exported[0] / 'session/host.txt').write_text('from the host\n')
    (exported[1] / 'temp.txt').write_text('temp\n')
    agent.EXPORTS = str(root / 'run-dsh-9p')
    for tag, path in zip(('dsh0', 'dsh1'), exported):
        base = Path(agent.EXPORTS, tag)
        base.mkdir(parents=True)
        agent.mount(str(path), str(base), None, agent.MS_BIND)
    mounts = [{'tag': 'dsh0', 'source': 'session', 'target': str(root / 'host/work'), 'readOnly': False},
              {'tag': 'dsh1', 'source': '', 'target': str(root / 'host/temp'), 'readOnly': True}]
    report = root / 'job.json'
    pid = os.fork()
    if pid == 0:
        try:
            job(agent, mounts, report)
            os._exit(0)
        except BaseException as error:
            report.write_text(json.dumps({'error': repr(error)}))
            os._exit(1)
    _, status = os.waitpid(pid, 0)
    facts = json.loads(report.read_text())
    facts.update(jobExit=os.waitstatus_to_exitcode(status),
                 parentStillHasBase=[os.path.ismount(os.path.join(agent.EXPORTS, tag)) for tag in ('dsh0', 'dsh1')],
                 parentSeesNoJobMounts=[not os.path.ismount(item['target']) for item in mounts],
                 hostSeesJobWrite=(exported[0] / 'session/written-by-job.txt').read_text(),
                 hostUnchangedByReadOnly=sorted(os.listdir(exported[1])))
    print(json.dumps(facts))


def main(args):
    args.output.mkdir(parents=True, exist_ok=False)
    agent = load(args.source)
    checks = validation(agent)
    root = args.output / 'namespace'
    root.mkdir()
    completed = subprocess.run(['unshare', '-Urm', sys.executable, '-I', '-B', str(Path(__file__).resolve()),
                                '--source', str(args.source), '--child', str(root)],
                               capture_output=True, timeout=60)
    (args.output / 'child.stderr').write_bytes(completed.stderr)
    facts = json.loads(completed.stdout) if completed.returncode == 0 else {'exit': completed.returncode}
    expected = {'rwSees': ['host.txt', 'written-by-job.txt'], 'roSees': ['temp.txt'], 'readOnlyWrite': 'EROFS',
                'baseDetached': [True, True], 'jobExit': 0, 'parentStillHasBase': [True, True],
                'parentSeesNoJobMounts': [True, True], 'hostSeesJobWrite': 'from the job view\n',
                'hostUnchangedByReadOnly': ['temp.txt']}
    checks += [{'case': 'namespace:' + key, 'pass': facts.get(key) == value, 'observed': facts.get(key)}
               for key, value in expected.items()]
    passed = all(row['pass'] for row in checks)
    (args.output / 'RESULT.json').write_text(json.dumps({'passed': passed, 'checks': checks, 'scope': __doc__}, indent=2) + '\n')
    print(json.dumps({'passed': passed, 'checks': len(checks), 'failed': [row['case'] for row in checks if not row['pass']]}))
    return 0 if passed else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--child')
    arguments = parser.parse_args()
    if arguments.child:
        child(arguments.source, arguments.child)
    else:
        if arguments.output is None:
            parser.error('--output is required')
        raise SystemExit(main(arguments))
