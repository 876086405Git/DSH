// 宿主测量专用：原生 rg 只作为对照，不进入 OHOS 后端。
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm, symlink, utimes } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

const root = await mkdtemp(join(tmpdir(), 'ohos-rg-diff-'));
const rg = process.env.OHOS_NATIVE_RG || 'rg';
const work = join(root, 'work'), temp = join(root, 'temp');
await Promise.all([work, temp].map(path => mkdir(path)));
for (const dir of ['.git', 'dir', 'ignored', 'norepo', '.hidden']) await mkdir(join(work, dir));
const files = {
  'plain.txt': 'ABC\nabc\n中文abc\n中文\n😀\nfoo foobar bar\n123\n',
  'zero.txt': '😀中abc\r\n\n中abc', 'fixed.txt': '^a.*b$\nA.B\na.b\n',
  'crlf.txt': 'abc\r\n中文abc\r\n', 'no-lf.txt': 'abc',
  'binary.txt': 'abc\0tail\n', 'dir/a.txt': 'abc\n', 'dir/b.js': 'abc\n',
  '.gitignore': 'ignored/\n*.skip\n!keep.skip\n', '.ignore': 'dot-ignore.txt\n',
  'ignored/deep.txt': 'abc\n', 'exclude.skip': 'abc\n', 'keep.skip': 'abc\n',
  'dot-ignore.txt': 'abc\n', '.secret.txt': 'abc\n', '.hidden/a.txt': 'abc\n',
  'norepo/.gitignore': 'ignored.txt\n', 'norepo/ignored.txt': 'abc\n',
};
let time = 300;
for (const [path, content] of Object.entries(files)) {
  await writeFile(join(work, path), content);
  await utimes(join(work, path), time, time++);
}
await symlink('plain.txt', join(work, 'linked.txt'));
await utimes(join(work, 'plain.txt'), 100, 100);
await utimes(join(work, 'crlf.txt'), 200, 200);
const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp });
const cases = [
  ['literal', '--json', '--regexp=abc'],
  ['case-sensitive', '--json', '--regexp=ABC', '--', 'plain.txt'],
  ['unicode-literal', '--json', '--regexp=中文', '--', 'plain.txt'],
  ['unicode-word', '--json', '--regexp=^\\w+$', '--', 'plain.txt'],
  ['unicode-property', '--json', '--regexp=\\p{Han}', '--', 'plain.txt'],
  ['lookahead-native-rejects', '--json', '--regexp=foo(?=bar)', '--', 'plain.txt'],
  ['backreference-native-rejects', '--json', '--regexp=(.)\\1', '--', 'plain.txt'],
  ['non-capture', '--json', '--regexp=(?:abc|ABC)', '--', 'plain.txt'],
  ['inline-flags', '--json', '--regexp=(?i)abc', '--', 'plain.txt'],
  ['anchored-crlf', '--json', '--regexp=abc$', '--', 'crlf.txt'],
  ['last-line-no-lf', '--json', '--regexp=abc', '--', 'no-lf.txt'],
  ['zero-start', '--json', '--regexp=^', '--', 'zero.txt'],
  ['zero-end', '--json', '--regexp=$', '--', 'zero.txt'],
  ['zero-empty', '--json', '--regexp=', '--', 'zero.txt'],
  ['zero-star', '--json', '--regexp=a*', '--', 'zero.txt'],
  ['zero-alternative', '--json', '--regexp=abc|', '--', 'zero.txt'],
  ['fixed-metacharacters', '--json', '-F', '--regexp=^a.*b$', '--', 'fixed.txt'],
  ['cli-ignore-case', '--json', '-i', '--regexp=a.b', '--', 'fixed.txt'],
  ['cli-case-last', '--json', '-i', '-s', '--regexp=a.b', '--', 'fixed.txt'],
  ['inline-case-off', '--json', '-i', '--regexp=(?-i)abc', '--', 'plain.txt'],
  ['binary-explicit', '--json', '--regexp=abc', '--', 'binary.txt'],
  ['normal-glob', '--json', '--regexp=abc', '--glob=*.txt'],
  ['path-glob', '--json', '--regexp=abc', '--glob=dir/*.txt'],
  ['nested-glob', '--json', '--regexp=abc', '--glob=**/*.txt'],
  ['brace-glob', '--json', '--regexp=abc', '--glob=*.{txt,js}'],
  ['include-negation-glob', '--json', '--regexp=abc', '--glob=!plain.txt'],
  ['invalid-regex', '--json', '--regexp=['],
  ['invalid-glob', '--json', '--regexp=abc', '--glob=['],
  ['symlink-explicit', '--json', '--regexp=abc', '--', 'linked.txt'],
  ['ignored-explicit', '--json', '--regexp=abc', '--', 'exclude.skip'],
  ['hidden-explicit', '--json', '--regexp=abc', '--', '.secret.txt'],
  ['negative-glob-explicit', '--json', '--regexp=abc', '--glob=!plain.txt', '--', 'plain.txt'],
  ['file-list', '--files', '--glob=*.txt', '--sort=modified', '--no-ignore', '--hidden', '--glob=!**/.git', '--glob=!**/.git/**'],
];
function normalize(stdout, args) {
  if (args.includes('--json')) return stdout.trim().split('\n').filter(Boolean).map(JSON.parse).filter(x => x.type === 'match').map(x => ({
    path: x.data.path, lines: x.data.lines, line_number: x.data.line_number, absolute_offset: x.data.absolute_offset, submatches: x.data.submatches,
  })).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  return stdout.trim().split('\n').filter(Boolean);
}
try {
  const matrix = [];
  for (const [name, ...args] of cases) {
    console.error(`[rg differential] ${name}`);
    const argv = ['--no-config', ...args];
    const native = spawnSync(rg, argv, { cwd: work, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    if (native.error) throw native.error;
    const handle = runtime.spawn({ argv: ['rg', ...argv], cwd: work, graceMs: 100, stdio: { stdin: 'ignore', stdout: { maxBytes: 1048576 }, stderr: { maxBytes: 1048576 } } });
    const timer = setTimeout(() => handle.terminate(), 30000);
    const result = await handle.done.finally(() => clearTimeout(timer));
    if (result.signal) throw new Error(`differential case did not finish: ${name}`);
    const stdout = handle.collected.stdout.readFrom(0).text, stderr = handle.collected.stderr.readFrom(0).text;
    const expected = { code: native.status, output: normalize(native.stdout, args) };
    const actual = { code: result.exitCode, output: normalize(stdout, args) };
    matrix.push({ name, equal: JSON.stringify(actual) === JSON.stringify(expected), expected, actual, nativeError: native.stderr || undefined, virtualError: stderr || undefined });
  }
  console.log(JSON.stringify({ nativePath: rg, nativeVersion: spawnSync(rg, ['--version'], { encoding: 'utf8' }).stdout.trim(), matrix }, null, 2));
} finally { await runtime.dispose(); await rm(root, { recursive: true, force: true }); }
