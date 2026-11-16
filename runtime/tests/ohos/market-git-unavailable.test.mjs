// A plugin's detail files can come from a partial clone, which runs git through
// execa and so past the OH subprocess backend. The cache below is the installed
// class's own bytes with its real imports; git is a controlled program on PATH.
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync, mkdtempSync, chmodSync, rmSync } from 'node:fs';
import * as fsPromises from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { delimiter, join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const marker = Symbol.for('dsh.go.ohos.sim');
const prefix = resolve(process.env.OHOS_TEST_DSH_PREFIX);
const source = readFileSync(join(prefix, 'node_modules/@deepseek-ai/dsh-plugin-market/lib/index.js'), 'utf8');
const begin = source.indexOf('const STAGING_PREFIX = ');
const end = source.indexOf('\n//#endregion', source.indexOf('var RepositoryCache = class {'));
assert(begin > 0 && end > begin, 'the repository cache moved');
const require = createRequire(join(prefix, 'package.json'));
const load = name => import(pathToFileURL(require.resolve(name)).href);
const { execa } = await import(pathToFileURL(join(prefix, 'node_modules/execa/index.js')).href);
const { withFileLock } = await load('@deepseek-ai/dsh-atomic-write');
const { scrubbedParentEnv } = await load('@deepseek-ai/dsh-subprocess');
const { DetailFailure } = await load('@deepseek-ai/dsh-plugin-detail');
const { mkdir, mkdtemp, readdir, rename, rm, stat, utimes } = fsPromises;
const RepositoryCache = new Function(
  'execa', 'withFileLock', 'scrubbedParentEnv', 'DetailFailure', 'existsSync', 'join',
  'mkdir', 'mkdtemp', 'readdir', 'rename', 'rm', 'stat', 'utimes',
  `${source.slice(begin, end)}\nreturn RepositoryCache;`,
)(execa, withFileLock, scrubbedParentEnv, DetailFailure, existsSync, join,
  mkdir, mkdtemp, readdir, rename, rm, stat, utimes);

async function observe(ohos) {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-market-git-'));
  const calls = join(directory, 'calls.jsonl');
  const git = join(directory, 'git');
  writeFileSync(git, `#!${process.execPath}\nrequire('node:fs').appendFileSync(${JSON.stringify(calls)}, JSON.stringify(process.argv.slice(2)) + '\\n');\nprocess.exit(1);\n`);
  chmodSync(git, 0o755);
  const previousPath = process.env.PATH;
  const previousMarker = Object.getOwnPropertyDescriptor(globalThis, marker);
  process.env.PATH = directory + delimiter + previousPath;
  if (ohos) globalThis[marker] = true;
  else delete globalThis[marker];
  try {
    const cache = new RepositoryCache({
      dir: directory, maxRepositoryBytes: 1 << 20, maxCacheBytes: 1 << 20, timeoutMs: 5000, ttlMs: 1000,
      transports: ['https'], lifetime: new AbortController().signal, sizePollMs: 200,
    });
    const failure = await cache.commit(join(directory, 'repository.git'), 'https://git.example.test/owner/project.git',
      undefined, new AbortController().signal).then(() => undefined, error => error);
    return { failure, calls: existsSync(calls) ? readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse) : [] };
  } finally {
    process.env.PATH = previousPath;
    if (previousMarker) Object.defineProperty(globalThis, marker, previousMarker);
    else delete globalThis[marker];
    rmSync(directory, { recursive: true, force: true });
  }
}

test('off OH the repository cache still starts the real git', { timeout: 10000 }, async () => {
  const { failure, calls } = await observe(false);
  assert(failure instanceof DetailFailure);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].at(-1), '--version');
});

test('on OH it answers git-unavailable without starting a process', { timeout: 10000 }, async () => {
  const { failure, calls } = await observe(true);
  assert(failure instanceof DetailFailure);
  assert.equal(failure.reason, 'git-unavailable');
  assert.match(failure.message, /OpenHarmony.*git.*computer/i);
  assert.deepEqual(calls, []);
});
