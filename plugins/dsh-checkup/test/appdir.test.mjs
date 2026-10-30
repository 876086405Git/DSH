// 0.5.1：宿主 app 目录定位（三种安装形态都要认）
//
// 反向插桩：删掉 lib/index.js 里 `app.asar.unpacked` 那两行候选后，本文件 [C][D]
// 会立刻打红 —— 证明这两条断言确实绑在实现上，不是空转。
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resourcesAppDir } from '../lib/index.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra === undefined ? '' : ' -> ' + JSON.stringify(extra)}`);
  }
};

const root = mkdtempSync(join(tmpdir(), 'checkup-appdir-'));
const resources = join(root, 'resources');
mkdirSync(resources, { recursive: true });

const makeApp = (dir, version) => {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'dsh-app', version }), 'utf8');
};

// ── [A] 未打包形态 ────────────────────────────────────────────────────────
console.log('\n[A] <resources>/app');
{
  makeApp(join(resources, 'app'), '0.2.0');
  ok('命中 app 目录', resourcesAppDir([resources]) === join(resources, 'app'), resourcesAppDir([resources]));
}

// ── [B] 打包形态（0.2.1-rc.5 起的真实形态）───────────────────────────────
console.log('\n[B] <resources>/app.asar');
{
  // 普通 Node 下 app.asar 就是个目录名，用来模拟 Electron 里透明挂载的效果
  makeApp(join(resources, 'app.asar'), '0.2.1-rc.5');
  ok('app 与 app.asar 同时存在时优先 app', resourcesAppDir([resources]) === join(resources, 'app'));

  rmSync(join(resources, 'app'), { recursive: true, force: true });
  ok('只有 app.asar 时命中它', resourcesAppDir([resources]) === join(resources, 'app.asar'), resourcesAppDir([resources]));
}

// ── [C] 只解包形态：app.asar.unpacked/dsh ────────────────────────────────
console.log('\n[C] <resources>/app.asar.unpacked/dsh（防御性候选）');
{
  rmSync(join(resources, 'app.asar'), { recursive: true, force: true });
  makeApp(join(resources, 'app.asar.unpacked', 'dsh'), '0.2.2-future');
  ok('命中 app.asar.unpacked/dsh', resourcesAppDir([resources]) === join(resources, 'app.asar.unpacked', 'dsh'), resourcesAppDir([resources]));
}

// ── [D] 解包根目录形态：app.asar.unpacked 自己带 package.json ────────────
console.log('\n[D] <resources>/app.asar.unpacked（兜底）');
{
  rmSync(join(resources, 'app.asar.unpacked', 'dsh'), { recursive: true, force: true });
  makeApp(join(resources, 'app.asar.unpacked'), '0.2.3-future');
  ok('命中 app.asar.unpacked 根', resourcesAppDir([resources]) === join(resources, 'app.asar.unpacked'), resourcesAppDir([resources]));
}

// ── [E] 顺序：完整 asar 比「部分解包」权威 ───────────────────────────────
console.log('\n[E] 优先级');
{
  makeApp(join(resources, 'app.asar'), '0.2.1-rc.5');
  ok('app.asar 优先于 app.asar.unpacked', resourcesAppDir([resources]) === join(resources, 'app.asar'));
  rmSync(join(resources, 'app.asar'), { recursive: true, force: true });
}

// ── [F] 都没有 → undefined（不能瞎猜一个路径）────────────────────────────
console.log('\n[F] 空目录');
{
  const empty = mkdtempSync(join(tmpdir(), 'checkup-empty-'));
  ok('没有任何 app 目录时返回 undefined', resourcesAppDir([empty]) === undefined, resourcesAppDir([empty]));
  rmSync(empty, { recursive: true, force: true });
}

rmSync(root, { recursive: true, force: true });

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
