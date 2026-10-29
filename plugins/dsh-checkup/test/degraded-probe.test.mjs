// 降级探测场景：宿主信息读不到时，检查必须"跳过"而不是"判死"
//
// 背景：桌面版可能把宿主封在 resources/app.asar 里。探测不到宿主版本与内置包时，
// 旧逻辑会把「没读到」当成「不存在」，导致：
//   · 所有声明 dsh 版本范围的插件被判不兼容 → 拒绝安装
//   · 所有带 dsh.client.inject 的插件被判依赖缺失 → 拒绝安装
//   · 体检把 @deepseek-ai/* 内置包判「实体缺失，建议删除」→ 照做 DSH 起不来
// 本文件钉住"跳过"语义，并用反向用例证明没有把保护写成"永远放行"。
import { checkCandidate } from '../lib/rules.js';
import { auditEnvironment, VERDICT } from '../lib/audit.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
};
const levelOf = (report, id) => report.checks.find((c) => c.id === id)?.level;

const manifest = {
  name: 'dsh-demo',
  version: '1.0.0',
  license: 'MIT',
  repository: { url: 'https://github.com/x/y' },
  author: { name: 'x' },
  engines: { dsh: '>=0.2.0', node: '>=22' },
  main: 'lib/index.js',
  exports: { '.': './lib/index.js', './client': './lib/client.js', './package.json': './package.json' },
  dsh: {
    bundle: { patch: './cordis.patch.yml' },
    client: { platform: 'web', inject: ['@deepseek-ai/dsh-client-layout'] },
  },
  peerDependencies: { '@deepseek-ai/cordis': '^4.0.0' },
};

/** 探测失败的宿主环境：版本未读到、包列表为空、安装清单为空。 */
const degradedEnv = {
  dshVersion: '0.0.0',
  dshVersionKnown: false,
  nodeVersion: '24.21.0',
  availableClientPackages: [],
  installedVersions: {},
  profileBundles: [],
  bundleSoftLimit: 40,
  knownBad: [],
  maliciousPackages: [],
  installedNames: [],
};

/** 探测正常的宿主环境。 */
const healthyEnv = {
  dshVersion: '0.2.1-rc.3',
  dshVersionKnown: true,
  nodeVersion: '24.21.0',
  availableClientPackages: ['@deepseek-ai/dsh-client-layout'],
  installedVersions: { '@deepseek-ai/cordis': '4.0.5' },
  profileBundles: [],
  bundleSoftLimit: 40,
  knownBad: [],
  maliciousPackages: [],
  installedNames: [],
};

console.log('\n[A] 降级探测：版本读不到时不判不兼容');
{
  const report = checkCandidate({ spec: 'dsh-demo@1.0.0', manifest, env: degradedEnv });
  ok('runtime-version = warn（不是 block）', levelOf(report, 'runtime-version') === 'warn', levelOf(report, 'runtime-version'));
  ok('整体未被阻止', report.blocked === 0, report.blocked);
}

console.log('\n[B] 降级探测：包列表为空时不判依赖缺失');
{
  const report = checkCandidate({ spec: 'dsh-demo@1.0.0', manifest, env: degradedEnv });
  ok('client-inject = warn（不是 block）', levelOf(report, 'client-inject') === 'warn', levelOf(report, 'client-inject'));
}

console.log('\n[C] 降级探测：安装清单为空时不报"未安装"');
{
  const report = checkCandidate({ spec: 'dsh-demo@1.0.0', manifest, env: degradedEnv });
  const peer = report.checks.find((c) => c.id === 'peer-deps');
  ok('peer-deps 不判 block', peer ? peer.level !== 'block' : true, peer && peer.level);
  ok('详情里没有"未安装"字样', !(peer && String(peer.detail || '').includes('未安装')), peer && peer.detail);
}

console.log('\n[D] 反向插桩：信息齐全时必须照常判死');
{
  // D1 版本真的不兼容 → 必须 block
  const badVersion = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: { ...manifest, engines: { dsh: '>=9.0.0', node: '>=22' } },
    env: healthyEnv,
  });
  ok('版本真不兼容 → block', levelOf(badVersion, 'runtime-version') === 'block', levelOf(badVersion, 'runtime-version'));

  // D2 注入依赖真的缺 → 必须 block
  const badInject = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: { ...manifest, dsh: { ...manifest.dsh, client: { platform: 'web', inject: ['@deepseek-ai/does-not-exist'] } } },
    env: healthyEnv,
  });
  ok('注入依赖真缺 → block', levelOf(badInject, 'client-inject') === 'block', levelOf(badInject, 'client-inject'));

  // D3 peer 真的没装 → 必须提醒未安装
  const badPeer = checkCandidate({
    spec: 'dsh-demo@1.0.0',
    manifest: { ...manifest, peerDependencies: { '@deepseek-ai/not-installed': '^1.0.0' } },
    env: healthyEnv,
  });
  const peerRow = badPeer.checks.find((c) => c.id === 'peer-deps');
  ok('peer 真缺 → 报未安装', Boolean(peerRow && String(peerRow.detail || '').includes('未安装')), peerRow && peerRow.detail);
}

console.log('\n[E] 体检：@deepseek-ai/* 即使读不到实体也必须保留');
{
  const report = auditEnvironment({
    plugins: [
      // 模拟 asar 场景：采集端拿不到实体，builtin 也没标出来
      { name: '@deepseek-ai/dsh-base', version: '', inBundles: true, inNodeModules: false, builtin: false, duplicateBundles: 1, requiredBy: [] },
      { name: '@deepseek-ai/dsh-web-app', version: '', inBundles: true, inNodeModules: false, builtin: false, duplicateBundles: 1, requiredBy: [] },
      // 第三方包：真的缺失，必须还能判卸载
      { name: 'dsh-third-party-gone', version: '1.0.0', inBundles: true, inNodeModules: false, builtin: false, duplicateBundles: 1, requiredBy: [] },
    ],
    context: { dshVersion: '0.0.0' },
  });
  const base = report.items.find((row) => row.name === '@deepseek-ai/dsh-base');
  const webApp = report.items.find((row) => row.name === '@deepseek-ai/dsh-web-app');
  const third = report.items.find((row) => row.name === 'dsh-third-party-gone');
  ok('dsh-base 保留', base && base.verdict === VERDICT.KEEP, base && base.verdict);
  ok('dsh-web-app 保留', webApp && webApp.verdict === VERDICT.KEEP, webApp && webApp.verdict);
  ok('第三方缺失仍判卸载（保护没过度）', third && third.verdict === VERDICT.REMOVE, third && third.verdict);
  ok('官方包理由写明内置', base && base.reason.includes('内置'), base && base.reason);
}

console.log('\n[F] 体检：宿主内置标记仍然优先');
{
  const report = auditEnvironment({
    plugins: [{ name: '@deepseek-ai/dsh-experimental-auto-review', version: '', inBundles: true, inNodeModules: true, builtin: true, duplicateBundles: 1, requiredBy: [] }],
    context: { dshVersion: '0.2.1-rc.3' },
  });
  const row = report.items[0];
  ok('builtin 标记 → 保留', row.verdict === VERDICT.KEEP, row.verdict);
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
