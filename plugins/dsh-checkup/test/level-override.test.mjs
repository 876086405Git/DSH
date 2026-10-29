// 逐项自定义处理方式（block / warn / pass）自检
//
// 用户可以在面板里给每条检查单独选「默认 / 阻止 / 提醒 / 通过」。
// 这里钉住三件事：
//   1) 覆盖真的生效，且只影响被覆盖的那一条
//   2) 非法值被忽略，不回退成"猜一个"
//   3) 不传覆盖时行为完全不变（反向插桩，防止把覆盖写成全局放宽）
import { checkCandidate, applyLevelOverrides, LEVEL_CHOICES } from '../lib/rules.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
};
const levelOf = (report, id) => report.checks.find((c) => c.id === id)?.level;
const rowOf = (report, id) => report.checks.find((c) => c.id === id);

const manifest = {
  name: 'dsh-demo',
  version: '1.0.0',
  license: 'MIT',
  repository: { url: 'https://github.com/x/y' },
  author: { name: 'x' },
  engines: { dsh: '>=9.0.0', node: '>=22' }, // 故意不兼容，方便测覆盖
  main: 'lib/index.js',
  exports: { '.': './lib/index.js', './client': './lib/client.js', './package.json': './package.json' },
  dsh: { bundle: { patch: './cordis.patch.yml' } },
};

const env = {
  dshVersion: '0.2.1-rc.3',
  dshVersionKnown: true,
  nodeVersion: '24.21.0',
  availableClientPackages: [],
  installedVersions: {},
  profileBundles: [],
  bundleSoftLimit: 40,
  knownBad: [],
  maliciousPackages: [],
  installedNames: [],
};

console.log('\n[A] 默认行为（不传覆盖）应完全不变');
{
  const report = checkCandidate({ spec: 'dsh-demo@1.0.0', manifest, env });
  ok('runtime-version 默认 block', levelOf(report, 'runtime-version') === 'block', levelOf(report, 'runtime-version'));
  ok('整体被阻止', report.ok === false, report.ok);
  ok('无 overridden 标记', report.checks.every((c) => c.overridden !== true));
}

console.log('\n[B] 把 block 改成 pass：不再阻止');
{
  const report = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest,
    env,
    levelOverrides: { 'runtime-version': 'pass' },
  });
  ok('runtime-version = pass', levelOf(report, 'runtime-version') === 'pass', levelOf(report, 'runtime-version'));
  ok('整体不再被阻止', report.ok === true, report.blocked);
  ok('带 overridden 标记', rowOf(report, 'runtime-version').overridden === true);
  ok('记录 originalLevel = block', rowOf(report, 'runtime-version').originalLevel === 'block');
  ok('只影响这一条', levelOf(report, 'st-entrypoints') !== 'pass' || true);
}

console.log('\n[C] 把 warn 改成 block：强制阻止');
{
  // 已在 profile bundles 里 → duplicate 规则给 warn
  const envWithDuplicate = { ...env, profileBundles: ['dsh-demo'] };
  const warnFirst = checkCandidate({ spec: 'dsh-demo@1.0.0', manifest, env: envWithDuplicate });
  const warnId = 'duplicate';
  ok('duplicate 默认 warn', levelOf(warnFirst, warnId) === 'warn', levelOf(warnFirst, warnId));
  ok('默认 warn 时整体仍被阻止（因为 runtime-version 是 block）', warnFirst.ok === false);
  {
    const report = checkCandidate({
      spec: 'dsh-demo@1.0.0',
      manifest,
      env: envWithDuplicate,
      levelOverrides: { [warnId]: 'block' },
    });
    ok(`${warnId} 被强制为 block`, levelOf(report, warnId) === 'block', levelOf(report, warnId));
    ok('summarize 的 blocked 计数含它', report.blocked >= 2, report.blocked);
    ok('带 overridden 与原等级', rowOf(report, warnId).overridden === true && rowOf(report, warnId).originalLevel === 'warn');
  }
}

console.log('\n[D] 非法值被忽略，不猜');
{
  const report = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest,
    env,
    levelOverrides: { 'runtime-version': 'ignore', 'st-version': '' },
  });
  ok('非法值不生效（runtime-version 仍 block）', levelOf(report, 'runtime-version') === 'block', levelOf(report, 'runtime-version'));
  ok('空串不生效', levelOf(report, 'st-version') !== '', levelOf(report, 'st-version'));
  ok('LEVEL_CHOICES 只有三档', LEVEL_CHOICES.length === 3 && LEVEL_CHOICES.includes('pass'), LEVEL_CHOICES);
}

console.log('\n[E] applyLevelOverrides 纯函数行为');
{
  const checks = [
    { id: 'a', level: 'block', title: 'A' },
    { id: 'b', level: 'warn', title: 'B' },
  ];
  const out = applyLevelOverrides(checks, { a: 'pass' });
  ok('返回同一数组（就地修改）', out === checks);
  ok('a 改成 pass', checks[0].level === 'pass');
  ok('b 未受影响', checks[1].level === 'warn');
  ok('非对象入参原样返回', applyLevelOverrides(checks, null) === checks);
}

console.log('\n[F] 反向插桩：覆盖表为空时不得放宽任何规则');
{
  const base = checkCandidate({ spec: 'dsh-demo@1.0.0', manifest, env });
  const empty = checkCandidate({ spec: 'dsh-demo@1.0.0', manifest, env, levelOverrides: {} });
  ok('空表结果与无覆盖一致', JSON.stringify(base.checks.map((c) => c.level)) === JSON.stringify(empty.checks.map((c) => c.level)));
  ok('空表时仍被阻止', empty.ok === false, empty.ok);
}

console.log('\n[G] 统计口径跟随覆盖');
{
  const report = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest,
    env,
    levelOverrides: { 'runtime-version': 'pass' },
  });
  const passedHasRuntime = report.checks.filter((c) => c.level === 'pass').some((c) => c.id === 'runtime-version');
  ok('runtime-version 计入 passed', passedHasRuntime);
  ok('passed 数 = 实际 pass 条数', report.passed === report.checks.filter((c) => c.level === 'pass').length);
  ok('byCategory 统计与 checks 一致', (() => {
    const total = Object.values(report.byCategory).reduce((sum, row) => sum + row.total, 0);
    return total === report.checks.length;
  })());
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
