// Install Guard — 环境体检与处置建议
//
// 扫描已安装的插件 / skill / MCP，基于能拿到的真实信息判断每一项「还有没有必要保留」。
// 纯函数：输入采集好的环境快照，输出逐项结论。采集（读目录、读配置）由 host 负责。
//
// 判定只用可验证的证据，不猜：
//   失效（缺文件 / 缺命令 / 缺 SKILL.md）、重复（同名多份）、冲突（同名 serverName /
//   bundle 名撞车 / 与内置同名）、不兼容（dshRange 不满足）、多余（无声明也无实体）。

export const VERDICT = { KEEP: 'keep', REMOVE: 'remove', REVIEW: 'review' };

const item = (kind, name, extra = {}) => ({
  kind,
  name,
  version: extra.version || '',
  path: extra.path || '',
  status: extra.status || '',
  verdict: extra.verdict || VERDICT.KEEP,
  reason: extra.reason || '',
  signals: Array.isArray(extra.signals) ? extra.signals : [],
});

/// 插件判定。
function auditPlugin(plugin, context) {
  const signals = [];
  let verdict = VERDICT.KEEP;
  let reason = '';

  const name = plugin.name;
  const inBundles = plugin.inBundles === true;
  const inNodeModules = plugin.inNodeModules === true;

  // 版本判定只在宿主版本已知时启用：离线采集拿到 0.0.0 时不能据此判「不兼容」。
  const dshVersionKnown = Boolean(context.dshVersion) && context.dshVersion !== '0.0.0';

  // 宿主内置 bundle：由 DSH 自身提供，属于系统组成部分，不在「可清理」范围。
  if (plugin.builtin === true) {
    return item('plugin', name, {
      version: plugin.version,
      status: '宿主内置',
      verdict: VERDICT.KEEP,
      reason: 'DSH 自带的内置 bundle，随客户端发布，不能单独卸载。',
      signals: ['宿主 app 提供'],
    });
  }

  if (!inNodeModules && inBundles) {
    return item('plugin', name, {
      version: plugin.version,
      status: '实体缺失',
      verdict: VERDICT.REMOVE,
      reason: 'profile 的 bundles 里登记了它，但 profile 与宿主都找不到这个包 —— 加载时必然报错，属于残留项。',
      signals: ['bundles 有登记', '实体缺失'],
    });
  }
  if (!inBundles && inNodeModules) {
    signals.push('依赖存在但未登记 bundle');
    verdict = VERDICT.REVIEW;
    reason = '包在 node_modules 里但没进 bundles，它不会被加载；作为其他插件的依赖可以保留，否则可清理。';
  }

  if (plugin.requiredBy && plugin.requiredBy.length > 0) {
    signals.push(`被 ${plugin.requiredBy.length} 个包依赖`);
    return item('plugin', name, {
      version: plugin.version,
      status: '被依赖',
      verdict: VERDICT.KEEP,
      reason: `它是 ${plugin.requiredBy.slice(0, 3).join(', ')} 的依赖，卸载会连带破坏上游插件。`,
      signals,
    });
  }

  if (dshVersionKnown && plugin.dshRange && plugin.incompatibleDsh === true) {
    return item('plugin', name, {
      version: plugin.version,
      status: '版本不兼容',
      verdict: VERDICT.REMOVE,
      reason: `声明需要 dsh ${plugin.dshRange}，当前是 ${context.dshVersion} —— 装上也不会正常工作。`,
      signals: signals.concat(`dshRange=${plugin.dshRange}`),
    });
  }

  if (plugin.duplicateBundles > 1) {
    return item('plugin', name, {
      version: plugin.version,
      status: '重复登记',
      verdict: VERDICT.REMOVE,
      reason: `bundles 里登记了 ${plugin.duplicateBundles} 次，重复条目会叠加加载次数、放大 boot 失败概率。`,
      signals,
    });
  }

  if (plugin.missingPatch === true && plugin.declaresClient === true) {
    signals.push('声明了 dsh.client 但 patch 缺失');
    verdict = VERDICT.REVIEW;
    reason = '声明了客户端入口却没有 bundle patch 行，可能装不全，建议先确认再用。';
  }

  if (!reason && plugin.prerelease === true) {
    signals.push('预发布/0.0.x 版本');
    verdict = VERDICT.REVIEW;
    reason = '版本成熟度低，接口可能随时变化；不影响使用时可保留，但升级要跟。';
  }

  if (!reason) {
    reason = '登记完整、实体存在、版本兼容，属于正常在用项。';
  }

  return item('plugin', name, {
    version: plugin.version,
    status: '正常',
    verdict,
    reason,
    signals,
  });
}

/// skill 判定。
function auditSkill(skill, context) {
  const signals = [];
  const name = skill.name;

  if (skill.exists === false) {
    return item('skill', name, { verdict: VERDICT.REMOVE, status: '目录缺失', reason: '登记项指向的目录不存在。' });
  }
  if (skill.hasSkillMd === false) {
    return item('skill', name, {
      status: '无 SKILL.md',
      verdict: VERDICT.REMOVE,
      reason: '目录里没有 SKILL.md，宿主不会把它识别为 skill —— 放这里只会增加扫描开销。',
      signals: [`${skill.fileCount || 0} 个文件`],
    });
  }
  if ((skill.fileCount || 0) === 0) {
    return item('skill', name, { status: '空目录', verdict: VERDICT.REMOVE, reason: '空目录，没有任何内容。' });
  }
  if (skill.duplicatesBuiltin === true) {
    return item('skill', name, {
      status: '与内置重复',
      verdict: VERDICT.REMOVE,
      reason: '宿主已内置同名 skill，本地这份会与内置争抢优先级，同名时只有一份生效。',
      signals,
    });
  }
  if (Array.isArray(context.duplicateSkillNames) && context.duplicateSkillNames.includes(name)) {
    return item('skill', name, {
      status: '同名多份',
      verdict: VERDICT.REMOVE,
      reason: '存在多个同名 skill，高优先级来源会覆盖其余，多出来的那份是冗余。',
      signals,
    });
  }
  if (skill.hasDangerousScript === true) {
    return item('skill', name, {
      status: '脚本有风险',
      verdict: VERDICT.REVIEW,
      reason: '脚本命中隐私/恶意特征，先人工确认用途再决定是否保留。',
      signals,
    });
  }
  return item('skill', name, {
    status: '正常',
    verdict: VERDICT.KEEP,
    reason: 'SKILL.md 完整、无重名、脚本未见异常。',
    signals,
  });
}

/// MCP 判定。
function auditMcp(entry, context) {
  const name = entry.serverName || entry.id;
  const signals = [];

  if (entry.commandExists === false) {
    return item('mcp', name, {
      path: entry.id,
      status: '命令不存在',
      verdict: VERDICT.REMOVE,
      reason: `启动命令 ${entry.command || '(空)'} 在本机找不到，MCP 起不来，工具永远不可用。`,
      signals,
    });
  }
  if (Array.isArray(context.duplicateServerNames) && context.duplicateServerNames.includes(name)) {
    return item('mcp', name, {
      path: entry.id,
      status: 'serverName 重复',
      verdict: VERDICT.REMOVE,
      reason: '多个 MCP 用了同一个 serverName，工具名前缀会互相覆盖，只保留一个即可。',
      signals,
    });
  }
  if (!entry.serverName) {
    return item('mcp', name, {
      path: entry.id,
      status: '未命名',
      verdict: VERDICT.REVIEW,
      reason: '没设置 serverName，工具前缀会退化成默认值，容易与其他 MCP 冲突。',
      signals,
    });
  }
  if (entry.hasPlainSecret === true) {
    return item('mcp', name, {
      path: entry.id,
      status: '明文密钥',
      verdict: VERDICT.REVIEW,
      reason: 'env 里直接写了密钥，配置被同步/备份时会泄露；改用 ${ENV} 引用后可以保留。',
      signals,
    });
  }
  return item('mcp', name, {
    path: entry.id,
    status: '正常',
    verdict: VERDICT.KEEP,
    reason: '命令可用、serverName 唯一、配置形状合法。',
    signals,
  });
}

/// 汇总三类结论。
export function auditEnvironment({ plugins = [], skills = [], mcp = [], context = {} }) {
  const items = [
    ...plugins.map((plugin) => auditPlugin(plugin, context)),
    ...skills.map((skill) => auditSkill(skill, context)),
    ...mcp.map((entry) => auditMcp(entry, context)),
  ];

  const byKind = {};
  for (const kind of ['plugin', 'skill', 'mcp']) {
    const rows = items.filter((row) => row.kind === kind);
    byKind[kind] = {
      total: rows.length,
      keep: rows.filter((row) => row.verdict === VERDICT.KEEP).length,
      review: rows.filter((row) => row.verdict === VERDICT.REVIEW).length,
      remove: rows.filter((row) => row.verdict === VERDICT.REMOVE).length,
    };
  }

  return {
    at: new Date().toISOString(),
    items,
    byKind,
    summary: {
      total: items.length,
      keep: items.filter((row) => row.verdict === VERDICT.KEEP).length,
      review: items.filter((row) => row.verdict === VERDICT.REVIEW).length,
      remove: items.filter((row) => row.verdict === VERDICT.REMOVE).length,
    },
  };
}
