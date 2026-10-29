// Install Guard — 稳定性检查（运行稳定 / 潜在 bug 风险）
//
// 目标是"装上去别把桌面端拖坏"：入口声明是否完整、版本成熟度、依赖与体积负担、
// 维护信号是否齐全。全部是纯函数，便于单测。

const pass = (id, title, detail, category = 'stability') => ({ id, category, level: 'pass', title, detail });
const warn = (id, title, detail, hint, category = 'stability') => ({ id, category, level: 'warn', title, detail, hint });
const block = (id, title, detail, hint, category = 'stability') => ({ id, category, level: 'block', title, detail, hint });

const DEP_COUNT_SOFT_LIMIT = 60;
const PACKAGE_SIZE_SOFT_LIMIT = 30 * 1024 * 1024; // 30 MB

function sizeOf(manifest) {
  const dist = manifest && manifest.dist ? manifest.dist : undefined;
  const value = dist && (dist.unpackedSize ?? dist.size);
  return Number.isFinite(value) ? value : undefined;
}

function humanSize(bytes) {
  if (!Number.isFinite(bytes)) return '未知';
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${Math.round(bytes / 1024)} KB`;
}

export function checkStability({ manifest, env }) {
  const checks = [];
  if (!manifest || typeof manifest !== 'object') {
    checks.push(pass('st-manifest', '未取得包元数据', '无法判断入口声明与依赖负担，仅按安装结果观察。'));
    return checks;
  }

  const label = `${manifest.name || '?'}@${manifest.version || '?'}`;
  const client = manifest.dsh && manifest.dsh.client;
  const bundle = manifest.dsh && manifest.dsh.bundle;

  // 1) 入口声明完整性：dsh.client 存在却没有 exports["./client"]，宿主会直接启动失败
  const exportsField = manifest.exports;
  const hasClientExport = Boolean(exportsField && exportsField['./client']);
  const hasMainExport = Boolean(exportsField && exportsField['.']);
  const hasMain = Boolean(manifest.main);
  if (client) {
    if (!hasClientExport) {
      checks.push(
        block(
          'st-entrypoints',
          '声明了 dsh.client 但缺 exports["./client"]',
          `${label} 的 dsh.client 存在，package.json 却没有 "./client" 导出；宿主 client-modules 会抛错并中止启动`,
          '补 exports：{ ".": ..., "./client": ..., "./package.json": ... }',
        ),
      );
    } else if (!hasMain && !hasMainExport) {
      checks.push(
        block(
          'st-entrypoints',
          '缺少宿主入口声明',
          '既没有 main 也没有 exports["."]，宿主无法 import 该包（服务端侧启动失败）',
          '补 main 或 exports["."]。',
        ),
      );
    } else {
      checks.push(pass('st-entrypoints', '入口声明完整', `exports["./client"] 存在${bundle ? '，bundle patch 已声明' : ''}`));
    }
  } else if (!hasMain && !hasMainExport) {
    checks.push(
      warn(
        'st-entrypoints',
        '缺少入口声明',
        'package.json 没有 main / exports["."]，宿主可能无法加载',
        '确认作者是否使用了非标准入口。',
      ),
    );
  } else {
    checks.push(pass('st-entrypoints', '入口声明存在', hasMain ? `main: ${manifest.main}` : 'exports["."] 存在'));
  }

  // 2) 版本成熟度
  const version = String(manifest.version || '');
  const isPrerelease = /-(?:alpha|beta|rc|dev|canary|next|snapshot)/i.test(version);
  const isZeroZero = /^0\.0\./.test(version);
  if (isPrerelease || isZeroZero) {
    checks.push(
      warn(
        'st-version',
        '版本成熟度偏低',
        `${label} 属于 ${isPrerelease ? '预发布版本' : '0.0.x 早期版本'}，接口与行为可能随时变化`,
        '生产使用建议换稳定版本。',
      ),
    );
  } else {
    checks.push(pass('st-version', '版本号稳定', version || '未声明'));
  }

  // 3) 依赖负担
  const deps = Object.keys(manifest.dependencies || {});
  if (deps.length > DEP_COUNT_SOFT_LIMIT) {
    checks.push(
      warn(
        'st-deps-weight',
        '依赖数量偏多',
        `${deps.length} 个运行时依赖（软上限 ${DEP_COUNT_SOFT_LIMIT}），安装耗时与冲突面都会变大`,
        '确认这些依赖是否都必要。',
      ),
    );
  } else {
    checks.push(pass('st-deps-weight', '依赖数量可控', `${deps.length} 个运行时依赖`));
  }

  // 4) 包体积
  const size = sizeOf(manifest);
  if (Number.isFinite(size) && size > PACKAGE_SIZE_SOFT_LIMIT) {
    checks.push(
      warn(
        'st-package-size',
        '包体积偏大',
        `${humanSize(size)}（软上限 ${humanSize(PACKAGE_SIZE_SOFT_LIMIT)}），下载与解包更容易失败`,
        '网络不稳时先在市场外下载再本地安装。',
      ),
    );
  } else if (Number.isFinite(size)) {
    checks.push(pass('st-package-size', '包体积正常', humanSize(size)));
  } else {
    checks.push(pass('st-package-size', '包体积未知', '注册表未提供体积信息，跳过该检查'));
  }

  // 5) 维护与合规信号
  const missing = [];
  if (!manifest.license) missing.push('license');
  if (!manifest.repository) missing.push('repository');
  const hasTest = Boolean(manifest.scripts && manifest.scripts.test);
  if (missing.length > 0) {
    checks.push(
      warn(
        'st-maintenance',
        '维护信息不完整',
        `缺少 ${missing.join(' / ')}${hasTest ? '（有 test 脚本）' : '（也没有 test 脚本）'}`,
        '缺少这些字段的插件通常缺少持续维护，出问题难以及时修复。',
      ),
    );
  } else {
    checks.push(pass('st-maintenance', '维护信息完整', `license + repository${hasTest ? ' + test' : ''}`));
  }

  // 6) 运行环境声明（稳定性：与宿主 Node 版本不匹配的常见崩溃源）
  const nodeRange = manifest.engines && manifest.engines.node;
  if (!nodeRange) {
    checks.push(
      warn(
        'st-engine-declared',
        '未声明 Node 版本范围',
        'engines.node 缺失，无法在装前判断与宿主内置 Node 是否匹配',
        '可让作者补 engines.node。',
      ),
    );
  } else {
    checks.push(pass('st-engine-declared', '已声明 Node 版本范围', nodeRange));
  }

  return checks;
}
