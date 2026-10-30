// 0.6.0 强制安装回归：设置面板手动预检的「强制安装」后端旁路。
//
// 反向插桩：把 /api-checkup/install 里的 `if (!report.ok && !force)` 改回
// `if (!report.ok)`，[C] 立刻打红 —— 证明断言绑在实现上，不是空转。
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// HOME 必须在 import lib/index.js 之前设好：模块加载时就用它拼路径。
const home = mkdtempSync(join(tmpdir(), 'checkup-force-'));
process.env.DSH_HOME = join(home, '.dsh');

const { apply } = await import('../lib/index.js');

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra === undefined ? '' : ' -> ' + JSON.stringify(extra)}`);
  }
};

// 造一个「检查必不通过」的安装目标：本地路径里没有 package.json。
const blockedSpec = join(tmpdir(), 'checkup-force-nonexistent-spec');

// 把注册好的路由拿出来，用最简 req / res 调用它。
const routes = new Map();
let installCalls = 0;
const installSpy = () => {
  installCalls += 1;
  return { status: 'accepted' };
};
const mkCtx = (extra) => ({ effect: () => {}, ...extra });
const ctx = {
  logger: { info: () => {}, warn: () => {}, error: () => {} },
  inject: (services, cb) => {
    if (services.includes('pluginManager')) {
      cb(mkCtx({ pluginManager: { installBundle: installSpy } }));
    }
    if (services.includes('webServer')) {
      cb(mkCtx({ webServer: { register: (route) => routes.set(route.path, route) } }));
    }
  },
  effect: () => {},
};
apply(ctx, {});

async function callRoute(path, body) {
  const route = routes.get(path);
  if (!route) throw new Error(`路由未注册：${path}`);
  const json = JSON.stringify(body || {});
  const req = {
    headers: {},
    [Symbol.asyncIterator]: async function* () {
      yield json;
    },
  };
  let status = 0;
  let payload;
  const res = {
    writeHead: (s) => {
      status = s;
    },
    end: (text) => {
      payload = JSON.parse(text);
    },
  };
  await route.handler(req, res);
  return { status, payload };
}

// ── [A] /check 在检查未通过时也发一次性 token ──────────────────────────────
console.log('\n[A] /api-checkup/check 对未通过的检查也发 token');
{
  const check = await callRoute('/api-checkup/check', { spec: blockedSpec });
  ok('检查返回 200', check.status === 200, check);
  ok('报告 ok=false（该路径没有 package.json）', check.payload.report.ok === false, check.payload.report.blocked);
  ok('仍然返回一次性 token', typeof check.payload.approvalToken === 'string' && check.payload.approvalToken.length > 0, check.payload.approvalToken);
}

// ── [B] 不带 force：安装被阻止 ────────────────────────────────────────────
console.log('\n[B] install 不带 force → 409 阻止');
{
  installCalls = 0;
  const { payload: ck } = await callRoute('/api-checkup/check', { spec: blockedSpec });
  const r = await callRoute('/api-checkup/install', { spec: blockedSpec, token: ck.approvalToken });
  ok('返回 409', r.status === 409, r.status);
  ok('ok=false', r.payload.ok === false);
  ok('blocked=true', r.payload.blocked === true);
  ok('没有执行安装', installCalls === 0, installCalls);
}

// ── [C] 带 force + 有效 token：安装执行 ───────────────────────────────────
console.log('\n[C] install 带 force + 有效 token → 执行安装');
{
  installCalls = 0;
  const { payload: ck } = await callRoute('/api-checkup/check', { spec: blockedSpec });
  const r = await callRoute('/api-checkup/install', { spec: blockedSpec, token: ck.approvalToken, force: true });
  ok('返回 200', r.status === 200, r);
  ok('ok=true', r.payload.ok === true, r.payload.error);
  ok('执行了安装（installBundle 被调用）', installCalls === 1, installCalls);
}

// ── [D] 带 force 但 token 无效：仍被拒（token 不能绕过）──────────────────
console.log('\n[D] install 带 force + 无效 token → 409（必须先检查过）');
{
  installCalls = 0;
  const r = await callRoute('/api-checkup/install', { spec: blockedSpec, token: 'bogus-token', force: true });
  ok('返回 409', r.status === 409, r.status);
  ok('stale=true（token 不新鲜）', r.payload.stale === true, r.payload);
  ok('没有执行安装', installCalls === 0, installCalls);
}

rmSync(home, { recursive: true, force: true });

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
