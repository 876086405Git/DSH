// 离线自检（对应 README 的「3. 离线自检」）：
// 在 vm 里 mock loader + react，加载 client.js 后手动 apply，提前发现
// 「declares dsh.client but exports no ./client」与「cannot get property X without inject」两类致命问题，
// 不用反复重启桌面端。
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const target = process.argv[2] || 'E:/kaifa/DSH-KAIFA/dsh-checkup';
const clientPath = `${target}/lib/client.js`;
const pkg = JSON.parse(readFileSync(`${target}/package.json`, 'utf8'));

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
};

console.log(`\n[1] package.json 声明（target: ${target}）`);
ok('name 存在', typeof pkg.name === 'string' && pkg.name.length > 0);
ok('main 指向 host 入口', typeof pkg.main === 'string' && pkg.main.length > 0);
if (pkg.dsh && pkg.dsh.client) {
  ok('dsh.client 存在 → 必须有 exports["./client"]', Boolean(pkg.exports && pkg.exports['./client']), pkg.exports);
  ok('exports["."] 存在（host 侧靠它被 import）', Boolean(pkg.exports && pkg.exports['.']), pkg.exports);
  ok('exports["./package.json"] 存在', Boolean(pkg.exports && pkg.exports['./package.json']), pkg.exports);
}

console.log('\n[2] client.js 运行时自检（vm + mock react）');
let entry;
const sandbox = {
  window: { __ModuleLoader__: { load: (e) => { entry = e; } } },
  console,
};
vm.createContext(sandbox);
vm.runInContext(readFileSync(clientPath, 'utf8'), sandbox);

ok('调用 __ModuleLoader__.load', Boolean(entry), entry && entry.id);
ok('loader id 与包名一致', entry && entry.id === pkg.name, entry && entry.id);

const reactMock = {
  createElement: () => null,
  useState: (value) => [typeof value === 'function' ? value() : value, () => {}],
  useEffect: () => {},
  useCallback: (fn) => fn,
  useMemo: (fn) => fn(),
  useRef: (value) => ({ current: value }),
};
const mod = entry.factory((spec) => {
  if (spec === 'react') return reactMock;
  throw new Error(`未预期的 require: ${spec}`);
});

const inject = Array.isArray(mod.inject) ? mod.inject : [];
const clientSource = readFileSync(clientPath, 'utf8');
const usedServices = new Set();
for (const match of clientSource.matchAll(/ctx\.(slots|sessions|locale|uiWorkspace|configForms)\b/g)) {
  usedServices.add(match[1]);
}
console.log('  inject =', JSON.stringify(inject), '| 用到 ctx.*:', [...usedServices].join(', ') || '(无)');

for (const service of usedServices) {
  ok(`inject 覆盖 "${service}"`, inject.includes(service), { inject, usedServices: [...usedServices] });
}

console.log('\n[3] apply 不抛（模拟宿主 slots 服务）');
const registered = [];
const ctxMock = {
  slots: {
    inject: (_name, factory) => { factory(); },
    register: (meta) => { registered.push(meta); return {}; },
  },
  effect: (fn) => { fn(); },
  inject: (_names, cb) => { cb(ctxMock); },
  logger: { info: () => {}, warn: () => {} },
};
try {
  mod.apply(ctxMock);
  ok('apply 未抛错', true);
  ok('注册了插件设置面板', registered.some((meta) => meta && meta.name === 'plugins.bundle.config'), registered);
  ok(
    '注册了全局检查浮层（shell.overlay）',
    registered.some((meta) => meta && meta.name === 'shell.overlay'),
    registered,
  );
  ok(
    '注册了落盘检查提示（checkup-sentinel-toast）',
    registered.some((meta) => meta && meta.name === 'shell.overlay' && meta.id === 'checkup-sentinel-toast'),
    registered.filter((meta) => meta && meta.name === 'shell.overlay'),
  );
  ok(
    '两个 shell.overlay 注册 id 不冲突',
    new Set(
      registered
        .filter((meta) => meta && meta.name === 'shell.overlay')
        .map((meta) => meta.id),
    ).size >= 2,
    registered.filter((meta) => meta && meta.name === 'shell.overlay'),
  );
  ok(
    '注册了插件详情页预检区（plugins.detail.section）',
    registered.some((meta) => meta && meta.name === 'plugins.detail.section'),
    registered,
  );
  ok(
    'detail.section 带 id（list 型槽必填，否则宿主静默丢弃）',
    registered.some(
      (meta) => meta && meta.name === 'plugins.detail.section' && typeof meta.id === 'string' && meta.id.length > 0,
    ),
    registered.filter((meta) => meta && meta.name === 'plugins.detail.section'),
  );
  ok(
    '注册了 bundle 行配置（plugins.row.config）',
    registered.some((meta) => meta && meta.name === 'plugins.row.config'),
    registered,
  );
  ok(
    '注册了设置入口（settings.section · 体检中心）',
    registered.some(
      (meta) =>
        meta &&
        meta.name === 'settings.section' &&
        typeof meta.id === 'string' &&
        meta.id.length > 0 &&
        typeof meta.label === 'function' &&
        meta.label() === '体检中心',
    ),
    registered.filter((meta) => meta && meta.name === 'settings.section'),
  );
  ok(
    '导航图标补丁已挂载（护盾 / 浏览器）',
    clientSource.includes('ctx.effect(() => patchSettingsNavIcons())') &&
      clientSource.includes('data-ed-nav-icon') &&
      clientSource.includes("'体检中心': [") &&
      clientSource.includes("'浏览器': ["),
  );
} catch (error) {
  ok('apply 未抛错', false, error.message);
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
