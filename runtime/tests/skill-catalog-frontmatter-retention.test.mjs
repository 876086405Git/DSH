import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;

test('技能目录解析独立的前言，加载时仍返回完整正文', { skip: !prefix && '缺少引擎前缀' }, async t => {
  const require = createRequire(join(resolve(prefix), 'package.json'));
  const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
  const { Context } = await load('cordis');
  const { SkillRegistry } = await load('dsh-skill');
  const filesystem = await load('dsh-skill-filesystem');
  const ctx = new Context();
  const root = await mkdtemp(join(tmpdir(), 'skill-frontmatter-'));
  t.after(async () => { await ctx.fiber.dispose(); await rm(root, { recursive: true, force: true }); });
  const folder = join(root, 'sample-skill');
  await mkdir(folder);
  const header = 'name: sample-skill\r\ndescription: 示例说明\r\n';
  const body = '正文🌿\n'.repeat(100);
  await writeFile(join(folder, 'SKILL.md'), '---\r\n' + header + '---\r\n' + body);
  await ctx.plugin(SkillRegistry);
  await ctx.plugin(filesystem, { includeDefaultRoots: false, customSkillDirs: [root] });
  const clone = globalThis.structuredClone;
  let copies = 0;
  t.mock.method(globalThis, 'structuredClone', function(value, ...rest) {
    if (value === header) copies++;
    return Reflect.apply(clone, this, [value, ...rest]);
  });
  const catalog = await ctx.skills.snapshot({ cwd: root });
  assert.equal(catalog.skills[0].description, '示例说明');
  assert.equal(copies, 1);
  assert.equal((await ctx.skills.get('sample-skill', { cwd: root })).content, body.trim());
});
