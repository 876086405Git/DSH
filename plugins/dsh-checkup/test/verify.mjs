// checkup 自检：
//  1) 规则内核的正向 / 反向（插桩）断言 —— 断言必须能被打红才算有效；
//  2) 真实 registry 包预检（只读 HTTP，不安装任何东西）。
import { checkCandidate, summarize } from '../lib/rules.js';
import { satisfies } from '../lib/version.js';
import { resolveManifest, parseInstallSpec } from '../lib/index.js';
import { REPO_ROOT } from './_paths.mjs';

let failures = 0;
let skips = 0;
function assert(label, condition, extra) {
  if (condition) {
    console.log(`  ok   ${label}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${label}${extra ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
}

const baseEnv = {
  dshVersion: '0.2.1-rc.3',
  nodeVersion: '24.21.0',
  availableClientPackages: ['@deepseek-ai/dsh-client-ui-layout', '@deepseek-ai/dsh-client-ui-conversation'],
  installedVersions: { '@deepseek-ai/cordis': '3.18.5' },
  profileBundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'],
  bundleSoftLimit: 40,
  knownBad: [],
};

const goodManifest = {
  name: 'dsh-good-plugin',
  version: '1.0.0',
  license: 'MIT',
  repository: { url: 'https://github.com/example/good-plugin' },
  author: { name: 'example' },
  engines: { dsh: '>=0.2.0', node: '>=22' },
  main: 'lib/index.js',
  exports: {
    '.': './lib/index.js',
    './client': './lib/client.js',
    './package.json': './package.json',
  },
  dsh: {
    bundle: { patch: './cordis.patch.yml' },
    client: { platform: 'web', inject: ['@deepseek-ai/dsh-client-ui-layout'] },
  },
  peerDependencies: { '@deepseek-ai/cordis': '^3.0.0' },
};

const levelOf = (report, id) => report.checks.find((c) => c.id === id)?.level;

console.log('\n[1] 版本范围比较');
assert('^0.2.0 接受 0.2.1-rc.3', satisfies('0.2.1-rc.3', '^0.2.0'));
assert('^0.3.0 拒绝 0.2.1-rc.3', !satisfies('0.2.1-rc.3', '^0.3.0'));
assert('>=0.2.0 <0.3.0 接受 0.2.1', satisfies('0.2.1', '>=0.2.0 <0.3.0'));
assert('~1.2 拒绝 1.3.0', !satisfies('1.3.0', '~1.2'));
assert('1.x 接受 1.9.9', satisfies('1.9.9', '1.x'));

console.log('\n[2] 兼容包整体通过');
{
  const report = checkCandidate({ spec: 'dsh-good-plugin@1.0.0', manifest: goodManifest, env: baseEnv });
  assert('ok=true', report.ok === true, report);
  assert('阻塞项为 0', report.blocked === 0);
  assert('runtime-version 通过', levelOf(report, 'runtime-version') === 'pass');
  assert('client-inject 通过', levelOf(report, 'client-inject') === 'pass');
}

console.log('\n[3] 版本不兼容 → 拦截');
{
  const bad = { ...goodManifest, engines: { dsh: '^0.3.0' } };
  const report = checkCandidate({ spec: 'dsh-bad@1.0.0', manifest: bad, env: baseEnv });
  assert('ok=false', report.ok === false);
  assert('runtime-version=block', levelOf(report, 'runtime-version') === 'block');
}

console.log('\n[4] 客户端注入包缺失 → 拦截（反向插桩证明有效）');
{
  const bad = {
    ...goodManifest,
    dsh: { ...goodManifest.dsh, client: { platform: 'web', inject: ['@deepseek-ai/dsh-client-ui-removed'] } },
  };
  const blocked = checkCandidate({ spec: 'dsh-x@1.0.0', manifest: bad, env: baseEnv });
  assert('缺包时 client-inject=block', levelOf(blocked, 'client-inject') === 'block');

  // 插桩：把缺失的包补进环境，同一份 manifest 必须立刻转为 pass
  const patchedEnv = {
    ...baseEnv,
    availableClientPackages: [...baseEnv.availableClientPackages, '@deepseek-ai/dsh-client-ui-removed'],
  };
  const passed = checkCandidate({ spec: 'dsh-x@1.0.0', manifest: bad, env: patchedEnv });
  assert('插桩后 client-inject=pass（说明检查读的是环境而不是硬编码）', levelOf(passed, 'client-inject') === 'pass');
  assert('插桩后整体 ok=true', passed.ok === true);
}

console.log('\n[5] 平台不符 → 拦截');
{
  const bad = { ...goodManifest, dsh: { ...goodManifest.dsh, client: { platform: 'node' } } };
  const report = checkCandidate({ spec: 'dsh-n@1.0.0', manifest: bad, env: baseEnv });
  assert('client-platform=block', levelOf(report, 'client-platform') === 'block');
}

console.log('\n[6] bundle 声明缺 patch → 拦截');
{
  const bad = { ...goodManifest, dsh: { ...goodManifest.dsh, bundle: {} } };
  const report = checkCandidate({ spec: 'dsh-b@1.0.0', manifest: bad, env: baseEnv });
  assert('bundle-declared=block', levelOf(report, 'bundle-declared') === 'block');
}

console.log('\n[7] 黑名单命中 → 拦截');
{
  const env = { ...baseEnv, knownBad: ['dsh-good-plugin@1.0.0'] };
  const report = checkCandidate({ spec: 'dsh-good-plugin@1.0.0', manifest: goodManifest, env });
  assert('known-bad=block', levelOf(report, 'known-bad') === 'block');
}

console.log('\n[8] 未声明 engines → 提醒但不拦截');
{
  const unknown = { ...goodManifest, engines: {} };
  const report = checkCandidate({ spec: 'dsh-u@1.0.0', manifest: unknown, env: baseEnv });
  assert('runtime-version=warn', levelOf(report, 'runtime-version') === 'warn');
  assert('整体仍 ok=true（warn 不阻止）', report.ok === true);
}

console.log('\n[9] peer 依赖版本偏差 → 提醒并列出明细');
{
  const peerBad = { ...goodManifest, peerDependencies: { '@deepseek-ai/cordis': '^4.0.0' } };
  const report = checkCandidate({ spec: 'dsh-p@1.0.0', manifest: peerBad, env: baseEnv });
  const check = report.checks.find((c) => c.id === 'peer-deps');
  assert('peer-deps=warn', check?.level === 'warn');
  assert('明细含当前版本', typeof check?.detail === 'string' && check.detail.includes('3.18.5'), check?.detail);
}

console.log('\n[10] spec 解析');
assert('名称+范围', JSON.stringify(parseInstallSpec('dsh-armory@2.4.3')) === JSON.stringify({ kind: 'registry', name: 'dsh-armory', range: '2.4.3' }));
assert('scoped 名称', parseInstallSpec('@scope/pkg@^1.2.0').name === '@scope/pkg');
assert('本地路径', parseInstallSpec(REPO_ROOT).kind === 'path', REPO_ROOT);

console.log('\n[11] 真实 registry 预检（只读 HTTP，网络抖动时显式 SKIP）');
{
  const resolved = await resolveManifest('dsh-armory@2.4.3', { attempts: 3, timeoutMs: 8000 });
  if (!resolved.manifest) {
    skips += 1;
    console.log(`  SKIP 网络不可达（reason=${resolved.reason}），本项不计入失败`);
  } else {
    assert('拿到 dsh-armory 的 manifest', true);
    const report = checkCandidate({ spec: 'dsh-armory@2.4.3', manifest: resolved.manifest, env: baseEnv });
    console.log('     -> ok=' + report.ok + ' blocked=' + report.blocked + ' warned=' + report.warned);
    for (const check of report.checks) console.log(`     [${check.level}] ${check.title}: ${check.detail ?? ''}`);
  }
}

console.log('\n[12] 不存在的包');
{
  const resolved = await resolveManifest('dsh-definitely-not-exists-zzz@1.0.0', { attempts: 2, timeoutMs: 8000 });
  if (resolved.manifest === undefined && resolved.reason === 'not-found') {
    assert('返回 not-found 而不是抛错', true);
  } else if (resolved.manifest === undefined) {
    skips += 1;
    console.log(`  SKIP 网络不可达（reason=${resolved.reason}）`);
  } else {
    assert('返回 not-found 而不是抛错', false, resolved.reason);
  }
}

console.log('\n==============================');
console.log(
  (failures === 0 ? 'ALL PASS' : `${failures} FAILURES`) + (skips > 0 ? ` （${skips} 项因网络不可达 SKIP）` : ''),
);
process.exit(failures === 0 ? 0 : 1);
