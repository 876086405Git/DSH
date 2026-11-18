#!/usr/bin/env python3
"""Only the real linux-control source-copy nodes; no native load or guest launch."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import shutil
import stat
import unittest

ROOT = Path(__file__).resolve().parents[3]
OPTIONS = None
REPORT = {'cases': []}


def identity(path):
    data = path.read_bytes()
    return dict(path=str(path), sha256=hashlib.sha256(data).hexdigest(), size=len(data),
                mode=f'{stat.S_IMODE(path.stat().st_mode):04o}')


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def staging_nodes(source):
    tree = ast.parse(source)
    starts = [i for i, node in enumerate(tree.body) if isinstance(node, ast.Assign)
              and any(isinstance(target, ast.Name) and target.id == 'source' for target in node.targets)
              and any(isinstance(value, ast.Constant) and value.value == 'source/runtime/ohos/linux'
                      for value in ast.walk(node))]
    if len(starts) != 1:
        raise ValueError('Expected the production Linux source staging boundary')
    index = starts[0]
    nodes = tree.body[index:index + 3]
    if len(nodes) != 3 or not isinstance(nodes[1], ast.Expr) or not isinstance(nodes[2], ast.For):
        raise ValueError('Expected source assignment, mkdir and production copy loop')
    if not any(isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
               and node.func.attr == 'copy2' for node in ast.walk(nodes[2])):
        raise ValueError('Expected the real copy2 loop, not an invented test algorithm')
    lines = source.splitlines(keepends=True)
    spans = [dict(startLine=node.lineno, endLine=node.end_lineno,
                  sha256=hashlib.sha256(''.join(lines[node.lineno - 1:node.end_lineno]).encode()).hexdigest())
             for node in nodes]
    return ast.Module(body=nodes, type_ignores=[]), spans


class ControlStagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = OPTIONS.source.resolve()
        cls.driver = (OPTIONS.driver or cls.root / 'tooling/ohos/research/linux-control/run.py').resolve()
        cls.modules = sorted((cls.root / 'runtime/ohos/linux').glob('*.mjs'))
        if not cls.modules or not all(path.is_file() for path in cls.modules):
            raise ValueError('Expected the current real source modules')
        cls.inputs = [cls.driver, Path(__file__).resolve(), *cls.modules]
        REPORT['inputs'] = [identity(path) for path in cls.inputs]
        save(OPTIONS.output / 'INPUTS.json', REPORT['inputs'])
        cls.code, REPORT['selectedProductionNodes'] = staging_nodes(cls.driver.read_text())

    def exercise(self, name, extra_module=False):
        base = OPTIONS.output / name
        fixture = base / 'fixture/runtime/ohos/linux'
        fixture.mkdir(parents=True)
        for original in self.modules:
            shutil.copy2(original, fixture / original.name)
        if extra_module:
            extra = fixture / 'future-ordinary-module.mjs'
            extra.write_text('export const fixtureVersion = 1;\n'); extra.chmod(0o755)
        # The contract is top-level *.mjs only, not the whole directory tree.
        (fixture / 'ordinary-note.txt').write_text('not a module\n')
        (fixture / 'nested').mkdir()
        (fixture / 'nested/not-top-level.mjs').write_text('export const nested = true;\n')
        output = base / 'staging'
        namespace = {'ROOT': base / 'fixture', 'output': output, 'shutil': shutil}
        exec(compile(self.code, str(self.driver), 'exec'), namespace)
        staged = output / 'source/runtime/ohos/linux'
        expected = {path.name: identity(path) for path in sorted(fixture.glob('*.mjs'))}
        actual = {path.name: identity(path) for path in sorted(staged.iterdir()) if path.is_file()}
        observation = {'name': name, 'extraOrdinaryModule': extra_module,
                       'sourceFiles': expected, 'stagedFiles': actual,
                       'unexpectedEntries': sorted(path.name for path in staged.iterdir() if not path.is_file()),
                       'missing': sorted(set(expected) - set(actual)),
                       'extra': sorted(set(actual) - set(expected)),
                       'scope': 'Real production AST copy nodes and file I/O; no source imports, assets, native library, VM or HTTP.'}
        REPORT['cases'].append(observation)
        save(base / 'OBSERVED.json', observation)
        self.assertEqual(set(actual), set(expected))
        self.assertEqual(observation['unexpectedEntries'], [])
        for leaf in expected:
            for key in ['sha256', 'size', 'mode']:
                self.assertEqual(actual[leaf][key], expected[leaf][key], (leaf, key))
        self.assertIn('job-diagnostics.mjs', actual)
        self.assertIn('proxy.mjs', actual)

    def test_current_production_module_set_is_complete(self):
        self.exercise('current-source')

    def test_additional_top_level_module_is_staged_without_copying_other_entries(self):
        self.exercise('additional-module', extra_module=True)

    @classmethod
    def tearDownClass(cls):
        REPORT['inputsAfter'] = [identity(path) for path in cls.inputs]
        if REPORT['inputs'] != REPORT['inputsAfter']:
            raise AssertionError('Read-only production/test input changed')


def main():
    global OPTIONS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--driver', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    OPTIONS = parser.parse_args()
    OPTIONS.output = OPTIONS.output.resolve()
    OPTIONS.output.mkdir(parents=True, exist_ok=False)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ControlStagingTests))
    REPORT.update(testsRun=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                  skipped=len(result.skipped), passed=result.wasSuccessful())
    save(OPTIONS.output / 'RESULT.json', REPORT)
    print(json.dumps({key: REPORT[key] for key in ['testsRun', 'failures', 'errors', 'skipped', 'passed']}))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
