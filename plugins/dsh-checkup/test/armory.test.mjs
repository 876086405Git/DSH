// 军械库四类检查（连接器 / 技能 / 插件 / 专家）自检
//
// 四类的落盘位置不同，这里逐类钉住「结构非法要拦、重复/失效要提醒」，
// 并保证正常数据不被误报（反向插桩）。
import { checkArmory, summarizeArmory, ARMORY_KINDS, ARMORY_RULE_IDS } from '../lib/armory.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
};
const find = (checks, id) => checks.find((c) => c.id === id);
const levelOf = (checks, id) => find(checks, id)?.level;

const healthy = {
  connectors: [
    { id: 'mcp-a', serverName: 'a', transport: 'stdio', command: 'uvx', commandExists: true },
    { id: 'mcp-b', serverName: 'b', transport: 'stdio', command: 'uvx', commandExists: true },
  ],
  skills: [
    { name: 'cad', root: '.dsh/skills', hasSkillMd: true, fileCount: 5 },
    { name: 'dxf', root: '.dsh/skills', hasSkillMd: true, fileCount: 3 },
  ],
  plugins: [
    { name: 'dsh-armory', inNodeModules: true, duplicateBundles: 1, official: false },
    { name: '@deepseek-ai/dsh-base', inNodeModules: false, duplicateBundles: 1, official: true },
  ],
  experts: [],
};

console.log('\n[A] 四类覆盖完整性');
{
  const checks = checkArmory(healthy);
  const ids = new Set(checks.map((c) => c.id));
  ok('8 个检查项都在', ARMORY_RULE_IDS.every((id) => ids.has(id)), [...ids]);
  ok('规则数 = 8', ARMORY_RULE_IDS.length === 8);
  const kinds = new Set(checks.map((c) => c.armoryKind));
  ok('四类都出现过', ARMORY_KINDS.every((kind) => kinds.has(kind.id)), [...kinds]);
  const perKind = {};
  for (const check of checks) perKind[check.armoryKind] = (perKind[check.armoryKind] || 0) + 1;
  ok('每类恰好 2 项（不遗漏不重复）', ARMORY_KINDS.every((kind) => perKind[kind.id] === 2), perKind);
  ok('检查项 id 唯一', ids.size === checks.length);
}

console.log('\n[B] 健康数据不得误报（反向插桩）');
{
  const checks = checkArmory(healthy);
  ok('全部 pass', checks.every((c) => c.level === 'pass'), checks.filter((c) => c.level !== 'pass').map((c) => c.id));
  ok('官方包不算实体缺失', levelOf(checks, 'arm-plugin-entity') === 'pass');
}

console.log('\n[C] 连接器：结构非法要拦、重名要提醒');
{
  const bad = checkArmory({
    ...healthy,
    connectors: [
      { id: 'mcp-x', serverName: 'x', transport: 'websocket', command: 'uvx' },
      { id: 'mcp-y', serverName: 'dup', transport: 'stdio', command: 'uvx' },
      { id: 'mcp-z', serverName: 'dup', transport: 'stdio', command: 'uvx' },
      { id: 'mcp-w', serverName: 'w', transport: 'stdio' },
    ],
  });
  ok('非法 transport → block', levelOf(bad, 'arm-connector-shape') === 'block', levelOf(bad, 'arm-connector-shape'));
  ok('stdio 缺 command 计入非法', String(find(bad, 'arm-connector-shape').detail).includes('缺 command'));
  ok('serverName 重复 → warn', levelOf(bad, 'arm-connector-dup') === 'warn', levelOf(bad, 'arm-connector-dup'));
  ok('重复名出现在详情里', String(find(bad, 'arm-connector-dup').detail).includes('dup'));
}

console.log('\n[D] 技能：缺 SKILL.md 要拦、重名要提醒');
{
  const bad = checkArmory({
    ...healthy,
    skills: [
      { name: 'good', root: '.dsh/skills', hasSkillMd: true, fileCount: 2 },
      { name: 'empty-dir', root: '.agents/skills', hasSkillMd: false, fileCount: 0 },
      { name: 'same', root: '.dsh/skills', hasSkillMd: true, fileCount: 1 },
      { name: 'same', root: '.agents/skills', hasSkillMd: true, fileCount: 1 },
    ],
  });
  ok('缺 SKILL.md → block', levelOf(bad, 'arm-skill-manifest') === 'block', levelOf(bad, 'arm-skill-manifest'));
  ok('缺的文件名在详情里', String(find(bad, 'arm-skill-manifest').detail).includes('empty-dir'));
  ok('跨两个根重名 → warn', levelOf(bad, 'arm-skill-dup') === 'warn', levelOf(bad, 'arm-skill-dup'));
}

console.log('\n[E] 插件：实体缺失要拦、重复登记要提醒');
{
  const bad = checkArmory({
    ...healthy,
    plugins: [
      { name: 'gone-third-party', inNodeModules: false, duplicateBundles: 1, official: false },
      { name: 'twice', inNodeModules: true, duplicateBundles: 2, official: false },
    ],
  });
  ok('第三方缺实体 → block', levelOf(bad, 'arm-plugin-entity') === 'block', levelOf(bad, 'arm-plugin-entity'));
  ok('重复登记 → warn', levelOf(bad, 'arm-plugin-dup') === 'warn', levelOf(bad, 'arm-plugin-dup'));
}

console.log('\n[F] 专家：结构非法要拦、孤儿要提醒');
{
  const bad = checkArmory({
    ...healthy,
    experts: [
      { id: 'preset-wbexpert-ok', name: 'WorkBuddy 专家 · 甲', plugin: 'dsh-armory', hasPersona: true, pluginInstalled: true },
      { id: 'wrong-id', name: 'WorkBuddy 专家 · 乙', plugin: '', hasPersona: true, pluginInstalled: true },
      { id: 'preset-wbexpert-empty', name: 'WorkBuddy 专家 · 丙', plugin: 'dsh-armory', hasPersona: false, pluginInstalled: true },
      { id: 'preset-wbexpert-orphan', name: 'WorkBuddy 专家 · 丁', plugin: 'removed-plugin', hasPersona: true, pluginInstalled: false },
    ],
  });
  ok('id 不规范 → block', levelOf(bad, 'arm-expert-shape') === 'block', levelOf(bad, 'arm-expert-shape'));
  ok('人设为空计入非法', String(find(bad, 'arm-expert-shape').detail).includes('人设正文为空'));
  ok('孤儿专家 → warn', levelOf(bad, 'arm-expert-orphan') === 'warn', levelOf(bad, 'arm-expert-orphan'));
  ok('孤儿详情带来源插件', String(find(bad, 'arm-expert-orphan').detail).includes('removed-plugin'));
}

console.log('\n[G] 空数据：跳过而不是报错');
{
  const empty = checkArmory({});
  ok('8 项都有结论', empty.length === 8, empty.length);
  ok('全部 pass', empty.every((c) => c.level === 'pass'), empty.filter((c) => c.level !== 'pass').map((c) => c.id));
}

console.log('\n[H] 分类与汇总');
{
  const checks = checkArmory(healthy);
  ok('结构项归兼容性', find(checks, 'arm-connector-shape').category === 'compatibility');
  ok('重复项归稳定性', find(checks, 'arm-connector-dup').category === 'stability');
  const stats = summarizeArmory(checks);
  ok('四类统计齐全', ARMORY_KINDS.every((kind) => Boolean(stats[kind.id])), Object.keys(stats));
  ok('统计总数 = 8', Object.values(stats).reduce((sum, row) => sum + row.total, 0) === 8);
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
