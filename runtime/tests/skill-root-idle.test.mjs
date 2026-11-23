import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const prefix = resolve(process.env.DSH_PREFIX);
const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { SkillRegistry } = await load('dsh-skill');
const filesystem = await load('dsh-skill-filesystem');

// Windows reports these names with a \\?\ prefix.
const polls = directory => process.report.getReport().libuv
  .filter(handle => handle.type === 'fs_poll' && handle.is_active && handle.filename?.includes(directory + sep))
  .map(handle => handle.filename.slice(handle.filename.indexOf(directory)));

// A missing root waits on its parent's events; only a link already standing in its
// place keeps the 100 ms stat poll, since retargeting it raises no event there.
test('missing skill roots wait on events, except behind a dangling link', async t => {
  const directory = await fs.realpath(await fs.mkdtemp(join(tmpdir(), 'dsh-skill-root-idle-')));
  const plain = join(directory, 'plain', '.agents', 'skills');
  const linked = join(directory, 'linked', '.agents', 'skills');
  await fs.mkdir(join(directory, 'plain'));
  await fs.mkdir(join(directory, 'linked'));
  await fs.symlink(join(directory, 'target'), join(directory, 'linked', '.agents'));
  const ctx = new Context();
  await ctx.plugin(SkillRegistry);
  await ctx.plugin(filesystem, {
    includeDefaultRoots: false, customSkillDirs: [plain, linked],
    dshHome: join(directory, 'home'), agentsHome: join(directory, 'agents'),
  }).await();
  t.after(async () => {
    await ctx.fiber.dispose();
    await fs.rm(directory, { recursive: true, force: true });
  });
  assert.deepEqual((await ctx.skills.snapshot()).skills, []);
  assert.deepEqual(polls(directory), [join(directory, 'linked', '.agents')]);

  await fs.mkdir(join(directory, 'target', 'skills'), { recursive: true });
  await fs.writeFile(join(directory, 'target', 'skills', 'example.md'), '---\nname: example\ndescription: linked\n---\nbody\n');
  const deadline = performance.now() + 5000;
  while (!(await ctx.skills.snapshot()).skills.some(skill => skill.name === 'example')) {
    assert(performance.now() < deadline, 'the link target is discovered');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
});
