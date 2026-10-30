// Install Guard — MCP 检查
//
// DSH 的 MCP 没有"安装 API"：它是一条 profile 配置（cordis.patch.yml 里
// `@deepseek-ai/dsh-mcp-client` 条目），改完配置重启才生效。所以这里检查的是
// 「一条准备写进去的 MCP 配置」以及「已存在的 MCP 条目」是否安全、稳定。

const pass = (id, title, detail, category = 'stability') => ({ id, category, level: 'pass', title, detail });
const warn = (id, title, detail, hint, category = 'stability') => ({ id, category, level: 'warn', title, detail, hint });
const block = (id, title, detail, hint, category = 'stability') => ({ id, category, level: 'block', title, detail, hint });


const TRANSPORTS = new Set(['stdio', 'sse', 'streamable-http']);
const SERVER_NAME_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;

/// 从 uvx / npx / node / python 形态里提取要预检的目标。
export function extractMcpTarget(config) {
  const args = Array.isArray(config && config.args) ? config.args.map(String) : [];
  const command = String((config && config.command) || '');
  const program = command.split(/[\\/]/).pop() || '';
  const lower = program.toLowerCase();
  const cleaned = args.filter((arg) => !arg.startsWith('-'));

  if (/^uvx(?:\.exe)?$/i.test(lower)) {
    // uvx --from pkg==1.0 cmd / uvx pkg
    const fromIndex = args.findIndex((arg) => arg === '--from' || arg === '-f');
    if (fromIndex >= 0 && args[fromIndex + 1]) {
      return { kind: 'python-package', spec: args[fromIndex + 1], program };
    }
    if (cleaned[0]) return { kind: 'python-package', spec: cleaned[0], program };
    return { kind: 'none', program };
  }
  if (/^npx(?:\.cmd)?$/i.test(lower)) {
    const target = cleaned.find((arg) => !arg.startsWith('--'));
    if (target) return { kind: 'npm-package', spec: target, program };
    return { kind: 'none', program };
  }
  if (/^(?:node|node\.exe)$/i.test(lower)) {
    const script = cleaned[0];
    if (script) return { kind: 'local-script', spec: script, program };
    return { kind: 'none', program };
  }
  if (/^(?:python|python3|python\.exe)$/i.test(lower)) {
    return { kind: 'python-module', spec: cleaned.join(' '), program };
  }
  return { kind: 'binary', spec: cleaned[0] || '', program };
}

/// 静态检查一条 MCP 配置。
/// @param config - { transport, serverName, command, args, env }
/// @param env - { resolvedCommand?: { path, exists }, existingServerNames?: string[], knownBad?: string[] }
export function checkMcp(config, env = {}) {
  const checks = [];
  const cfg = config && typeof config === 'object' ? config : {};
  const transport = typeof cfg.transport === 'string' ? cfg.transport : '';
  const serverName = typeof cfg.serverName === 'string' ? cfg.serverName : '';
  const command = typeof cfg.command === 'string' ? cfg.command : '';
  const target = extractMcpTarget(cfg);

  // 1) 形状：传输方式与必备字段
  if (!TRANSPORTS.has(transport)) {
    checks.push(
      block(
        'mcp-shape',
        '传输方式不合法',
        `transport=${transport || '(空)'}，只支持 ${[...TRANSPORTS].join(' / ')}`,
        '改成 stdio（本地进程）或 sse / streamable-http（远程）。',
        'compatibility',
      ),
    );
  } else if (transport === 'stdio' && !command) {
    checks.push(
      block('mcp-shape', 'stdio 缺少 command', 'stdio 必须提供要启动的可执行文件', '补 command。', 'compatibility'),
    );
  } else {
    checks.push(
      pass('mcp-shape', '配置形状合法', `${transport}${command ? ` · ${target.program || command}` : ''}`, 'compatibility'),
    );
  }

  // 2) serverName
  if (!serverName) {
    checks.push(
      warn('mcp-servername', '未设置 serverName', '缺失时工具前缀会退化为默认值，容易与其他 MCP 冲突', '显式设置 serverName。', 'stability'),
    );
  } else if (!SERVER_NAME_PATTERN.test(serverName)) {
    checks.push(
      warn(
        'mcp-servername',
        'serverName 不符合规范',
        `${serverName}（应匹配 ${SERVER_NAME_PATTERN.source}）`,
        '工具名会被拼成 mcp__<serverName>__<tool>，超长或含非法字符会导致注册失败。',
        'stability',
      ),
    );
  } else {
    checks.push(pass('mcp-servername', 'serverName 合法', serverName));
  }

  // 2b) 与已装连接器的交叉比对：重名 / 同一个后端换名字 / 名字只差分隔符。
  //     重复判定从 mcp-servername 里搬到这里，是因为它本质是「候选 vs 已装」的比对，
  //     而不是名字本身的合法性；拆开后两边都能单独调级。
  //     candidatePersisted=true 表示候选这条已经写进配置（哨兵复查 / 已装项体检），
  //     此时要把自己那一份从重复计数里减掉，否则每条都会自报重复。
  const others = Array.isArray(env.existingConnectors)
    ? env.existingConnectors.filter((row) => row && typeof row === 'object')
    : Array.isArray(env.existingServerNames)
      ? env.existingServerNames.map((value) => ({ serverName: value }))
      : [];
  const persisted = env.candidatePersisted === true;
  const keyOf = (value) => String(value == null ? '' : value).trim().toLowerCase();
  const looseKey = (value) => keyOf(value).replace(/[-_\s]/g, '');
  const myKey = keyOf(serverName);
  const sameNameCount = myKey ? others.filter((row) => keyOf(row.serverName) === myKey).length : 0;
  const duplicateCount = Math.max(0, sameNameCount - (persisted && myKey ? 1 : 0));

  if (!myKey) {
    checks.push(
      pass('dup-connector-name', '无 serverName 可比对', '未设置 serverName，重名检查交给 mcp-servername 提示'),
    );
  } else if (duplicateCount > 0) {
    checks.push(
      warn(
        'dup-connector-name',
        '与已装连接器 serverName 重复',
        `${serverName} 在 profile 里已有 ${sameNameCount} 条同名条目`,
        '同名会让 mcp__<serverName>__<tool> 前缀撞车、工具互相覆盖，只保留一个。',
        'stability',
      ),
    );
  } else {
    checks.push(
      pass(
        'dup-connector-name',
        '连接器名称未被占用',
        others.length ? `已比对 ${others.length} 个已装连接器，${serverName} 不重名` : '本机还没有已配置的连接器',
      ),
    );
  }

  // 同一个后端的另一种接入方式：命令+参数完全一致但换了 serverName，
  // 或者名字只差大小写/下划线/连字符（工具前缀会互相覆盖）。
  const backendKey = (row) => {
    // 同一个可执行文件的写法可能差着扩展名：uvx / uvx.exe / c:/bin/uvx.EXE
    const program = String(row?.command || '')
      .split(/[\\/]/)
      .pop()
      .toLowerCase()
      .replace(/\.(?:exe|cmd|bat|ps1)$/, '');
    if (!program) return '';
    // 参数顺序不代表身份：`--from pkg cmd` 与 `cmd --from pkg` 是同一个后端。
    const args = (Array.isArray(row?.args) ? row.args : [])
      .map((value) => String(value).trim())
      .filter(Boolean)
      .sort();
    return `${program} ${args.join(' ')}`.trim();
  };
  const myBackend = backendKey({ command, args: cfg.args });
  const sameBackend = [];
  const nearNames = [];
  for (const row of others) {
    const otherKey = keyOf(row.serverName);
    const isSelf = persisted && otherKey === myKey;
    if (isSelf) continue;
    if (myKey && otherKey && otherKey !== myKey && looseKey(row.serverName) === looseKey(serverName)) {
      nearNames.push(String(row.serverName));
    }
    if (myBackend && otherKey !== myKey && backendKey(row) === myBackend) {
      sameBackend.push(String(row.serverName));
    }
  }
  if (nearNames.length === 0 && sameBackend.length === 0) {
    checks.push(
      pass(
        'conflict-connector-tool',
        '与已装连接器无工具级冲突',
        others.length ? '工具前缀与后端命令均不冲突' : '无可比对项',
      ),
    );
  } else {
    const reasons = [];
    if (nearNames.length > 0) reasons.push(`serverName 只差分隔符：${nearNames.join(', ')}（工具前缀可能互相覆盖）`);
    if (sameBackend.length > 0) reasons.push(`同一个后端已接入为：${sameBackend.join(', ')}（工具会重复暴露、调用结果互相干扰）`);
    checks.push(
      warn('conflict-connector-tool', '与已装连接器存在工具级冲突', reasons.join('；'), '去掉重复的那一个，或显式改成不同的 serverName。', 'stability'),
    );
  }

  // 3) command 是否存在
  const resolved = env.resolvedCommand;
  if (transport === 'stdio' && command) {
    if (resolved && resolved.exists === false) {
      checks.push(
        block(
          'mcp-command',
          '启动命令不存在',
          `${command} 在本机找不到，MCP 会一直启动失败、工具不可用`,
          '确认路径或改用 PATH 中的命令。',
          'stability',
        ),
      );
    } else if (resolved && resolved.path) {
      checks.push(pass('mcp-command', '启动命令可用', resolved.path));
    } else {
      checks.push(pass('mcp-command', '启动命令未解析', '远程传输或无法在装前确认，运行时可诊断'));
    }
  }

  // 4) 包目标（npm 包由 host 继续做 registry 预检）
  if (target.kind === 'npm-package') {
    checks.push(
      warn(
        'mcp-package',
        '需要预检的包目标',
        `npm 包：${target.spec}`,
        '宿主会继续按插件同一套规则检查该包的版本/依赖/安全。',
        'compatibility',
      ),
    );
  } else if (target.kind === 'python-package') {
    checks.push(
      pass(
        'mcp-package',
        'python 包目标（不在 npm 侧预检）',
        `${target.spec} 由 uv/uvx 解析安装，装前只校验命令与参数`,
        'compatibility',
      ),
    );
  } else if (target.kind === 'local-script') {
    checks.push(pass('mcp-local-script', '本地脚本目标', target.spec, 'compatibility'));
  } else if (target.kind === 'python-module') {
    checks.push(
      warn('mcp-package', 'python -m 形式无法预检版本', target.spec, '确认该模块已随运行环境安装。', 'compatibility'),
    );
  } else {
    checks.push(pass('mcp-package', '未涉及包安装', '二进制 / 其他形式，跳过包预检', 'compatibility'));
  }

  // 5) env 里的明文密钥
  const envField = cfg.env && typeof cfg.env === 'object' ? cfg.env : {};
  const secretKeys = Object.keys(envField).filter((key) => /(?:api[_-]?key|token|secret|password|passwd)/i.test(key));
  const plainSecrets = secretKeys.filter((key) => {
    const value = String(envField[key] ?? '');
    return value.length >= 8 && !/^\$\{/.test(value);
  });
  if (plainSecrets.length === 0) {
    checks.push(pass('mcp-env-secret', '未发现明文密钥', secretKeys.length ? `有 ${secretKeys.length} 个密钥字段，但都是引用形式` : 'env 中无密钥字段', 'security'));
  } else {
    checks.push(
      warn(
        'mcp-env-secret',
        'env 中存在明文密钥',
        `${plainSecrets.join(', ')} 的值直接写在 profile 配置里`,
        '改用 ${ENV_VAR} 引用系统环境变量，避免配置被同步/备份时泄露。',
        'security',
      ),
    );
  }

  // 6) 黑名单：serverName 或命令名命中
  const knownBad = Array.isArray(env.knownBad) ? env.knownBad : [];
  const hit = knownBad.find(
    (bad) => bad === serverName || (target.spec && bad === target.spec) || (target.program && bad === target.program),
  );
  if (hit) {
    checks.push(
      block('mcp-known-bad', '命中已知崩溃黑名单', hit, '换用其他实现或修复后再接入。', 'compatibility'),
    );
  }

  return checks;
}
