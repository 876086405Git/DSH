import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { createFilesystem } from '../../ohos/process/filesystem.mjs';

const parent = process.env.DSH_O4B_PARENT_ROOT
  ? pathToFileURL(resolve(process.env.DSH_O4B_PARENT_ROOT) + '/') : new URL('../../ohos/', import.meta.url);
const client = process.env.DSH_O4B_GIT_ROOT
  ? pathToFileURL(resolve(process.env.DSH_O4B_GIT_ROOT) + '/') : new URL('../../ohos/process/', import.meta.url);
export const { createOwnedGitResources } = await import(new URL('process/owned-resources.mjs', parent));
export const { openOwnershipLedger } = await import(new URL('publication/ledger.mjs', parent));
export const { executeGit } = await import(new URL('git.mjs', client));
export const { createGitFs } = await import(new URL('git-fs.mjs', client));
const binding = process._linkedBinding('dsh_ohos_publication');
const native = { lockExclusive: binding.lockExclusive, setOwnershipMarker: binding.setOwnershipMarker,
  getOwnershipMarker: binding.getOwnershipMarker };
assert(Object.values(native).every(value => typeof value === 'function'));
if (process.env.DSH_O4B_EXPECT_STRICT === '1') {
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert.equal(globalThis[Symbol.for('dsh.go.ohos.sim')], true);
  assert(process.execArgv.includes('--jitless'));
}
export const fixedEnv = { GIT_AUTHOR_NAME: '测试作者', GIT_AUTHOR_EMAIL: 'test@example.invalid',
  GIT_COMMITTER_NAME: '测试作者', GIT_COMMITTER_EMAIL: 'test@example.invalid',
  GIT_AUTHOR_DATE: '1700000000 +0000', GIT_COMMITTER_DATE: '1700000000 +0000' };
export const hasCode = (error, code) => !!error && (error.code === code || hasCode(error.cause, code)
  || error.errors?.some(value => hasCode(value, code)));
export async function fixture(t, { inside = false, onStage, ownerFs, ownership } = {}) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-owned-git-'));
  const dir = join(root, 'repo'), scratch = inside ? join(dir, '.private-snapshot') : join(root, 'private');
  const directory = join(root, 'ownership');
  await fs.mkdir(dir); await fs.mkdir(scratch, { recursive: true });
  const roots = inside ? [dir] : [dir, scratch];
  const ledger = await openOwnershipLedger({ directory, ownerId: randomUUID(), ...native });
  const sessions = [], expectedFailures = new Map(), calls = [], trace = [];
  const mount = createFilesystem(roots); mount.seal();
  const trackedFs = new Proxy(mount.fs, { get(target, key) {
    const value = target[key];
    if (typeof value !== 'function') return value;
    return (...args) => { trace.push({ operation: String(key), path: typeof args[0] === 'string' ? args[0] : undefined }); return value.apply(target, args); };
  } });
  const makeOwner = (overrides = {}) => {
    const session = createOwnedGitResources({ roots, getOwnership: () => ownership?.(ledger) ?? ledger,
      onStage, ...(ownerFs ? { fs: ownerFs } : {}), ...overrides });
    sessions.push(session); return session;
  };
  const owner = makeOwner();
  // A separate forwarding object preserves the frozen owner's Proxy invariants.
  const facade = Object.fromEntries(['createIndex', 'writeIndex', 'writeMetadata', 'commitIndex', 'releaseIndex', 'createClone', 'commitClone', 'releaseClone']
    .map(key => [key, (...args) => {
      calls.push({ operation: key, target: args[0]?.target, id: typeof args[0] === 'string' ? args[0] : undefined });
      return owner[key](...args);
    }]));
  const ctx = { fs: trackedFs, cwd: dir, env: fixedEnv, stdin: '', ownedGit: facade };
  const f = { root, dir, scratch, directory, roots, ledger, owner, ctx, calls, trace, makeOwner,
    expectFinishFailure(session, code) { expectedFailures.set(session, code); },
    async records() { return JSON.parse(await fs.readFile(join(directory, 'ledger.json'), 'utf8')).entries; },
    async run(args, extras = {}) {
      const result = await executeGit(args, { ...ctx, ...extras });
      assert.equal(result.exitCode, 0, `${args.join(' ')}: ${result.stderr}`);
      return result;
    },
  };
  t.after(async () => {
    const unexpected = [];
    for (const session of sessions) {
      try { await session.finish(); assert(!expectedFailures.has(session), 'expected resource finish failure'); }
      catch (error) { if (!expectedFailures.has(session) || !hasCode(error, expectedFailures.get(session))) unexpected.push(error); }
    }
    try { await ledger.close(); } finally { await fs.rm(root, { recursive: true, force: true }); }
    if (unexpected.length) throw new AggregateError(unexpected, 'Git fixture resource finish failed');
  });
  return f;
}
