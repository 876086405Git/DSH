// Install Guard — 军械库四类检查（连接器 / 技能 / 插件 / 专家）
//
// 这四类是 dsh-armory（大肥鱼军械库）面板里的对象分类，各自的落盘位置不同：
//
//   UI 名   kind      落盘位置                                              识别凭据
//   连接器  mcp       profile/cordis.patch.yml 的 @deepseek-ai/dsh-mcp-client 条目    config.serverName
//   技能    skill     ~/.dsh/skills/<name>/ 与 ~/.agents/skills/<name>/        目录名（专家技能带 wbexpert__ 前缀）
//   插件    plugin    profile 的 dsh.profile.bundles + node_modules           包名
//   专家    expert    profile/cordis.patch.yml 的 @deepseek-ai/dsh-agent-preset 行  行 id `preset-wbexpert-*`
//
// 每类两项：一项看「结构是否合法」（兼容性），一项看「是否重复/失效」（稳定性）。
// 与安装前检查的分工：那边判「这个包能不能装」，这边判「已装对象有没有问题」。

export const ARMORY_KINDS = [
  { id: 'connector', label: '连接器', desc: 'MCP 连接（cordis.patch.yml 里的 dsh-mcp-client 条目）' },
  { id: 'skill', label: '技能', desc: 'skills 目录下的 skill（含专家捆绑技能）' },
  { id: 'plugin', label: '插件', desc: 'profile bundles 里登记的插件' },
  { id: 'expert', label: '专家', desc: '召唤出的专家预设（dsh-agent-preset 行）' },
];

export const ARMORY_RULE_IDS = [
  'arm-connector-shape',
  'arm-connector-dup',
  'arm-skill-manifest',
  'arm-skill-dup',
  'arm-plugin-entity',
  'arm-plugin-dup',
  'arm-expert-shape',
  'arm-expert-orphan',
];

/** 结构项统一归「兼容性」，重复/失效项归「稳定性」。 */
function passCompat(id, kind, title, detail) {
  return { id, category: 'compatibility', armoryKind: kind, level: 'pass', title, detail };
}
function blockCompat(id, kind, title, detail, hint) {
  return { id, category: 'compatibility', armoryKind: kind, level: 'block', title, detail, hint };
}
function warnStable(id, kind, title, detail, hint) {
  return { id, category: 'stability', armoryKind: kind, level: 'warn', title, detail, hint };
}
function passStable(id, kind, title, detail) {
  return { id, category: 'stability', armoryKind: kind, level: 'pass', title, detail };
}

const TRANSPORTS = new Set(['stdio', 'sse', 'streamable-http']);

/**
 * 检查四类已装对象。
 *
 * @param input.connectors - [{ id, serverName, transport, command, commandExists }]
 * @param input.skills     - [{ name, root, hasSkillMd, fileCount }]
 * @param input.plugins    - [{ name, inNodeModules, duplicateBundles, official }]
 * @param input.experts    - [{ id, name, plugin, hasPersona, pluginInstalled }]
 */
export function checkArmory(input = {}) {
  const connectors = Array.isArray(input.connectors) ? input.connectors : [];
  const skills = Array.isArray(input.skills) ? input.skills : [];
  const plugins = Array.isArray(input.plugins) ? input.plugins : [];
  const experts = Array.isArray(input.experts) ? input.experts : [];

  const checks = [];

  // ── 连接器（1/4）────────────────────────────────────────────────────────
  {
    const bad = [];
    const missingCommand = [];
    for (const row of connectors) {
      const label = row.serverName || row.id;
      if (!TRANSPORTS.has(String(row.transport || ''))) bad.push(`${label}：transport=${row.transport || '(空)'}`);
      else if (row.transport === 'stdio' && !row.command) bad.push(`${label}：stdio 缺 command`);
      else if (!row.serverName) bad.push(`${label}：缺 serverName`);
      // #4 命令字段填了、但可执行文件实际不存在：连接必然起不来，必须报出来。
      else if (row.transport === 'stdio' && row.commandExists === false) missingCommand.push(label);
    }
    if (connectors.length === 0) {
      checks.push(passCompat('arm-connector-shape', 'connector', '没有已配置的连接器', 'profile 里没有 dsh-mcp-client 条目，跳过。'));
    } else if (bad.length > 0) {
      checks.push(blockCompat('arm-connector-shape', 'connector', '连接器配置不完整', bad.join('；'), '补齐 transport/serverName/command，否则这个连接起不来。'));
    } else if (missingCommand.length > 0) {
      checks.push(
        blockCompat(
          'arm-connector-shape',
          'connector',
          '连接器的启动命令不存在',
          `${missingCommand.join(', ')}：command 指向的可执行文件找不到`,
          '命令被删除或移动后连接必然起不来，改回正确路径或卸掉这个连接器。',
        ),
      );
    } else {
      checks.push(passCompat('arm-connector-shape', 'connector', '连接器配置均合法', `${connectors.length} 个连接器，transport / serverName / command 都完整`));
    }

    const seen = new Map();
    for (const row of connectors) {
      const key = row.serverName;
      if (!key) continue;
      seen.set(key, (seen.get(key) || 0) + 1);
    }
    const dup = [...seen.entries()].filter(([, count]) => count > 1).map(([name]) => name);
    if (dup.length === 0) {
      checks.push(passStable('arm-connector-dup', 'connector', '连接器名称唯一', connectors.length ? `${connectors.length} 个 serverName 互不重复` : '无连接器'));
    } else {
      checks.push(warnStable('arm-connector-dup', 'connector', '连接器 serverName 重复', `重复：${dup.join(', ')}`, '工具名前缀会互相覆盖，只保留一个。'));
    }
  }

  // ── 技能（2/4）──────────────────────────────────────────────────────────
  {
    const missing = skills.filter((row) => row.hasSkillMd === false).map((row) => row.name);
    if (skills.length === 0) {
      checks.push(passCompat('arm-skill-manifest', 'skill', '没有已安装技能', 'skills 目录为空，跳过。'));
    } else if (missing.length === 0) {
      checks.push(passCompat('arm-skill-manifest', 'skill', '技能都有 SKILL.md', `${skills.length} 个技能目录均含 SKILL.md`));
    } else {
      checks.push(blockCompat('arm-skill-manifest', 'skill', '技能缺 SKILL.md', missing.join(', '), '宿主不会把没有 SKILL.md 的目录识别为技能，删掉或补齐。'));
    }

    const byName = new Map();
    for (const row of skills) byName.set(row.name, (byName.get(row.name) || 0) + 1);
    const dupSkill = [...byName.entries()].filter(([, count]) => count > 1).map(([name]) => name);
    if (dupSkill.length === 0) {
      checks.push(passStable('arm-skill-dup', 'skill', '技能名称唯一', skills.length ? `${skills.length} 个技能无重名` : '无技能'));
    } else {
      checks.push(warnStable('arm-skill-dup', 'skill', '技能重名', `重复：${dupSkill.join(', ')}`, '同名时高优先级来源覆盖其余，多出来的那份是冗余。'));
    }
  }

  // ── 插件（3/4）──────────────────────────────────────────────────────────
  {
    const ghosts = plugins.filter((row) => row.inNodeModules === false && row.official !== true).map((row) => row.name);
    const officialGhosts = plugins.filter((row) => row.inNodeModules === false && row.official === true).map((row) => row.name);
    if (plugins.length === 0) {
      checks.push(passCompat('arm-plugin-entity', 'plugin', '没有已登记插件', 'bundles 为空，跳过。'));
    } else if (ghosts.length === 0) {
      checks.push(
        passCompat(
          'arm-plugin-entity',
          'plugin',
          '插件实体齐全',
          `${plugins.length} 个插件都能找到实体${officialGhosts.length ? `（另有 ${officialGhosts.length} 个宿主内置包，不计入缺失）` : ''}`,
        ),
      );
    } else {
      checks.push(
        blockCompat('arm-plugin-entity', 'plugin', '插件登记了但找不到实体', ghosts.join(', '), '加载时必然报错，从 bundles 里清掉或重装。'),
      );
    }

    const dupPlugin = plugins.filter((row) => (row.duplicateBundles || 1) > 1).map((row) => row.name);
    if (dupPlugin.length === 0) {
      checks.push(passStable('arm-plugin-dup', 'plugin', '插件登记无重复', plugins.length ? `${plugins.length} 个插件各登记一次` : '无插件'));
    } else {
      checks.push(warnStable('arm-plugin-dup', 'plugin', '插件重复登记', `重复：${dupPlugin.join(', ')}`, '重复条目会叠加加载次数、放大 boot 失败概率。'));
    }
  }

  // ── 专家（4/4）──────────────────────────────────────────────────────────
  {
    const bad = [];
    for (const row of experts) {
      const id = String(row.id || '');
      if (!id.startsWith('preset-wbexpert-')) bad.push(`${id || '(无 id)'}：行 id 不是 preset-wbexpert-* 前缀`);
      else if (!row.name) bad.push(`${id}：config.name 为空`);
      else if (row.hasPersona === false) bad.push(`${id}：人设正文为空`);
    }
    if (experts.length === 0) {
      checks.push(passCompat('arm-expert-shape', 'expert', '没有已召唤的专家', 'profile 里没有 dsh-agent-preset 行，跳过。'));
    } else if (bad.length === 0) {
      checks.push(passCompat('arm-expert-shape', 'expert', '专家预设结构完整', `${experts.length} 个专家：id 规范、名称非空、人设正文非空`));
    } else {
      checks.push(blockCompat('arm-expert-shape', 'expert', '专家预设不完整', bad.join('；'), '删掉重建该专家预设，否则新会话选到它会是空人设。'));
    }

    // 孤儿：专家所属插件已从 bundles 移除；技能类专家（bundles 里没有对应插件）不算孤儿。
    const orphans = experts.filter((row) => row.pluginInstalled === false).map((row) => `${row.id}（${row.plugin}）`);
    if (orphans.length === 0) {
      checks.push(passStable('arm-expert-orphan', 'expert', '没有孤儿专家预设', experts.length ? `${experts.length} 个专家都能对上来处` : '无专家'));
    } else {
      checks.push(
        warnStable('arm-expert-orphan', 'expert', '专家预设的来源插件已不存在', orphans.join(', '), '预设仍会出现在选择器里，但捆绑技能可能已失效；不需要就送还。'),
      );
    }
  }

  return checks;
}

/// 按四类汇总统计（面板用）。
export function summarizeArmory(checks) {
  const byKind = {};
  for (const kind of ARMORY_KINDS) {
    const rows = checks.filter((check) => check.armoryKind === kind.id);
    byKind[kind.id] = {
      total: rows.length,
      blocked: rows.filter((row) => row.level === 'block').length,
      warned: rows.filter((row) => row.level === 'warn').length,
      passed: rows.filter((row) => row.level === 'pass').length,
    };
  }
  return byKind;
}
