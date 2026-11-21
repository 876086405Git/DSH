// SOURCE_IO: intact pinned provider bodies, real Node IO, supplied framework services only.
// No Cordis engine, real approvals, network mount or power-loss execution is claimed.
import assert from 'node:assert/strict';
import { readFile, mkdir, mkdtemp, rm, statfs } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { join } from 'node:path';

class Service { constructor(ctx) { this.ctx = ctx; } }
class HarnessError extends Error {
  constructor(message, code, options) { super(message, options); this.code = code; }
}
export const notesSourceRoot = () => process.env.DSH_FS_NOTES_SOURCE
  ?? (process.env.DSH_PREFIX ? join(process.env.DSH_PREFIX, 'node_modules', '@deepseek-ai') : null);
async function sourceModule(root, name, modules, expected) {
  const path = join(root, name, 'lib/index.js');
  const source = await readFile(path, 'utf8');
  assert.equal(createHash('sha256').update(source).digest('hex'), expected[name], 'source identity: ' + name);
  const key = 'notes-source-' + randomUUID();
  globalThis[Symbol.for(key)] = modules;
  let replaced = 0;
  const body = source.replace(/^import (.+) from ["']([^"']+)["'];$/gm, (whole, spec, name) => {
    if (name.startsWith('node:')) return whole;
    assert(Object.hasOwn(modules, name), 'unexpected framework dependency: ' + name);
    replaced++;
    return 'const ' + (spec.startsWith('{') ? spec : '{ default: ' + spec + ' }')
      + ' = globalThis[Symbol.for(' + JSON.stringify(key) + ')][' + JSON.stringify(name) + '];';
  });
  assert.equal(replaced, Object.keys(modules).length);
  try { return await import('data:text/javascript;base64,' + Buffer.from(body).toString('base64')); }
  finally { delete globalThis[Symbol.for(key)]; }
}
export async function notesProviders(root) {
  const binding = JSON.parse(await readFile(new URL('./companion-notes-files-source-pins.json', import.meta.url)));
  const actual = {};
  for (const name of Object.keys(binding.targets.android)) {
    actual[name] = createHash('sha256').update(await readFile(join(root, name, 'lib/index.js'))).digest('hex');
  }
  const selected = Object.values(binding.targets).find(expected =>
    Object.entries(expected).every(([name, hash]) => actual[name] === hash));
  assert(selected, 'requires one complete, exact Android or OHOS provider source variant');
  const load = (name, modules) => sourceModule(root, name, modules, selected);
  const common = { '@deepseek-ai/cordis': { Service }, '@deepseek-ai/dsh-llm': { HarnessError } };
  const vocabulary = await load('dsh-fs', common);
  const sandbox = await load('dsh-sandbox', { ...common,
    '@deepseek-ai/dsh-util-values': { assertNever() { assert.fail('unexpected policy mode'); } } });
  const schema = { default() { return this; } };
  const { LocalFileSystem } = await load('dsh-fs-local', {
    '@deepseek-ai/dsh-fs-patch': { applyHunks() { assert.fail('notes never use arbitrary patch edits'); } },
    'chokidar': { watch() { assert.fail('notes never start a watcher'); } },
    '@deepseek-ai/schemastery': { default: { object: () => schema, string: () => schema, number: () => schema } },
    '@deepseek-ai/dsh-fs': vocabulary,
  });
  const { SandboxedFileSystem } = await load('dsh-fs-sandbox', {
    '@deepseek-ai/dsh-fs-local': { LocalFileSystem }, '@deepseek-ai/dsh-fs': vocabulary,
    '@deepseek-ai/dsh-sandbox': sandbox,
  });
  return { LocalFileSystem, SandboxedFileSystem };
}
export async function notesFixture(t, { sandboxed = false, injectLocalType = true } = {}) {
  const source = notesSourceRoot();
  assert(source);
  // Outside /tmp: the real workspace policy deliberately grants /tmp globally.
  const root = await mkdtemp(join(process.cwd(), 'notes-source-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'notes'));
  const providers = await notesProviders(source);
  const ctx = { sandboxPolicy: { defaultMode: 'workspace-write', resolve: () => ({ mode: 'workspace-write', workspaceRoot: join(root, 'notes') }) } };
  const fs = new (sandboxed ? providers.SandboxedFileSystem : providers.LocalFileSystem)(ctx,
    { cwd: root, diffBasisMaxBytes: 10 * 1024 * 1024 });
  const actualFilesystemType = (await statfs(root, { bigint: true })).type.toString(16);
  // This sandbox is overlayfs, which production correctly rejects. Only the capability probe is
  // injected; all stat/open/read/write/link/fsync/rename/process-death effects remain real.
  if (injectLocalType) fs.internals.companionStatfs = async () => ({ type: 0xef53n });
  const target = await fs.resolve(join(root, 'notes'));
  const directory = await fs.dshGoBindNotesDirectory(target);
  return { root, fs, target, directory, providers, actualFilesystemType };
}
