#!/usr/bin/env python3
"""Real tar I/O with filesystem or explicit TarInfo owner input; no image/VM build."""
import argparse
import ast
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[3]
OPTIONS = None
REPORT = {}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def identity(path):
    data = path.read_bytes()
    return dict(path=str(path), sha256=digest(data), size=len(data),
                mode=f'{stat.S_IMODE(path.stat().st_mode):04o}')


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def builder_nodes(source):
    """Execute the unchanged production archive nodes, not the CLI/image code."""
    tree = ast.parse(source)
    matches = [i for i, node in enumerate(tree.body) if isinstance(node, ast.With)
               and any(isinstance(item.context_expr, ast.Call)
                       and isinstance(item.context_expr.func, ast.Attribute)
                       and isinstance(item.context_expr.func.value, ast.Name)
                       and item.context_expr.func.value.id == 'tarfile'
                       and item.context_expr.func.attr == 'open'
                       and any(isinstance(value, ast.Constant) and value.value == 'tools.block'
                               for value in ast.walk(item.context_expr))
                       for item in node.items)]
    if len(matches) != 1:
        raise ValueError('Expected one production tools.block tar writer')
    index = matches[0]
    padding = tree.body[index + 1]
    if not isinstance(padding, ast.With) or not any(
            isinstance(value, ast.Constant) and value.value == 'r+b' for value in ast.walk(padding)):
        raise ValueError('Expected the production sector-padding block immediately after tar writer')
    helpers = [node for node in tree.body[:index]
               if isinstance(node, ast.FunctionDef) and node.name == 'rooted']
    nodes = helpers + [tree.body[index], padding]
    lines = source.splitlines(keepends=True)
    spans = [dict(startLine=node.lineno, endLine=node.end_lineno,
                  sha256=digest(''.join(lines[node.lineno - 1:node.end_lineno]).encode()))
             for node in nodes]
    return ast.Module(body=nodes, type_ignores=[]), spans


def child():
    request = json.load(sys.stdin)
    before_uid, before_gid = os.geteuid(), os.getegid()
    ownership_mode = request['ownershipMode']
    if ownership_mode == 'filesystem' and before_uid == 0:
        raise RuntimeError('Filesystem ownership case requires an actual non-root writer')
    directory = Path(request['directory'])
    tree, image = directory / 'fixture', directory / 'image'
    tree.mkdir(); image.mkdir()
    tools = tree / 'tools'
    for name in ['usr/bin', 'usr/share', 'workspace']:
        (tools / name).mkdir(parents=True, exist_ok=True)
    content = {
        'usr/bin/fixture-tool': (b'#!/bin/sh\nprintf fixture\\n\n', 0o755),
        'usr/share/fixture-data': ('ordinary tar fixture 中文\n'.encode(), 0o640),
        'workspace/marker': (b'OWNED-SMALL-ARCHIVE\n', 0o600),
    }
    for name, (data, mode) in content.items():
        path = tools / name; path.write_bytes(data); path.chmod(mode)
    (tools / 'usr/bin/tool-link').symlink_to('fixture-tool')
    agent = tree / 'agent.py'
    agent.write_bytes(base64.b64decode(request['agent'])); agent.chmod(0o644)
    init = tree / 'runtime/ohos/linux/guest/agent-init.sh'
    init.parent.mkdir(parents=True)
    init.write_bytes(base64.b64decode(request['init'])); init.chmod(0o644)
    expected = {}
    inputs = []
    for path in sorted(tools.rglob('*')):
        info = path.lstat(); name = path.relative_to(tools).as_posix()
        entry = {'kind': 'symlink' if path.is_symlink() else 'directory' if path.is_dir() else 'file',
                 'mode': stat.S_IMODE(info.st_mode)}
        if entry['kind'] == 'file': entry['sha256'] = digest(path.read_bytes())
        if entry['kind'] == 'symlink': entry['linkname'] = os.readlink(path)
        expected[name] = entry
        inputs.append(dict(name=name, uid=info.st_uid, gid=info.st_gid, **entry))
    for path, name, target_mode in [(agent, 'usr/local/lib/dsh/guest-agent.py', 0o644),
                                    (init, 'sbin/dsh-init', 0o755)]:
        info = path.stat()
        expected[name] = dict(kind='file', mode=target_mode, sha256=digest(path.read_bytes()))
        inputs.append(dict(name=name, uid=info.st_uid, gid=info.st_gid,
                           sourceMode=stat.S_IMODE(info.st_mode), sha256=digest(path.read_bytes())))
    module, spans = builder_nodes(request['builderSource'])
    namespace = {'tarfile': tarfile, 'image': image, 'ROOT': tree,
                 'a': SimpleNamespace(tools_root=tools, agent=agent)}
    metadata_inputs = []
    original_gettarinfo = tarfile.TarFile.gettarinfo
    def fixture_gettarinfo(self, *args, **kwargs):
        info = original_gettarinfo(self, *args, **kwargs)
        if info is not None:
            # Only the owner metadata input is controlled. Production filtering,
            # add/addfile, gzip serialization and the archive readback are real.
            info.uid, info.gid = 18001, 28001
            info.uname, info.gname = 'fixture-builder', 'fixture-builders'
            metadata_inputs.append(dict(name=info.name, uid=info.uid, gid=info.gid,
                                        uname=info.uname, gname=info.gname))
        return info
    if ownership_mode == 'tarinfo-fixture':
        tarfile.TarFile.gettarinfo = fixture_gettarinfo
    try:
        exec(compile(module, request['builderPath'], 'exec'), namespace)
    finally:
        tarfile.TarFile.gettarinfo = original_gettarinfo
    archive = image / 'tools.block'
    actual = {}
    headers = []
    with tarfile.open(archive, 'r:gz') as stream:
        for member in stream:
            if member.name in actual:
                raise AssertionError('Duplicate archive member in this fixed fixture')
            kind = 'file' if member.isfile() else 'directory' if member.isdir() else 'symlink' if member.issym() else 'other'
            entry = dict(kind=kind, mode=member.mode)
            if kind == 'file': entry['sha256'] = digest(stream.extractfile(member).read())
            if kind == 'symlink': entry['linkname'] = member.linkname
            actual[member.name] = entry
            headers.append(dict(name=member.name, uid=member.uid, gid=member.gid,
                                uname=member.uname, gname=member.gname, **entry))
    print(json.dumps({'scope': 'Production AST tar/padding nodes and actual archive I/O; owner-input mode is explicit. No mke2fs, image assembly or VM.',
                      'ownershipMode': ownership_mode, 'metadataInputsBeforeProductionFilter': metadata_inputs,
                      'beforeEuid': before_uid, 'beforeEgid': before_gid,
                      'euid': os.geteuid(), 'egid': os.getegid(), 'inputOwners': inputs,
                      'selectedProductionNodes': spans, 'builderSha256': digest(request['builderSource'].encode()),
                      'expectedShape': expected, 'actualShape': actual, 'members': headers,
                      'archive': identity(archive)}, ensure_ascii=False))


class ToolsOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = OPTIONS.source.resolve()
        builder = (OPTIONS.builder or source / 'tooling/ohos/build-linux-assets.py').resolve()
        inputs = [builder, source / 'runtime/ohos/linux/guest-agent.py',
                  source / 'runtime/ohos/linux/guest/agent-init.sh', Path(__file__).resolve()]
        REPORT['inputs'] = [identity(path) for path in inputs]
        save(OPTIONS.output / 'INPUTS.json', REPORT['inputs'])
        directory = OPTIONS.output / 'writer'
        directory.mkdir(mode=0o700)
        ownership_mode = 'tarinfo-fixture' if OPTIONS.metadata_fixture or os.geteuid() == 0 else 'filesystem'
        request = dict(ownershipMode=ownership_mode, directory=str(directory), builderPath=str(builder),
                       builderSource=builder.read_text(),
                       agent=base64.b64encode(inputs[1].read_bytes()).decode(),
                       init=base64.b64encode(inputs[2].read_bytes()).decode())
        argv = [sys.executable, '-I', '-B', str(Path(__file__).resolve()), '--child']
        environment = {'PATH': os.defpath, 'LANG': 'C.UTF-8', 'TMPDIR': str(directory)}
        save(OPTIONS.output / 'COMMAND.json', dict(argv=argv, cwd=str(directory),
                                                 environment=environment,
                                                 scope='Fixed environment; stdin contains only selected source and synthetic fixture bytes.'))
        completed = subprocess.run(argv, input=json.dumps(request).encode(), cwd=directory,
                                   env=environment, capture_output=True, timeout=20)
        (OPTIONS.output / 'child.stdout').write_bytes(completed.stdout)
        (OPTIONS.output / 'child.stderr').write_bytes(completed.stderr)
        REPORT['childExitCode'] = completed.returncode
        if completed.returncode:
            raise RuntimeError('Archive fixture setup/writer failed; see child.stderr, not a product behavior PASS')
        cls.observed = json.loads(completed.stdout)
        REPORT['observation'] = cls.observed
        REPORT['inputsAfter'] = [identity(path) for path in inputs]
        if REPORT['inputs'] != REPORT['inputsAfter']:
            raise AssertionError('Read-only production/test input changed')
        save(OPTIONS.output / 'OBSERVED.json', cls.observed)

    def test_every_archive_member_is_owned_by_root(self):
        value = self.observed
        self.assertTrue(value['inputOwners'])
        self.assertTrue(all(row['uid'] == value['euid'] and row['gid'] == value['egid']
                            for row in value['inputOwners']))
        if value['ownershipMode'] == 'filesystem':
            self.assertNotEqual(value['euid'], 0, 'Do not mask the regression with root-owned input')
            self.assertEqual(value['metadataInputsBeforeProductionFilter'], [])
        else:
            self.assertEqual(value['ownershipMode'], 'tarinfo-fixture')
            metadata = value['metadataInputsBeforeProductionFilter']
            self.assertEqual({row['name'] for row in metadata}, set(value['expectedShape']))
            self.assertTrue(all((row['uid'], row['gid']) == (18001, 28001) for row in metadata))
        wrong = [row for row in value['members'] if (row['uid'], row['gid'], row['uname'], row['gname']) != (0, 0, 'root', 'root')]
        self.assertEqual(wrong, [], 'All recursive, agent and explicit init headers must be normalized')

    def test_member_contents_types_modes_links_and_sector_padding_are_preserved(self):
        value = self.observed
        self.assertEqual(value['actualShape'], value['expectedShape'])
        self.assertEqual(value['actualShape']['sbin/dsh-init']['mode'], 0o755)
        self.assertEqual(value['archive']['size'] % 512, 0)
        self.assertTrue(value['members'])


def main():
    global OPTIONS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--builder', type=Path)
    parser.add_argument('--metadata-fixture', action='store_true',
                        help='Explicit nonzero TarInfo owner input; also selected automatically when running as root.')
    parser.add_argument('--output', type=Path, required=True)
    OPTIONS = parser.parse_args()
    OPTIONS.output = OPTIONS.output.resolve()
    OPTIONS.output.mkdir(parents=True, exist_ok=False, mode=0o755)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ToolsOwnershipTests))
    REPORT.update(testsRun=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                  skipped=len(result.skipped), passed=result.wasSuccessful(),
                  scope='Actual tar I/O; inspect ownershipMode and euid for the input boundary. Not a six-asset, SDK or guest build.')
    save(OPTIONS.output / 'RESULT.json', REPORT)
    print(json.dumps({key: REPORT[key] for key in ['testsRun', 'failures', 'errors', 'skipped', 'passed']}))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    if sys.argv[1:] == ['--child']:
        child()
    else:
        raise SystemExit(main())
