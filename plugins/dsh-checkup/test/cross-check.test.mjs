// 0.4.0 交叉比对（候选 vs 已装）回归测试
//
// 这一组断言全部是「0.3.4 上必红」的：旧代码里根本没有这些规则 id，
// `checks.find(c => c.id === '...')` 会拿到 undefined，断言必然失败。
// 反向插桩验证方式：把本文件拷到 0.3.4 的 lib/ 旁边跑一遍 → 必须大面积 FAIL。
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { checkCandidate, RULE_IDS } from '../lib/rules.js';
import { checkMcp } from '../lib/mcp.js';
import { checkSkill, skillContentHash } from '../lib/skill.js';
import { checkExpert } from '../lib/expert.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra === undefined ? '' : ' -> ' + JSON.stringify(extra)}`);
  }
};

const checkOf = (report, id) => (Array.isArray(report) ? report : report?.checks || []).find((row) => row.id === id);
const levelOf = (report, id) => checkOf(report, id)?.level;
const detailOf = (report, id) => String(checkOf(report, id)?.detail || '');

const env = (over = {}) => ({
  dshVersion: '0.3.4',
  dshVersionKnown: true,
  nodeVersion: '24.18.0',
  availableClientPackages: [],
  installedVersions: {},
  profileBundles: [],
  bundleSoftLimit: 40,
  knownBad: [],
  ...over,
});

const manifest = (over = {}) => ({
  name: 'dsh-demo',
  version: '1.0.0',
  main: 'lib/index.js',
  license: 'MIT',
  repository: 'https://example.com/dsh-demo',
  scripts: { test: 'node --test' },
  engines: { dsh: '>=0.2.0', node: '>=18' },
  ...over,
});

// ── [1] 规则目录 ────────────────────────────────────────────────────────────
console.log('\n[1] RULE_IDS 收录 8 条交叉比对规则');
{
  const expected = [
    'dup-plugin-version',
    'conflict-deps',
    'dup-connector-name',
    'conflict-connector-tool',
    'dup-skill-content',
    'cand-expert-shape',
    'cand-expert-dup',
    'cand-expert-refs',
  ];
  for (const id of expected) ok(`RULE_IDS 含 ${id}`, RULE_IDS.includes(id));
}

// ── [2] 插件：同名版本比对 ──────────────────────────────────────────────────
console.log('\n[2] dup-plugin-version');
{
  const same = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: manifest(),
    env: env({ profileBundles: ['dsh-demo'], installedVersions: { 'dsh-demo': '1.0.0' } }),
  });
  ok('同版本 → pass', levelOf(same, 'dup-plugin-version') === 'pass', levelOf(same, 'dup-plugin-version'));

  const upgrade = checkCandidate({
    spec: 'dsh-demo@1.1.0',
    manifest: manifest({ version: '1.1.0' }),
    env: env({ profileBundles: ['dsh-demo'], installedVersions: { 'dsh-demo': '1.0.0' } }),
  });
  ok('版本不同 → warn', levelOf(upgrade, 'dup-plugin-version') === 'warn');
  ok(
    '明细同时给出两个版本',
    detailOf(upgrade, 'dup-plugin-version').includes('1.0.0') && detailOf(upgrade, 'dup-plugin-version').includes('1.1.0'),
    detailOf(upgrade, 'dup-plugin-version'),
  );

  const downgrade = checkCandidate({
    spec: 'dsh-demo@0.9.0',
    manifest: manifest({ version: '0.9.0' }),
    env: env({ profileBundles: ['dsh-demo'], installedVersions: { 'dsh-demo': '1.0.0' } }),
  });
  ok('降级被单独标出', String(checkOf(downgrade, 'dup-plugin-version')?.title).includes('低于'));

  const asDep = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: manifest(),
    env: env({ profileBundles: [], installedVersions: { 'dsh-demo': '1.0.0' } }),
  });
  ok('同名包只是依赖时也提醒', levelOf(asDep, 'dup-plugin-version') === 'warn' && String(checkOf(asDep, 'dup-plugin-version')?.title).includes('依赖'), checkOf(asDep, 'dup-plugin-version'));
}

// ── [3] 插件：依赖排斥 ──────────────────────────────────────────────────────
console.log('\n[3] conflict-deps');
{
  const hard = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: manifest({ dependencies: { '@deepseek-ai/cordis': '^5.0.0' } }),
    env: env({ installedVersions: { '@deepseek-ai/cordis': '4.2.1' } }),
  });
  ok('宿主单例包互斥 → block', levelOf(hard, 'conflict-deps') === 'block', levelOf(hard, 'conflict-deps'));
  ok('明细写明两个版本', detailOf(hard, 'conflict-deps').includes('4.2.1') && detailOf(hard, 'conflict-deps').includes('^5.0.0'));

  const soft = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: manifest({ dependencies: { yaml: '^3.0.0' } }),
    env: env({ installedVersions: { yaml: '2.9.1' } }),
  });
  ok('普通依赖版本不一致 → warn', levelOf(soft, 'conflict-deps') === 'warn', levelOf(soft, 'conflict-deps'));

  const fine = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: manifest({ dependencies: { yaml: '^2.9.0' } }),
    env: env({ installedVersions: { yaml: '2.9.1' } }),
  });
  ok('范围满足 → pass', levelOf(fine, 'conflict-deps') === 'pass');

  const noData = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: manifest({ dependencies: { yaml: '^2.9.0' } }),
    env: env({ installedVersions: {} }),
  });
  ok('读不到已装清单 → 不误判为冲突', levelOf(noData, 'conflict-deps') === 'warn');
}

// ── [4] 连接器：重名 + 工具级冲突 ───────────────────────────────────────────
console.log('\n[4] dup-connector-name / conflict-connector-tool');
{
  const base = { transport: 'stdio', serverName: 'cad', command: 'uvx', args: ['--from', 'cadgen==0.7.26', 'cadgen', 'mcp'] };
  const resolved = { exists: true, path: 'C:/uvx.exe' };

  const dup = checkMcp(base, { ...resolved, existingServerNames: ['cad'] });
  ok('与已装重名 → warn', levelOf(dup, 'dup-connector-name') === 'warn');
  ok('重名不再占用 mcp-servername', levelOf(dup, 'mcp-servername') === 'pass');

  const self = checkMcp(base, { ...resolved, existingConnectors: [{ serverName: 'cad', command: 'uvx', args: base.args }], candidatePersisted: true });
  ok('已落盘条目复查时不自己撞自己', levelOf(self, 'dup-connector-name') === 'pass', levelOf(self, 'dup-connector-name'));

  const realDup = checkMcp(base, {
    ...resolved,
    existingConnectors: [
      { serverName: 'cad', command: 'a', args: [] },
      { serverName: 'cad', command: 'b', args: [] },
    ],
    candidatePersisted: true,
  });
  ok('已落盘且有两条同名 → warn', levelOf(realDup, 'dup-connector-name') === 'warn');

  const caseVariant = checkMcp({ ...base, serverName: 'CAD' }, { ...resolved, existingConnectors: [{ serverName: 'cad', command: 'other', args: [] }] });
  ok('大小写不同按重名处理', levelOf(caseVariant, 'dup-connector-name') === 'warn');

  const sepVariant = checkMcp({ ...base, serverName: 'c_ad' }, { ...resolved, existingConnectors: [{ serverName: 'cad', command: 'other', args: [] }] });
  ok('只差分隔符 → 工具冲突 warn', levelOf(sepVariant, 'conflict-connector-tool') === 'warn');

  const sameBackend = checkMcp({ ...base, serverName: 'cad2' }, { ...resolved, existingConnectors: [{ serverName: 'cad', command: 'C:/bin/uvx.EXE', args: base.args }] });
  ok('同一后端换名字 → 工具冲突 warn', levelOf(sameBackend, 'conflict-connector-tool') === 'warn');

  const clean = checkMcp({ ...base, serverName: 'other' }, { ...resolved, existingConnectors: [{ serverName: 'cad', command: 'uvx', args: ['x'] }] });
  ok('无关连接器 → pass', levelOf(clean, 'dup-connector-name') === 'pass' && levelOf(clean, 'conflict-connector-tool') === 'pass');
}

// ── [5] 技能：改名同款 ──────────────────────────────────────────────────────
console.log('\n[5] dup-skill-content');
{
  const skillText = '---\nname: review\ndescription: 代码审查\n---\n\n# Review\n细节正文\n';
  const files = [{ path: 'SKILL.md', text: skillText }];
  const hash = skillContentHash(skillText);

  const renamed = checkSkill({
    dirPath: 'C:/tmp/review-copy',
    files,
    existingNames: ['review'],
    existingSkills: [{ dirName: 'review', skillName: 'review', hash }],
  });
  ok('内容指纹相同 → warn', levelOf(renamed, 'dup-skill-content') === 'warn');
  ok('明细点出撞车目录', detailOf(renamed, 'dup-skill-content').includes('review'));

  const declName = checkSkill({
    dirPath: 'C:/tmp/another',
    files,
    existingNames: ['other'],
    existingSkills: [{ dirName: 'other', skillName: 'Review', hash: 'deadbeef' }],
  });
  ok('frontmatter name 撞车 → warn', levelOf(declName, 'dup-skill-content') === 'warn');

  const unique = checkSkill({
    dirPath: 'C:/tmp/unique',
    files: [{ path: 'SKILL.md', text: '---\nname: unique\ndescription: 独一份\n---\n正文\n' }],
    existingNames: [],
    existingSkills: [{ dirName: 'review', skillName: 'review', hash }],
  });
  ok('不重复 → pass', levelOf(unique, 'dup-skill-content') === 'pass');
}

// ── [6] 专家 ───────────────────────────────────────────────────────────────
console.log('\n[6] cand-expert-*');
{
  const persona = '你是陈漫勤，22岁，温柔细腻，说话简短，遇到技术问题先给结论再给证据。';
  const installed = [{ id: 'preset-wbexpert-review', name: '代码审查专家', persona }];

  const sameId = checkExpert({ id: 'preset-wbexpert-review', name: '另一个名字', persona: '完全不同的一段人设正文，长度够二十个字。' }, { experts: installed });
  ok('id 撞车 → block', levelOf(sameId, 'cand-expert-dup') === 'block');

  const samePersona = checkExpert({ id: 'preset-wbexpert-copy', name: '新名字', persona }, { experts: installed });
  ok('同一套人设换名 → warn', levelOf(samePersona, 'cand-expert-dup') === 'warn');
  ok('明细指出与人设重复', detailOf(samePersona, 'cand-expert-dup').includes('preset-wbexpert-review'));

  const sameName = checkExpert({ id: 'preset-wbexpert-x', name: '代码审查专家', persona: '另一个人设，长度也够二十个字，内容不同。' }, { experts: installed });
  ok('名称撞车 → warn', levelOf(sameName, 'cand-expert-dup') === 'warn');

  const empty = checkExpert({ id: 'preset-wbexpert-empty', name: '空人设', persona: '' }, { experts: installed });
  ok('人设为空 → block', levelOf(empty, 'cand-expert-shape') === 'block');

  const shortPersona = checkExpert({ id: 'preset-wbexpert-short', name: '短人设', persona: '很短' }, { experts: installed });
  ok('人设过短 → warn', levelOf(shortPersona, 'cand-expert-shape') === 'warn');

  const missingRef = checkExpert(
    { id: 'preset-wbexpert-ref', name: '依赖专家', persona: '这是一段足够长度的人设正文，用来触发引用检查。', externalRefs: ['dsh-pet-bridge'] },
    { experts: installed, installedNames: ['dsh-checkup'] },
  );
  ok('引用插件没装 → warn', levelOf(missingRef, 'cand-expert-refs') === 'warn');

  const clean = checkExpert(
    { id: 'preset-wbexpert-new', name: '新专家', persona: '这是一段全新的、不与任何已装专家重复的人设正文内容。', externalRefs: [] },
    { experts: installed, installedNames: [] },
  );
  ok('无冲突 → 三条全 pass', ['cand-expert-shape', 'cand-expert-dup', 'cand-expert-refs'].every((id) => levelOf(clean, id) === 'pass'));
}

// ── [7] 集成：两个技能根都参与比对 ──────────────────────────────────────────
console.log('\n[7] checkSkillDir 覆盖 ~/.agents/skills（旧版只扫 ~/.dsh/skills）');
{
  const root = mkdtempSync(join(tmpdir(), 'checkup-cross-'));
  const homeDsh = join(root, '.dsh');
  const agentsSkills = join(root, '.agents', 'skills');
  const bodyA = '---\nname: shared-skill\ndescription: 候选自己那份\n---\n\n候选正文 A\n';
  const bodyB = '---\nname: shared-skill\ndescription: agent 根里那份\n---\n\n已装正文 B\n';
  const bodyX = '---\nname: mirror\ndescription: 同内容不同名\n---\n\n一模一样的正文\n';

  // 场景 1：同名但内容不同 —— 只有把 ~/.agents/skills 也纳入比对才看得到
  mkdirSync(join(homeDsh, 'skills', 'shared-skill'), { recursive: true });
  writeFileSync(join(homeDsh, 'skills', 'shared-skill', 'SKILL.md'), bodyA, 'utf8');
  mkdirSync(join(agentsSkills, 'shared-skill'), { recursive: true });
  writeFileSync(join(agentsSkills, 'shared-skill', 'SKILL.md'), bodyB, 'utf8');

  // 场景 2：agent 根里已有一份同内容技能，候选换了目录名
  mkdirSync(join(homeDsh, 'skills', 'mirror-copy'), { recursive: true });
  writeFileSync(join(homeDsh, 'skills', 'mirror-copy', 'SKILL.md'), bodyX, 'utf8');
  mkdirSync(join(agentsSkills, 'mirror'), { recursive: true });
  writeFileSync(join(agentsSkills, 'mirror', 'SKILL.md'), bodyX, 'utf8');

  // index.js 在模块加载时读 DSH_HOME，所以先设环境变量再动态 import。
  process.env.DSH_HOME = homeDsh;
  const mod = await import('../lib/index.js');

  const named = await mod.checkSkillDir(join(homeDsh, 'skills', 'shared-skill'));
  ok('agent 根里的同名技能被 sk-name 发现', (named.checks || []).some((c) => c.id === 'sk-name' && c.level === 'warn'));

  const mirrored = await mod.checkSkillDir(join(homeDsh, 'skills', 'mirror-copy'));
  ok('agent 根里的同内容技能被 dup-skill-content 发现', levelOf(mirrored, 'dup-skill-content') === 'warn', levelOf(mirrored, 'dup-skill-content'));
  rmSync(root, { recursive: true, force: true });
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
