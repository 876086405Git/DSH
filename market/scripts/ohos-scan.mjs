// Static screening only. No package module or lifecycle script is executed.
import { createHash } from 'node:crypto';

export const OHOS_SCANNER = 'dsh-go-ohos-static/1';
const labels = { usable: '可用', partial: '部分可用', unavailable: '不可用' };
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
const nativeSuffix = /\.(?:node|exe|dll|dylib|a|o)$|\.so(?:\.\d+)*$/i;
const wasmMagic = Buffer.from([0, 97, 115, 109]);
const nativeMagic = new Set(['7f454c46', 'feedface', 'feedfacf', 'cefaedfe', 'cffaedfe', 'cafebabe']);
const meanings = {
  'native-code': '包含原生二进制或本机编译输入；普通插件不能加载未随 HAP 白名单发布的原生模块。',
  'native-loader': '源码引用原生加载入口；需核对实际调用路径与 HAP 原生库白名单。',
  'child-process': '源码引用 child_process 或进程执行依赖；鸿蒙本机不能执行外部程序。',
  wasm: '包含 Wasm 字节或 WebAssembly 引用；当前鸿蒙运行时没有可用的 Wasm 执行通道。',
  bin: '声明 npm 命令入口；CLI 功能不能通过外部进程启动，不能据此推断包内 API 也失效。',
  'install-script': '包含安装生命周期脚本或隐式 node-gyp 构建；应用内不执行安装脚本。',
  'platform-excluded': 'package.json 的 os/cpu 条件排除了 openharmony/arm64。',
  'invalid-platform-declaration': 'os/cpu 声明格式无效，不能推断目标平台支持。',
  'binary-main': '包的唯一 main 为原生或 Wasm 文件，没有 exports 或 DSH bundle 替代入口。',
  'unresolved-dependencies': '未扫描全部必需依赖；单包结果不能证明依赖闭包在鸿蒙可运行。',
  'optional-dependencies': '存在未纳入必需闭包的可选依赖；相关功能仍需单独核实。',
  'dependency-findings': '固定依赖闭包中仍有静态风险或未覆盖的包；详情见依赖扫描结果。',
};

function excluded(values, target) {
  const entries = typeof values === 'string' ? [values] : values;
  if (!Array.isArray(entries) || entries.some(value => typeof value !== 'string')) return false;
  if (entries.length === 1 && entries[0] === 'any') return false;
  const positive = entries.filter(value => !value.startsWith('!'));
  return entries.includes('!' + target) || (positive.length > 0 && !positive.includes(target));
}

export function runtimeDependencies(pkg) {
  const rows = new Map();
  for (const [name, range] of Object.entries(pkg.dependencies ?? {})) rows.set(name, { name, range, kind: 'dependency' });
  // Optional entries override matching dependencies; a separately mandatory
  // peer remains a required part of the host contract.
  for (const name of Object.keys(pkg.optionalDependencies ?? {})) rows.delete(name);
  for (const [name, range] of Object.entries(pkg.peerDependencies ?? {})) {
    if (!pkg.peerDependenciesMeta?.[name]?.optional && !rows.has(name)) rows.set(name, { name, range, kind: 'peer' });
  }
  return [...rows.values()].sort((a, b) => compare(a.name, b.name));
}

export function scanOhos(files, pkg) {
  const evidence = new Map();
  const fileRows = [...files].sort(([a], [b]) => compare(a, b)).map(([path, bytes]) => ({
    path, bytes: bytes.length, sha256: sha256(bytes),
  }));
  const hashes = new Map(fileRows.map(row => [row.path, row.sha256]));
  const add = (code, path, detail, line) => {
    const rows = evidence.get(code) ?? [];
    if (rows.length < 12 && !rows.some(row => row.path === path && row.detail === detail)) {
      rows.push({ path, ...(line ? { line } : {}), ...(hashes.has(path) ? { sha256: hashes.get(path) } : {}), detail });
    }
    evidence.set(code, rows);
  };
  for (const key of ['os', 'cpu']) {
    const value = pkg[key];
    if (value !== undefined && typeof value !== 'string' &&
        (!Array.isArray(value) || value.some(entry => typeof entry !== 'string'))) {
      add('invalid-platform-declaration', 'package.json', key);
    }
  }
  if (excluded(pkg.os, 'openharmony') || excluded(pkg.cpu, 'arm64')) {
    add('platform-excluded', 'package.json', JSON.stringify({ os: pkg.os, cpu: pkg.cpu }));
  }
  if (typeof pkg.main === 'string' && !pkg.exports && !pkg.dsh?.bundle &&
      (nativeSuffix.test(pkg.main) || /\.wasm$/i.test(pkg.main))) {
    add('binary-main', 'package.json', pkg.main);
  }
  if (typeof pkg.bin === 'string' && pkg.bin) add('bin', 'package.json', pkg.bin);
  if (pkg.bin && typeof pkg.bin === 'object' && !Array.isArray(pkg.bin)) {
    for (const [name, path] of Object.entries(pkg.bin).sort(([a], [b]) => compare(a, b))) {
      if (typeof path === 'string' && path) add('bin', 'package.json', name + ': ' + path);
    }
  }
  for (const key of ['preinstall', 'install', 'postinstall']) {
    if (typeof pkg.scripts?.[key] === 'string' && pkg.scripts[key].trim()) {
      // Commands are code, not instructions to this scanner. Never execute them.
      add('install-script', 'package.json', key);
    }
  }
  if (files.has('binding.gyp') && pkg.gypfile !== false && !pkg.scripts?.install && !pkg.scripts?.preinstall) {
    add('install-script', 'binding.gyp', 'implicit node-gyp rebuild');
  }
  for (const [path, bytes] of files) {
    if (nativeSuffix.test(path) || /(?:^|\/)binding\.gyp$/i.test(path) ||
        nativeMagic.has(bytes.subarray(0, 4).toString('hex')) || bytes.subarray(0, 2).toString() === 'MZ') {
      add('native-code', path, 'file extension, executable magic, or binding.gyp');
    }
    if (/\.wasm$/i.test(path) || bytes.subarray(0, 4).equals(wasmMagic)) add('wasm', path, 'Wasm file');
    if (!/\.(?:[cm]?js|jsx|tsx?|sh)$/i.test(path) || /\.d\.[cm]?ts$/i.test(path)) continue;
    const source = bytes.toString('utf8');
    // These are references, not a reachability proof. Comments/string literals
    // may produce conservative findings; indirect/computed calls can be missed.
    const patterns = [
      ['child-process', /\b(?:from\s*|import\s*\(?\s*|require\s*\(\s*)['"](?:node:)?child_process['"]|\b(?:child_process|process)\s*\.\s*(?:spawn|exec|execFile|fork)\s*\(/g],
      ['native-loader', /\bprocess\s*\.\s*dlopen\s*\(|\b(?:from\s*|import\s*\(?\s*|require\s*\(\s*)['"](?:bindings|node-gyp-build|@mapbox\/node-pre-gyp|ffi-napi)['"]/g],
      ['wasm', /\bWebAssembly\b/g],
    ];
    for (const [code, pattern] of patterns) {
      const match = pattern.exec(source);
      if (match) add(code, path, 'source reference (not execution proof)', source.slice(0, match.index).split('\n').length);
    }
    if (/\.sh$/i.test(path)) add('child-process', path, 'shell script file');
  }
  for (const key of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const name of Object.keys(pkg[key] ?? {})) {
      if (['execa', 'cross-spawn', 'shelljs', 'node-pty'].includes(name)) add('child-process', 'package.json', key + ': ' + name);
      if (['bindings', 'node-gyp-build', 'node-pre-gyp', '@mapbox/node-pre-gyp', 'ffi-napi'].includes(name)) {
        add('native-loader', 'package.json', key + ': ' + name);
      }
    }
  }
  const required = runtimeDependencies(pkg);
  const optional = Object.keys(pkg.optionalDependencies ?? {}).sort();
  if (optional.length) add('optional-dependencies', 'package.json', optional.join(', '));
  const ownStatus = evidence.has('platform-excluded') || evidence.has('binary-main') ? 'unavailable' : evidence.size ? 'partial' : 'usable';
  if (required.length) add('unresolved-dependencies', 'package.json', required.map(row => row.name).join(', '));
  const status = ownStatus === 'unavailable' ? ownStatus : evidence.size ? 'partial' : 'usable';
  return {
    schema: 1, scanner: OHOS_SCANNER, name: pkg.name ?? null, version: pkg.version ?? null,
    status, label: labels[status], ownStatus,
    scope: 'static-package-only', deviceValidated: false,
    target: { platform: 'openharmony', arch: 'arm64', node: '24.22.1', jit: false, wasm: false, externalProcesses: false },
    provisioning: 'prebundled-only; in-app package installation is unavailable',
    meaning: '可用表示所扫描范围未发现本扫描器覆盖的阻断；不是运行证明。部分可用表示功能限制或证据不足，不保证存在可运行子集。',
    reasons: [...evidence].sort(([a], [b]) => compare(a, b)).map(([code, locations]) => ({ code, message: meanings[code], evidence: locations })),
    dependencies: { coverage: 'not-traversed', required, optional },
    source: { files: files.size, bytes: fileRows.reduce((n, row) => n + row.bytes, 0), sha256: sha256(JSON.stringify(fileRows)) },
  };
}

// A caller that scanned a fixed installed graph may close the dependency scope.
// Reachability is intentionally not inferred from a package manifest.
export function withDependencyCoverage(report, { missing = [], findings = [], packages = 0, lockSha256 }) {
  const reasons = report.reasons.filter(row => row.code !== 'unresolved-dependencies');
  if (missing.length) reasons.push({ code: 'unresolved-dependencies', message: meanings['unresolved-dependencies'], evidence: missing });
  if (findings.length) reasons.push({ code: 'dependency-findings', message: meanings['dependency-findings'], evidence: findings });
  const status = report.ownStatus === 'unavailable' ? 'unavailable' : reasons.length ? 'partial' : 'usable';
  return { ...report, status, label: labels[status], scope: 'static-installed-required-dependency-closure', reasons,
    dependencies: { ...report.dependencies, coverage: missing.length ? 'incomplete' : 'complete', packages, ...(lockSha256 ? { lockSha256 } : {}) } };
}

export function ohosSummary(report) {
  if (report?.scanner !== OHOS_SCANNER || !Object.hasOwn(labels, report.status)) throw new Error('missing-ohos-scan');
  return { status: report.status, label: report.label, scope: report.scope, scanner: report.scanner,
    deviceValidated: false, sourceSha256: report.source.sha256,
    reasons: report.reasons.map(({ code, message }) => ({ code, message })),
    note: report.meaning, provisioning: report.provisioning };
}

export function applyOhosData(sidecar, data) {
  if (sidecar?.schema !== 1 || !sidecar.plugins || typeof sidecar.plugins !== 'object' || Array.isArray(sidecar.plugins) ||
      data?.schema !== 1 || !Array.isArray(data.packages)) throw new Error('invalid-ohos-data');
  const result = structuredClone(sidecar);
  const seen = new Set();
  for (const row of data.packages) {
    const target = Object.hasOwn(result.plugins, row.name) ? result.plugins[row.name] : undefined;
    if (typeof row.name !== 'string' || !/^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/.test(row.name) ||
        typeof row.version !== 'string' || typeof row.integrity !== 'string' ||
        seen.has(row.name) || !target || target.version !== row.version || target.integrity !== row.integrity ||
        row.platforms?.ohos?.name !== row.name || row.platforms?.ohos?.version !== row.version) {
      throw new Error('ohos-data-identity-mismatch:' + row.name);
    }
    seen.add(row.name);
    target.platforms = { ...target.platforms, ohos: ohosSummary(row.platforms.ohos) };
  }
  return result;
}
