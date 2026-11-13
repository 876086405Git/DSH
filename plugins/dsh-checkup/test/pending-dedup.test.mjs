// 0.6.1 挂起去重回归：同一 spec 重复触发 installBundle 时，旧挂起必须先作废。
//
// 背景 bug：市场重试/重复触发 installBundle 时，createPending 不按 spec 去重，
// 会累积多个 pending 和多个 180s 定时器；旧定时器稍后 fire 反复抛「已拦截」，
// 叠加浮层从不清除过期状态，表现为「反复提示超时 + 点了安装/取消仍循环」。
//
// 反向插桩：删掉 createPending 开头那段按 spec 去重的循环，[B] 的
// 「第一次 promise 被取代」立刻打红。
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const home = mkdtempSync(join(tmpdir(), 'checkup-dedup-'));
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

// 检查必不通过的本地路径（没有 package.json → manifest-unavailable block）。
const blockedSpec = join(tmpdir(), 'checkup-dedup-nonexistent-spec');

const routes = new Map();
const managerRef = { installBundle: () => ({ status: 'accepted' }) };
const mkCtx = (extra) => ({ effect: () => {}, ...extra });
const ctx = {
  logger: { info: () => {}, warn: () => {}, error: () => {} },
  inject: (services, cb) => {
    if (services.includes('pluginManager')) cb(mkCtx({ pluginManager: managerRef }));
    if (services.includes('webServer')) cb(mkCtx({ webServer: { register: (route) => routes.set(route.path, route) } }));
  },
  effect: () => {},
};
apply(ctx, {});

async function callRoute(path, body) {
  const route = routes.get(path);
  if (!route) throw new Error(`路由未注册：${path}`);
  const json = JSON.stringify(body || {});
  const req = { headers: {}, [Symbol.asyncIterator]: async function* () { yield json; } };
  let status = 0;
  let payload;
  const res = { writeHead: (s) => { status = s; }, end: (t) => { payload = JSON.parse(t); } };
  await route.handler(req, res);
  return { status, payload };
}

const tick = (ms = 90) => new Promise((r) => setTimeout(r, ms));

// 记录每次 installBundle promise 的落定情况
function track(promise) {
  const state = { settled: false, resolved: false, rejected: false, error: null };
  promise.then(
    () => { state.settled = true; state.resolved = true; },
    (e) => { state.settled = true; state.rejected = true; state.error = e; },
  );
  return state;
}

// ── [A] 第一次 installBundle → 创建挂起 ────────────────────────────────────
console.log('\n[A] 第一次 installBundle 创建挂起');
const p1State = track(managerRef.installBundle(blockedSpec));
await tick();
const first = await callRoute('/api-checkup/pending', {});
ok('存在挂起', first.payload.pending !== null, first.payload);
const idA = first.payload.pending && first.payload.pending.id;
ok('第一次 promise 尚未落定（仍在等确认）', p1State.settled === false, p1State);

// ── [B] 同 spec 第二次 → 旧挂起被取代（核心修复）──────────────────────────
console.log('\n[B] 同 spec 第二次触发 → 旧挂起被取代');
const p2State = track(managerRef.installBundle(blockedSpec));
await tick();
ok('第一次 promise 已被取代（rejected）', p1State.rejected === true, { settled: p1State.settled, rejected: p1State.rejected });
ok('取代消息写明被新请求取代', p1State.error && /取代/.test(String(p1State.error.message)), p1State.error && p1State.error.message);
const second = await callRoute('/api-checkup/pending', {});
ok('仍有挂起（新的）', second.payload.pending !== null, second.payload);
const idB = second.payload.pending && second.payload.pending.id;
ok('挂起 id 已换成新的（≠ 旧 A）', Boolean(idA) && Boolean(idB) && idA !== idB, { idA, idB });

// ── [C] 新挂起仍然有效（没被误取消）───────────────────────────────────────
console.log('\n[C] 新挂起未被误取消');
ok('第二次 promise 仍未落定（等确认）', p2State.settled === false, p2State);

// ── [D] 取消新挂起后，浮层能拿到「无挂起」（轮询据此清过期状态）─────────────
console.log('\n[D] 取消后 pending 归零');
{
  const cancel = await callRoute('/api-checkup/confirm', { id: idB, action: 'cancel' });
  ok('cancel 返回 200', cancel.status === 200, cancel);
  const after = await callRoute('/api-checkup/pending', {});
  ok('pending 归零（浮轮询会清掉过期状态）', after.payload.pending === null, after.payload);
}

rmSync(home, { recursive: true, force: true });

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
