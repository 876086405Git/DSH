// Test-only plugin for the unchanged O0b HTTP/WS five-tool script.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';

const git = createRequire(new URL('../../ohos/process/package.json', import.meta.url))('isomorphic-git');
export const inject = ['workspaceChanges', 'connection', 'webServer'];

function gitState(directory) {
  const files = {};
  function walk(path, relative = '') {
    for (const entry of fs.readdirSync(path, { withFileTypes: true })) {
      const name = relative ? `${relative}/${entry.name}` : entry.name;
      const target = join(path, entry.name);
      if (entry.isDirectory()) walk(target, name);
      else {
        assert(entry.isFile(), 'fixture git metadata must contain regular files');
        files[name] = createHash('sha256').update(fs.readFileSync(target)).digest('hex');
      }
    }
  }
  walk(directory);
  return files;
}

export async function apply(ctx, config) {
  assert.equal(config?.confirmEmptyTestWorkspace, true, 'test fixture requires explicit opt-in');
  const directory = process.cwd();
  assert.deepEqual(fs.readdirSync(directory), [], 'fixture only initializes a new empty O0 workspace');
  const output = resolve(config.output);
  assert(!output.startsWith(directory + '/'), 'fixture report must be outside the Git work tree');
  const externalFile = '仅快照可见.txt';
  fs.writeFileSync(join(directory, externalFile), 'before\n', { flag: 'wx' });
  fs.writeFileSync(join(directory, '未改动.txt'), 'unchanged\n', { flag: 'wx' });
  fs.writeFileSync(join(directory, '.gitignore'), 'ignored.txt\nignored-nested/\n', { flag: 'wx' });
  fs.writeFileSync(join(directory, 'ignored.txt'), 'ignored-before\n', { flag: 'wx' });
  await git.init({ fs, dir: directory, defaultBranch: 'main' });
  for (const filepath of [externalFile, '未改动.txt', '.gitignore']) await git.add({ fs, dir: directory, filepath });
  await git.commit({ fs, dir: directory, message: 'O0 workspace snapshot fixture', author: { name: 'OHOS fixture', email: 'fixture@example.invalid', timestamp: 1, timezoneOffset: 0 } });
  const metadataBefore = gitState(join(directory, '.git'));
  // Prepare outside the worktree, then move in synchronously after baseline.
  // A broken ignored-gitlink branch now changes the snapshot and is observable
  // through the production summary, rather than existing unchanged in both trees.
  const stagedNested = fs.mkdtempSync(join(dirname(directory), 'fixture-nested-'));
  await git.init({ fs, dir: stagedNested, defaultBranch: 'main' });
  fs.writeFileSync(join(stagedNested, 'nested.txt'), 'nested repository content\n', { flag: 'wx' });
  await git.add({ fs, dir: stagedNested, filepath: 'nested.txt' });
  await git.commit({ fs, dir: stagedNested, message: 'ignored nested fixture', author: { name: 'OHOS fixture', email: 'fixture@example.invalid', timestamp: 2, timezoneOffset: 0 } });
  const nestedMetadataBefore = gitState(join(stagedNested, '.git'));
  let changed = false;
  const announced = new Map();
  ctx.on('session/event', (session, event) => {
    if (event.type === 'workspace/changes') announced.set(session.id, event.seq);
    if (event.type === 'tool/result' && !changed) {
      // An outside writer is not observed by fs/write-intent. Only a real
      // repository snapshot can report this change; file-tool fallback cannot.
      fs.writeFileSync(join(directory, externalFile), 'after\n');
      fs.writeFileSync(join(directory, 'ignored.txt'), 'ignored-after\n');
      fs.renameSync(stagedNested, join(directory, 'ignored-nested'));
      changed = true;
    }
  });

  // workspaceChanges is injected, so its own serial stopping listener was
  // installed before ours. Its snapshot and records exist before this runs.
  ctx.on('agent/turn-stopping', async ({ agent, turn, signal }) => {
    const record = { status: 'BLOCKED', turn, externalMutationObserved: changed };
    try {
      const seq = announced.get(agent.session.id);
      const summary = ctx.workspaceChanges.summary(agent.session.id, seq);
      assert(summary, 'production workspace summary must exist');
      record.summary = summary;
      assert.match(summary.snapshot?.before ?? '', /^[0-9a-f]{40}$/u, 'repository baseline snapshot is required');
      assert.match(summary.snapshot?.after ?? '', /^[0-9a-f]{40}$/u, 'repository end snapshot is required');
      assert.notEqual(summary.snapshot.before, summary.snapshot.after);
      const index = summary.files.findIndex(file => file.path === externalFile);
      assert(index >= 0, 'snapshot must include a mutation outside DSH file tools');
      assert(summary.files.some(file => file.path === '中文 测试.txt'));
      assert(!summary.files.some(file => file.path === 'ignored.txt' || file.path === '未改动.txt'));
      assert(!summary.files.some(file => file.path === 'ignored-nested' || file.path.startsWith('ignored-nested/')),
        'an ignored nested repository arriving after baseline must not enter the snapshot');
      record.ignoredNestedArrivedAfterBaseline = changed;
      const comparison = await ctx.workspaceChanges.diff(agent.session.id, seq, index, signal);
      assert.equal(comparison.kind, 'text');
      assert.equal(comparison.before, true); assert.equal(comparison.after, true);
      const lines = comparison.hunks.flatMap(hunk => hunk.lines);
      assert(lines.includes('-before')); assert(lines.includes('+after'));
      record.comparison = comparison;
      assert.deepEqual(gitState(join(directory, '.git')), metadataBefore, 'snapshot must not change user index, objects or refs');
      assert.deepEqual(gitState(join(directory, 'ignored-nested/.git')), nestedMetadataBefore, 'snapshot must not change nested repository metadata');
      record.repositoryMetadataUnchanged = true;

      // Read the same authenticated HTTP endpoints as the existing client.
      const origin = ctx.webServer.getOrigin();
      const login = await fetch(ctx.connection.authenticatedUrl(origin), { redirect: 'manual', signal });
      assert.equal(login.status, 303);
      const cookie = login.headers.getSetCookie().find(value => value.startsWith('dsh-auth-')).split(';')[0];
      const query = new URLSearchParams({ sessionId: agent.session.id, seq: String(seq) });
      const response = await fetch(`${origin}/api/changes.summary?${query}`, { headers: { cookie }, signal });
      assert.equal(response.status, 200);
      const visible = await response.json();
      assert.deepEqual(visible.files, summary.files);
      query.set('index', String(index));
      const diffResponse = await fetch(`${origin}/api/changes.diff?${query}`, { headers: { cookie }, signal });
      assert.equal(diffResponse.status, 200);
      assert.deepEqual(await diffResponse.json(), comparison);
      record.clientSummary = visible;
      record.status = 'PASS';
    } catch (error) {
      record.error = error.message;
      throw error;
    } finally {
      fs.writeFileSync(output, JSON.stringify(record, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    }
  });
}
