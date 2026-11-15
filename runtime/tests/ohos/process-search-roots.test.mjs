import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import OhSubprocessRuntime from '../../ohos/process/index.mjs';

assert.ok(process.env.OHOS_TEST_PROCESS_PREFIX, 'Use an exact pinned DSH prefix');
const require = createRequire(join(resolve(process.env.OHOS_TEST_PROCESS_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const [{ Context }, { Session }, { SystemPrompt }, { SessionProjectionRegistry }, { LocalFileSystem }, { WorkingDirectoryService }, search] = await Promise.all([
  'cordis', 'dsh-session', 'dsh-system-prompt', 'dsh-session-projection', 'dsh-fs-local', 'dsh-working-directory', 'dsh-tool-fs-search',
].map(load));
let sequence = 0;

async function fixture(t) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-m4-4a-search-'));
  const [a, b, temp] = ['session-a', 'session-b', 'temporary'].map(name => join(root, name));
  await Promise.all([a, b, temp].map(path => fs.mkdir(path)));
  const sub = join(a, 'sub'); await fs.mkdir(sub);
  await fs.writeFile(join(a, 'root.txt'), 'needle in session A\n');
  await fs.writeFile(join(b, 'secret.txt'), 'needle in session B\n');
  const ctx = new Context();
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(SessionProjectionRegistry);
  await ctx.plugin(LocalFileSystem, { cwd: a });
  await ctx.plugin(WorkingDirectoryService, { defaultDirectory: a });
  await ctx.plugin(OhSubprocessRuntime, { workspaceRoots: [a, b], temporaryRoot: temp });
  t.after(async () => {
    try { await ctx.fiber.dispose(); }
    finally { await fs.rm(root, { recursive: true, force: true }); }
  });
  const agent = (workspace = a) => {
    const id = `m4-4a-search-${++sequence}`;
    const session = workspace === null ? Session.create(id) : Session.create(id, undefined, {
      version: 4, id, createdAt: Date.now(), isSeeded: false, cwd: workspace,
    });
    session.append('turn/start', { turn: 1 });
    return { id, session, ctx, inject() {} };
  };
  const run = (owner, args, tool = 'grep', context = ctx) => search.runRipgrep(context,
    { ...(owner === undefined ? {} : { agent: owner }), signal: new AbortController().signal }, tool,
    tool === 'grep' ? search.buildGrepCommand(args) : search.buildGlobCommand(args), 65536, 100, 4096);
  return { root, a, b, sub, ctx, agent, run };
}

test('real Session and WorkingDirectory preserve grep access to its session parent after cd', async t => {
  const f = await fixture(t), owner = f.agent();
  await f.ctx.workingDirectory.set(owner, f.sub);
  assert.equal(owner.session.header.cwd, f.a);
  assert.equal(f.ctx.workingDirectory.get(owner.session), f.sub);
  const result = await f.run(owner, { pattern: 'needle', path: '../root.txt' });
  assert.equal(result.workdir, f.sub);
  assert.deepEqual(search.parseGrepMatches(result.stdout), [{ path: '../root.txt', lineNumber: 1, line: 'needle in session A' }]);
  assert.equal(result.noMatches, false);
  assert.equal(f.ctx.subprocess.backend.prepared.size, 0);
});

test('real grep cannot read an explicitly named different host-authorized session root', async t => {
  const f = await fixture(t), owner = f.agent();
  await assert.rejects(f.run(owner, { pattern: 'needle', path: join(f.b, 'secret.txt') }), { code: 'SEARCH_FAILED' });
  assert.equal(await fs.readFile(join(f.b, 'secret.txt'), 'utf8'), 'needle in session B\n');
});

test('changing actual WorkingDirectory to another authorized root does not change session authority', async t => {
  const f = await fixture(t), owner = f.agent();
  await f.ctx.workingDirectory.set(owner, f.b);
  assert.equal(f.ctx.workingDirectory.get(owner.session), f.b);
  assert.equal(owner.session.header.cwd, f.a);
  await assert.rejects(f.run(owner, { pattern: 'needle', path: 'secret.txt' }), error => {
    assert.equal(error.code, 'SEARCH_FAILED');
    assert.equal(error.cause?.code, 'EACCES');
    return true;
  });
  assert.equal(f.ctx.subprocess.backend.live.size, 0);
});

test('real glob uses the same session-root ticket from a nested current directory', async t => {
  const f = await fixture(t), owner = f.agent();
  await f.ctx.workingDirectory.set(owner, f.sub);
  const result = await f.run(owner, { pattern: '*.txt', path: '..' }, 'glob');
  assert.equal(result.noMatches, false);
  assert.deepEqual(result.stdout.trim().split('\n'), ['../root.txt']);
});

test('a real Session with no original cwd fails explicitly rather than acquiring the current cwd as authority', async t => {
  const f = await fixture(t), owner = f.agent(null);
  assert.equal(owner.session.header.cwd, undefined);
  await assert.rejects(f.run(owner, { pattern: 'needle', path: 'root.txt' }), error => {
    assert.equal(error.code, 'SEARCH_FAILED');
    assert.equal(error.cause?.code, 'EACCES');
    return true;
  });
  assert.equal(f.ctx.subprocess.backend.live.size, 0);
});

test('OHOS search refuses a backend lacking prepare before calling its real spawn', async t => {
  const f = await fixture(t), owner = f.agent();
  let spawns = 0;
  const context = { workingDirectory: f.ctx.workingDirectory, subprocess: {
    spawn(spec) { spawns++; return f.ctx.subprocess.spawn(spec); },
  } };
  await assert.rejects(f.run(owner, { pattern: 'needle', path: 'root.txt' }, 'grep', context), error => {
    assert.equal(error.code, 'SEARCH_FAILED');
    assert.equal(error.cause?.code, 'ERR_OHOS_CONFINEMENT_UNAVAILABLE');
    return true;
  });
  assert.equal(spawns, 0);
});

test('agentless search uses the explicitly authorized current directory and cannot read another root', async t => {
  const f = await fixture(t), previous = process.cwd();
  process.chdir(f.a);
  try {
    const result = await f.run(undefined, { pattern: 'needle', path: 'root.txt' });
    assert.equal(search.parseGrepMatches(result.stdout)[0].line, 'needle in session A');
    await assert.rejects(f.run(undefined, { pattern: 'needle', path: join(f.b, 'secret.txt') }), { code: 'SEARCH_FAILED' });
  } finally { process.chdir(previous); }
});
