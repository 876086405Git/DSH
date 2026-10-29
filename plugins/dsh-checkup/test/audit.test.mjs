// 环境体检（保留/卸载判定）自检
import { auditEnvironment, VERDICT } from '../lib/audit.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
};
const pick = (report, kind, name) => report.items.find((row) => row.kind === kind && row.name === name);
const verdictOf = (report, kind, name) => pick(report, kind, name)?.verdict;

const basePlugin = {
  name: 'p',
  version: '1.0.0',
  inBundles: true,
  inNodeModules: true,
  duplicateBundles: 1,
  declaresClient: true,
  missingPatch: false,
  prerelease: false,
  requiredBy: [],
};

console.log('\n[A] 插件判定');
{
  const missing = auditEnvironment({
    plugins: [{ ...basePlugin, name: 'gone', inNodeModules: false }],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  ok('实体缺失 → 卸载', verdictOf(missing, 'plugin', 'gone') === VERDICT.REMOVE);

  const builtin = auditEnvironment({
    plugins: [{ ...basePlugin, name: '@deepseek-ai/dsh-base', builtin: true, version: '' }],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  ok('宿主内置 → 保留', verdictOf(builtin, 'plugin', '@deepseek-ai/dsh-base') === VERDICT.KEEP);

  const dep = auditEnvironment({
    plugins: [{ ...basePlugin, name: 'dep', requiredBy: ['other'] }],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  ok('被依赖 → 保留', verdictOf(dep, 'plugin', 'dep') === VERDICT.KEEP);

  const bad = auditEnvironment({
    plugins: [{ ...basePlugin, name: 'old', dshRange: '>=9.0.0', incompatibleDsh: true }],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  ok('版本不兼容 → 卸载', verdictOf(bad, 'plugin', 'old') === VERDICT.REMOVE);

  // 反向插桩：宿主版本未知（0.0.0）时不得据此判不兼容
  const unknown = auditEnvironment({
    plugins: [{ ...basePlugin, name: 'old2', dshRange: '>=9.0.0', incompatibleDsh: true }],
    context: { dshVersion: '0.0.0' },
  });
  ok('离线(0.0.0) 不误判不兼容', verdictOf(unknown, 'plugin', 'old2') === VERDICT.KEEP, verdictOf(unknown, 'plugin', 'old2'));

  const dup = auditEnvironment({
    plugins: [{ ...basePlugin, name: 'twice', duplicateBundles: 2 }],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  ok('重复登记 → 卸载', verdictOf(dup, 'plugin', 'twice') === VERDICT.REMOVE);

  const pre = auditEnvironment({
    plugins: [{ ...basePlugin, name: 'pre', prerelease: true }],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  ok('预发布 → 待确认', verdictOf(pre, 'plugin', 'pre') === VERDICT.REVIEW);

  const fine = auditEnvironment({
    plugins: [basePlugin],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  ok('正常插件 → 保留', verdictOf(fine, 'plugin', 'p') === VERDICT.KEEP);
}

console.log('\n[B] skill 判定');
{
  const noMd = auditEnvironment({ skills: [{ name: 's1', hasSkillMd: false, fileCount: 3 }], context: {} });
  ok('缺 SKILL.md → 卸载', verdictOf(noMd, 'skill', 's1') === VERDICT.REMOVE);

  const empty = auditEnvironment({ skills: [{ name: 's2', hasSkillMd: true, fileCount: 0 }], context: {} });
  ok('空目录 → 卸载', verdictOf(empty, 'skill', 's2') === VERDICT.REMOVE);

  const risky = auditEnvironment({ skills: [{ name: 's3', hasSkillMd: true, fileCount: 5, hasDangerousScript: true }], context: {} });
  ok('脚本有风险 → 待确认', verdictOf(risky, 'skill', 's3') === VERDICT.REVIEW);

  const good = auditEnvironment({ skills: [{ name: 's4', hasSkillMd: true, fileCount: 5 }], context: {} });
  ok('正常 skill → 保留', verdictOf(good, 'skill', 's4') === VERDICT.KEEP);
}

console.log('\n[C] MCP 判定');
{
  const noCmd = auditEnvironment({ mcp: [{ id: 'm1', serverName: 'x', command: 'no-such', commandExists: false }], context: {} });
  ok('命令不存在 → 卸载', verdictOf(noCmd, 'mcp', 'x') === VERDICT.REMOVE);

  const dup = auditEnvironment({
    mcp: [
      { id: 'm1', serverName: 'same', command: 'uvx', commandExists: true },
      { id: 'm2', serverName: 'same', command: 'uvx', commandExists: true },
    ],
    context: { duplicateServerNames: ['same'] },
  });
  ok('serverName 重复 → 卸载', verdictOf(dup, 'mcp', 'same') === VERDICT.REMOVE);

  const unnamed = auditEnvironment({ mcp: [{ id: 'm3', serverName: '', command: 'uvx', commandExists: true }], context: {} });
  ok('未命名 → 待确认', verdictOf(unnamed, 'mcp', 'm3') === VERDICT.REVIEW);

  const secret = auditEnvironment({ mcp: [{ id: 'm4', serverName: 'y', command: 'uvx', commandExists: true, hasPlainSecret: true }], context: {} });
  ok('明文密钥 → 待确认', verdictOf(secret, 'mcp', 'y') === VERDICT.REVIEW);

  const good = auditEnvironment({ mcp: [{ id: 'm5', serverName: 'z', command: 'uvx', commandExists: true }], context: {} });
  ok('正常 MCP → 保留', verdictOf(good, 'mcp', 'z') === VERDICT.KEEP);
}

console.log('\n[D] 汇总统计');
{
  const report = auditEnvironment({
    plugins: [basePlugin, { ...basePlugin, name: 'gone', inNodeModules: false }],
    skills: [{ name: 's', hasSkillMd: true, fileCount: 2 }],
    mcp: [{ id: 'm', serverName: 'x', command: 'uvx', commandExists: true }],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  ok('total = 4', report.summary.total === 4, report.summary);
  ok('keep + review + remove = total', report.summary.keep + report.summary.review + report.summary.remove === report.summary.total);
  ok('按类统计齐全', Boolean(report.byKind.plugin && report.byKind.skill && report.byKind.mcp));
  ok('remove 计数 = 1', report.summary.remove === 1, report.summary);
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
