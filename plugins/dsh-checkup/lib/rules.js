// Install Guard — 预检规则内核（纯函数：不碰 fs / 网络，便于单测与反向验证）
//
// 三类检查：
//   compatibility —— 能不能在这个 DSH 版本上跑起来
//   security      —— 会不会泄露隐私 / 带恶意或病毒代码（见 security.js）
//   stability     —— 装上去稳不稳、有没有潜在 bug 风险（见 stability.js）
//
// 每条检查：{ id, category, level, title, detail, hint }
//   level = 'block'  -> 立即阻止安装（弹窗列出原因）
//           'warn'   -> 允许安装，但明确告知风险
//           'pass'   -> 通过项（面板里折叠展示）

import { satisfies, parseVersion, compareVersions } from './version.js';
import { checkSecurity } from './security.js';
import { checkStability } from './stability.js';

export const CATEGORIES = [
  { id: 'compatibility', label: '兼容性', desc: '能否在当前 DSH 客户端环境正确加载与运行' },
  { id: 'security', label: '安全性', desc: '隐私泄露 / 恶意代码 / 病毒代码风险' },
  { id: 'stability', label: '稳定性', desc: '运行是否稳定，是否存在潜在 bug 与维护风险' },
];

export const RULE_IDS = [
  // 兼容性
  'spec',
  'runtime-version',
  'node-engine',
  'client-platform',
  'client-inject',
  'bundle-declared',
  'peer-deps',
  'known-bad',
  'duplicate',
  'bundle-load',
  // 交叉比对（候选 vs 已装）：插件、连接器、技能、专家各一组
  'dup-plugin-version',
  'conflict-deps',
  'dup-connector-name',
  'conflict-connector-tool',
  'dup-skill-content',
  'cand-expert-shape',
  'cand-expert-dup',
  'cand-expert-refs',
  // 安全性
  'sec-manifest',
  'sec-scripts',
  'sec-deps',
  'sec-typosquat',
  'sec-source',
  'sec-traceability',
  // 稳定性
  'st-manifest',
  'st-entrypoints',
  'st-version',
  'st-deps-weight',
  'st-package-size',
  'st-maintenance',
  'st-engine-declared',
];

const CATEGORY = 'compatibility';
const pass = (id, title, detail) => ({ id, category: CATEGORY, level: 'pass', title, detail });
const warn = (id, title, detail, hint) => ({ id, category: CATEGORY, level: 'warn', title, detail, hint });
const block = (id, title, detail, hint) => ({ id, category: CATEGORY, level: 'block', title, detail, hint });

/// 每条检查允许用户单独指定处理方式：'block' | 'warn' | 'pass'。
/** 三档之外的值一律忽略 —— 配置写错时退回规则自身的判定，而不是猜一个。 */
export const LEVEL_CHOICES = ['block', 'warn', 'pass'];

/**
 * 按用户的逐项设置覆盖 level。
 *
 * 只改 level，不动 title/detail/hint：用户改的是「怎么处理」，不是「结论是什么」。
 * 被覆盖的条目会带上 overridden 与 originalLevel，界面据此标注「已自定义」。
 */
export function applyLevelOverrides(checks, levelOverrides) {
  if (!levelOverrides || typeof levelOverrides !== 'object') return checks;
  for (const check of checks) {
    const forced = levelOverrides[check.id];
    if (!LEVEL_CHOICES.includes(forced)) continue;
    if (check.level === forced) continue;
    check.originalLevel = check.level;
    check.level = forced;
    check.overridden = true;
  }
  return checks;
}

/// 把一个检查列表收敛成结论：任何 block 即失败；同时按三类统计。
export function summarize(checks) {
  const blocked = checks.filter((c) => c.level === 'block');
  const warned = checks.filter((c) => c.level === 'warn');
  const byCategory = {};
  for (const category of CATEGORIES) {
    const rows = checks.filter((c) => (c.category || CATEGORY) === category.id);
    byCategory[category.id] = {
      total: rows.length,
      blocked: rows.filter((c) => c.level === 'block').length,
      warned: rows.filter((c) => c.level === 'warn').length,
      passed: rows.filter((c) => c.level === 'pass').length,
    };
  }
  return {
    ok: blocked.length === 0,
    blocked: blocked.length,
    warned: warned.length,
    passed: checks.filter((c) => c.level === 'pass').length,
    byCategory,
    checks,
  };
}

/// 从 manifest / 安装目标里取出「这个包声明支持的 DSH 版本」。
export function declaredDshRange(manifest) {
  const candidates = [
    manifest?.dsh?.engines?.dsh,
    manifest?.engines?.dsh,
    manifest?.dsh?.version,
  ];
  return candidates.find((value) => typeof value === 'string' && value.trim()) || undefined;
}

export function declaredNodeRange(manifest) {
  return typeof manifest?.engines?.node === 'string' ? manifest.engines.node : undefined;
}

/// 主检查入口。
export function checkCandidate(input) {
  const { spec, manifest, env, levelOverrides } = input || {};
  const checks = [];
  const manifestName = manifest?.name;

  // 1. spec 形态
  if (typeof spec !== 'string' || !spec.trim()) {
    checks.push(block('spec', '安装目标为空', '没有提供要安装的包名或路径。'));
    return summarize(applyLevelOverrides(checks, levelOverrides));
  }
  checks.push(pass('spec', '安装目标可解析', spec.trim()));

  if (!manifest || typeof manifest !== 'object') {
    checks.push(
      warn(
        'spec',
        '未取得包元数据',
        '注册表或本地路径没有返回 package.json，只能做安装后检查。',
        '确认网络/镜像可用，或改用本地路径安装。',
      ),
    );
    return summarize(applyLevelOverrides(checks, levelOverrides));
  }

  const label = manifestName ? `${manifestName}@${manifest.version || '?'}` : spec.trim();

  // 2. 客户端版本兼容（本插件的核心诉求）
  const dshRange = declaredDshRange(manifest);
  if (dshRange) {
    // 宿主版本读不到（打包版 app.asar、探测失败）时不能判「不兼容」：
    // 「没读到」不等于「不满足」，据此拒绝安装会把所有插件都挡在门外。
    if (env.dshVersionKnown === false) {
      checks.push(
        warn(
          'runtime-version',
          '无法核对 DSH 版本',
          ` ${label} 声明 dsh ${dshRange}，但没读到宿主版本，跳过该项`,
          '确认桌面端版本后再判断，或先装后观察启动是否正常。',
        ),
      );
    } else if (satisfies(env.dshVersion, dshRange)) {
      checks.push(pass('runtime-version', '兼容当前 DeepSeek Harness', `${label} 声明 dsh ${dshRange}，当前 ${env.dshVersion}`));
    } else {
      checks.push(
        block(
          'runtime-version',
          '与当前 DeepSeek Harness 版本不兼容',
          `${label} 要求 dsh ${dshRange}，当前运行 ${env.dshVersion}`,
          '升级/降级该插件到适配版本，或换用继续维护的分支。',
        ),
      );
    }
  } else {
    checks.push(
      warn(
        'runtime-version',
        '插件未声明 DSH 版本范围',
        `${label} 的 package.json 里没有 dsh.engines.dsh / engines.dsh 字段，无法在装前判定版本兼容。`,
        '安装后若启动异常，优先怀疑该插件未适配当前版本。',
      ),
    );
  }

  // 3. Node 运行时要求
  const nodeRange = declaredNodeRange(manifest);
  if (nodeRange) {
    if (satisfies(env.nodeVersion, nodeRange)) {
      checks.push(pass('node-engine', 'Node 运行时满足要求', `声明 node ${nodeRange}，当前 ${env.nodeVersion}`));
    } else {
      checks.push(
        warn(
          'node-engine',
          'Node 运行时低于插件要求',
          `${label} 要求 node ${nodeRange}，当前 ${env.nodeVersion}`,
          '桌面端内置 Node 由 DSH 管理，升级 DSH 才可能满足。',
        ),
      );
    }
  }

  // 4. 客户端平台
  const client = manifest.dsh?.client;
  if (client) {
    const platform = client.platform;
    if (platform === undefined || platform === 'web') {
      checks.push(pass('client-platform', '客户端平台匹配', `platform=${platform ?? 'web(默认)'}`));
    } else {
      checks.push(
        block(
          'client-platform',
          '客户端平台不匹配',
          `${label} 声明 platform=${String(platform)}，桌面端只加载 web 平台，装上去不会显示甚至导致启动异常。`,
          '换用 web 平台版本。',
        ),
      );
    }
  }

  // 5. 客户端注入依赖（DSH boot 失败的高发原因）
  const injects = Array.isArray(client?.inject) ? client.inject : [];
  if (injects.length > 0) {
    const available = new Set(env.availableClientPackages || []);
    // 空集不代表「全缺」：打包版把宿主封在 app.asar 里，读不到包列表时只能算「无法核对」。
    if (available.size === 0) {
      checks.push(
        warn(
          'client-inject',
          '无法核对客户端注入依赖',
          `没有读到宿主内置包列表，${injects.length} 个注入依赖未核对`,
          '确认桌面端能正常加载插件后再装。',
        ),
      );
    } else {
      const missing = injects.filter((entry) => !available.has(entry));
      if (missing.length === 0) {
        checks.push(pass('client-inject', '客户端注入依赖齐全', injects.join(', ')));
      } else {
        checks.push(
          block(
            'client-inject',
            '客户端注入依赖在当前版本不存在',
            `缺少：${missing.join(', ')}（这些包在当前 DSH 版本里没有，加载时会 boot 失败并触发桌面端重启）`,
            '安装适配当前 DSH 版本的插件版本，或联系作者移除对该包的依赖。',
          ),
        );
      }
    }
  }

  // 6. bundle patch 声明
  const bundle = manifest.dsh?.bundle;
  if (bundle === undefined) {
    checks.push(
      pass(
        'bundle-declared',
        '非 bundle 插件',
        '该包只注册插件条目，不注入 profile patch（风险面更小）。',
      ),
    );
  } else {
    const patchPath = typeof bundle === 'object' && bundle ? bundle.patch : undefined;
    if (typeof patchPath === 'string' && patchPath.trim()) {
      checks.push(pass('bundle-declared', 'bundle patch 已声明', patchPath));
    } else {
      checks.push(
        block(
          'bundle-declared',
          'bundle 声明缺少 patch 路径',
          'dsh.bundle 存在但没有可用的 patch 文件路径，加载阶段会失败。',
          '该包构建产物不完整，换用完整版本。',
        ),
      );
    }
  }

  // 7. peerDependencies（DSH 自身只查安装时可见的部分，这里逐条明细）
  const peers = manifest.peerDependencies && typeof manifest.peerDependencies === 'object' ? manifest.peerDependencies : {};
  const peerIssues = [];
  for (const [peerName, peerRange] of Object.entries(peers)) {
    const installed = env.installedVersions?.[peerName];
    if (!installed) {
      // 安装清单为空说明没读到宿主的包信息，不能据此断言「未安装」。
      if (Object.keys(env.installedVersions || {}).length === 0) continue;
      peerIssues.push(`${peerName} 未安装（要求 ${peerRange}）`);
      continue;
    }
    if (!satisfies(installed, String(peerRange))) {
      peerIssues.push(`${peerName} 当前 ${installed}，要求 ${peerRange}`);
    }
  }
  if (Object.keys(peers).length === 0) {
    checks.push(pass('peer-deps', '无 peer 依赖约束', 'package.json 未声明 peerDependencies'));
  } else if (peerIssues.length === 0) {
    checks.push(pass('peer-deps', 'peer 依赖全部满足', `${Object.keys(peers).length} 项`));
  } else {
    checks.push(
      warn(
        'peer-deps',
        'peer 依赖版本不匹配',
        peerIssues.join('；'),
        '多数情况仍可运行，但可能出现 API 缺失导致的运行时崩溃。',
      ),
    );
  }

  // 8. 已知会拖垮桌面端的版本黑名单
  const signature = manifestName && manifest.version ? `${manifestName}@${manifest.version}` : '';
  const knownBad = Array.isArray(env.knownBad) ? env.knownBad : [];
  const hit = knownBad.find((entry) => entry === signature || entry === manifestName);
  if (hit) {
    checks.push(
      block(
        'known-bad',
        '命中已知崩溃黑名单',
        `${hit} 曾在本机或社区记录中导致桌面端启动失败。`,
        '换用其他版本；确认修复后再从黑名单移除。',
      ),
    );
  }

  // 9. 重复安装
  const bundles = Array.isArray(env.profileBundles) ? env.profileBundles : [];
  if (manifestName && bundles.includes(manifestName)) {
    checks.push(
      warn(
        'duplicate',
        '已在 profile bundles 中',
        `${manifestName} 已存在，重复安装会叠加条目、增加 boot 失败概率。`,
        '先卸载旧版本再安装。',
      ),
    );
  }

  // 9b. 交叉比对：同名包已在本地时，版本是否一致（升级/降级/换版本）
  //     与 `duplicate` 的分工：那边只说「这个名字在 bundles 里」，这边说「装的是哪个版本、
  //     和已装的比是升是降、会不会覆盖成另一份副本」。
  const inBundles = Boolean(manifestName && bundles.includes(manifestName));
  const installedVersion = manifestName ? env.installedVersions?.[manifestName] : undefined;
  const incomingVersion = String(manifest.version || '');
  if (!manifestName) {
    checks.push(pass('dup-plugin-version', '无包名可比对', '元数据里没有 name，跳过多版本比对'));
  } else if (!installedVersion) {
    checks.push(
      pass(
        'dup-plugin-version',
        '本地没有同名包',
        inBundles
          ? `${manifestName} 在 bundles 里登记过，但读不到已装版本（实体可能已缺失）`
          : `${manifestName} 未在本地安装过`,
      ),
    );
  } else if (!inBundles) {
    checks.push(
      warn(
        'dup-plugin-version',
        '同名包已作为依赖存在',
        `${manifestName}@${installedVersion} 已在 node_modules 里（未登记为 bundle），再装成 bundle 会出现两份实例`,
        '确认这个包是被别的插件依赖、还是确实要装成独立插件。',
      ),
    );
  } else if (!incomingVersion || incomingVersion === installedVersion) {
    checks.push(pass('dup-plugin-version', '已装版本与本次一致', `${manifestName}@${installedVersion}`));
  } else {
    const before = parseVersion(installedVersion);
    const after = parseVersion(incomingVersion);
    const downgrade = Boolean(before && after && compareVersions(after, before) < 0);
    checks.push(
      warn(
        'dup-plugin-version',
        downgrade ? '要安装的版本低于已装版本' : '已装同名包，但版本不同',
        `${manifestName} 已装 ${installedVersion}，本次要装 ${incomingVersion}（${downgrade ? '降级' : '升级/换版'}）`,
        downgrade
          ? '降级会覆盖已装副本，若有其他插件依赖新版本的接口会连带失效。'
          : '换版本会覆盖已装副本，先确认没有别的插件钉死在旧版本上。',
      ),
    );
  }

  // 9c. 交叉比对：候选声明的 dependencies 与本地已装版本是否互斥。
  //     `peer-deps` 只查 peerDependencies，普通 dependencies 一直是盲区；
  //     而 @deepseek-ai/* 是宿主单例包，装出第二份实例 = 注册不到宿主、插件静默失效。
  const candidateDeps = { ...(manifest.dependencies || {}), ...(manifest.optionalDependencies || {}) };
  const depEntries = Object.entries(candidateDeps).filter(([, range]) => typeof range === 'string' && range.trim());
  const installedMap = env.installedVersions || {};
  if (Object.keys(installedMap).length === 0) {
    checks.push(
      warn(
        'conflict-deps',
        '无法核对依赖冲突',
        '没有读到自己已装的包版本清单，本次跳过依赖排斥检查',
        '确认桌面端与 profile 的 node_modules 可读后再判断。',
      ),
    );
  } else {
    const conflicts = [];
    for (const [depName, depRange] of depEntries) {
      const have = installedMap[depName];
      if (!have) continue; // 没装过就不存在「排斥」，交给安装过程自己解析
      if (satisfies(have, depRange)) continue;
      conflicts.push({ depName, depRange, have, singleton: depName.startsWith('@deepseek-ai/') });
    }
    const describe = (row) => `${row.depName} 已装 ${row.have}，候选要 ${row.depRange}`;
    if (conflicts.length === 0) {
      checks.push(
        pass(
          'conflict-deps',
          '依赖与已装版本不冲突',
          `${depEntries.length} 个依赖已比对 ${Object.keys(installedMap).length} 个已装包`,
        ),
      );
    } else {
      const hard = conflicts.filter((row) => row.singleton);
      const soft = conflicts.filter((row) => !row.singleton);
      if (hard.length > 0) {
        checks.push(
          block(
            'conflict-deps',
            '与宿主内置包的版本互斥',
            `${hard.map(describe).join('；')}（这些是 DSH 单例包，装出第二份实例会注册不到宿主、插件静默失效）`,
            '让作者放宽依赖范围，或换一个适配当前 DSH 的版本。',
          ),
        );
      }
      if (soft.length > 0) {
        checks.push(
          warn(
            'conflict-deps',
            '依赖版本与已装不一致',
            `${soft.map(describe).join('；')}（包管理器会嵌套装第二份，体积与重复实例风险上升）`,
            '确认候选是否必须依赖新的主版本；能放宽就放宽。',
          ),
        );
      }
    }
  }

  // 10. bundle 数量压力
  const limit = Number.isFinite(env.bundleSoftLimit) ? env.bundleSoftLimit : 40;
  if (bundles.length >= limit) {
    checks.push(
      warn(
        'bundle-load',
        'profile 已接近 bundle 上限',
        `当前 ${bundles.length} 个 bundle（软上限 ${limit}）。bundle 越多，boot 失败后越难定位。`,
        '优先禁用不再使用的插件。',
      ),
    );
  }

  // 安全性：隐私泄露 / 恶意代码 / 病毒特征
  checks.push(...checkSecurity({ manifest, env, sourceHits: input && input.sourceHits }));

  // 稳定性：运行稳定与潜在 bug 风险
  checks.push(...checkStability({ manifest, env }));

  return summarize(applyLevelOverrides(checks, levelOverrides));
}

