// 实时哨兵（InstallSentinel）自检
//
// 钉住六件事（全部用临时目录 + 注入的检查函数，不碰真实 ~/.dsh）：
//   1) 启动基线：已存在的 skill 目录 / MCP 条目不拦（升级重启不误伤存量）
//   2) 恶意脚本 skill 新目录出现 → 自动隔离进 quarantine
//   3) 缺 SKILL.md 的目录 → 复查后隔离（瞬时状态不误伤由时序参数覆盖）
//   4) patch 新增 mcp-shape block 条目 → 行级摘除，摘后 YAML 合法、其余条目完好
//   5) mcp-command（命令不存在）只告警不摘除（宿主 PATH 差异误报不自动破坏配置）
//   6) 隔离区放行 / 删除，且拒绝操作隔离区外的路径（防穿越）

import { mkdtemp, mkdir, writeFile, readdir, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parse as parseYaml } from 'yaml';
import { InstallSentinel } from '../lib/guard.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra !== undefined ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const readFile2 = async (file) => (await import('node:fs/promises')).readFile(file, 'utf8');
const writeFile0Read = async (file) => readFile2(file);

// 与 lib/skill.js 同判定的最小检查替身：只认「有没有 SKILL.md」与「脚本里有没有 evil()」。
const makeCheckSkillDir = () => async (dir) => {
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
  const hasManifest = entries.some((e) => e.isFile() && e.name === 'SKILL.md');
  let scriptHits = 0;
  for (const entry of entries) {
    if (entry.isFile() && entry.name.endsWith('.js')) {
      const text = await writeFile0Read(join(dir, entry.name));
      if (text.includes('evil()')) scriptHits += 1;
    }
  }
  const checks = [];
  checks.push(
    hasManifest
      ? { id: 'sk-manifest', level: 'pass' }
      : { id: 'sk-manifest', level: 'block', title: '缺少 SKILL.md' },
  );
  checks.push(
    scriptHits
      ? { id: 'sk-scripts', level: 'block', title: `${scriptHits} 处恶意特征` }
      : { id: 'sk-scripts', level: 'pass' },
  );
  return { ok: scriptHits === 0 && hasManifest, blocked: scriptHits || (hasManifest ? 0 : 1), warned: 0, checks };
};

// MCP 检查替身：transport 非法 → mcp-shape block；command 绝对路径不存在 → mcp-command block。
const makeCheckMcpConfig = () => (config) => {
  const checks = [];
  const transport = String(config?.transport || '');
  if (!['stdio', 'sse', 'streamable-http'].includes(transport)) {
    checks.push({ id: 'mcp-shape', level: 'block' });
  } else if (transport === 'stdio' && config?.command && String(config.command).includes('definitely-missing-')) {
    checks.push({ id: 'mcp-command', level: 'block' });
  } else {
    checks.push({ id: 'mcp-shape', level: 'pass' });
  }
  const blocked = checks.filter((c) => c.level === 'block').length;
  return { ok: blocked === 0, blocked, warned: 0, checks };
};

const TIMINGS = { skillDebounceMs: 30, mcpDebounceMs: 30, inspectDelayMs: 20, manifestRecheckMs: 50 };

async function makeEnv() {
  const root = await mkdtemp(join(tmpdir(), 'dsh-checkup-guard-'));
  const skillsA = join(root, 'skills-dsh');
  const skillsB = join(root, 'skills-agents');
  const quarantine = join(root, 'quarantine');
  const patchFile = join(root, 'cordis.patch.yml');
  await mkdir(skillsA, { recursive: true });
  await mkdir(skillsB, { recursive: true });
  await mkdir(quarantine, { recursive: true });
  await writeFile(patchFile, '# profile patch\n', 'utf8');
  return { root, skillsA, skillsB, quarantine, patchFile };
}

function makeSentinel(env, overrides = {}) {
  return new InstallSentinel({
    skillsRoots: [env.skillsA, env.skillsB],
    patchFile: env.patchFile,
    quarantineDir: env.quarantine,
    checkSkillDir: overrides.checkSkillDir || makeCheckSkillDir(),
    checkMcpConfig: makeCheckMcpConfig(),
    readMcpEntries: overrides.readMcpEntries || (() => Promise.resolve([])),
    timings: TIMINGS,
  });
}

const writeSkill = async (root, name, files) => {
  const dir = join(root, name);
  await mkdir(dir, { recursive: true });
  for (const [file, text] of Object.entries(files)) await writeFile(join(dir, file), text, 'utf8');
  return dir;
};

// ── 1) 基线不误伤 ────────────────────────────────────────────────────────────
console.log('case 1: 启动基线不拦存量');
{
  const env = await makeEnv();
  await writeSkill(env.skillsA, 'existing-skill', { 'SKILL.md': '---\nname: x\ndescription: y\n---\n' });
  await writeFile(
    env.patchFile,
    '- id: agent\n  include:\n    - id: mcp-old\n      name: "@deepseek-ai/dsh-mcp-client"\n      config:\n        transport: stdio\n        serverName: old\n',
    'utf8',
  );
  const sentinel = makeSentinel(env, { readMcpEntries: () => Promise.resolve([{ id: 'mcp-old', config: { transport: 'bogus' } }]) });
  await sentinel.start();
  await sleep(150);
  ok('存量 skill 无事件', sentinel.events.length === 0, sentinel.events);
  ok('基线登记 1 个 skill', sentinel.seenSkillDirs.size === 1);
  ok('基线登记 1 个 MCP id', sentinel.seenMcpIds.size === 1 && sentinel.seenMcpIds.has('mcp-old'));
  sentinel.stop();
}

// ── 2) 恶意脚本 skill → 隔离 ────────────────────────────────────────────────
console.log('case 2: 恶意脚本 skill 自动隔离');
{
  const env = await makeEnv();
  const sentinel = makeSentinel(env);
  await sentinel.start();
  await writeSkill(env.skillsB, 'evil-skill', { 'SKILL.md': '---\nname: evil\n---\n', 'run.js': 'evil();\n' });
  await sleep(400);
  const quarantined = await sentinel.listQuarantined();
  ok('目录已移入隔离区', quarantined.length === 1 && quarantined[0].includes('evil-skill-'), quarantined);
  ok('原目录已不存在', !existsSync(join(env.skillsB, 'evil-skill')));
  const event = sentinel.events.find((e) => e.kind === 'skill');
  ok('事件标记 quarantined 且带 sk-scripts', event?.action === 'quarantined' && event.blockedIds.includes('sk-scripts'), event);
  // 放行流程：restore 回第一个 skill 根。
  const released = await sentinel.releaseQuarantined(quarantined[0], 'restore');
  ok('放行后回到 skill 根', existsSync(join(env.skillsA, 'evil-skill')) && released.action === 'released');
  sentinel.stop();
}

// ── 3) 缺 SKILL.md → 复查后隔离 ─────────────────────────────────────────────
console.log('case 3: 缺 SKILL.md 复查后隔离');
{
  const env = await makeEnv();
  const sentinel = makeSentinel(env);
  await sentinel.start();
  await writeSkill(env.skillsA, 'no-manifest', { 'readme.txt': 'hello' });
  await sleep(500);
  const quarantined = await sentinel.listQuarantined();
  ok('复查仍缺 SKILL.md → 隔离', quarantined.length === 1, quarantined);
  sentinel.stop();
}

// ── 4) patch 新增 mcp-shape block → 行级摘除 ────────────────────────────────
console.log('case 4: MCP 结构性 block 自动摘除');
{
  const env = await makeEnv();
  const entries = [];
  const sentinel = makeSentinel(env, {
    readMcpEntries: () => Promise.resolve(entries),
  });
  await sentinel.start();
  // 模拟军械库写入：一条合法 + 一条 transport 非法。
  entries.push({ id: 'mcp-good', config: { transport: 'stdio', serverName: 'good', command: 'node' } });
  entries.push({ id: 'mcp-bad', config: { transport: 'telepathy', serverName: 'bad' } });
  await writeFile(
    env.patchFile,
    [
      '- id: agent-default-model',
      '- id: mnemon',
      '  include:',
      '    - id: mcp-good',
      '      name: "@deepseek-ai/dsh-mcp-client"',
      '      config:',
      '        transport: stdio',
      '        serverName: good',
      '    - id: mcp-bad',
      '      name: "@deepseek-ai/dsh-mcp-client"',
      '      config:',
      '        transport: telepathy',
      '        serverName: bad',
      '- id: tail-entry',
      '',
    ].join('\n'),
    'utf8',
  );
  await sleep(400);
  const after = await readFile2(env.patchFile);
  ok('mcp-bad 条目已被摘除', !after.includes('mcp-bad') && !after.includes('telepathy'), after);
  ok('mcp-good 条目保留', after.includes('mcp-good') && after.includes('serverName: good'));
  ok('前后无关条目保留', after.includes('agent-default-model') && after.includes('tail-entry'));
  const doc = parseYaml(after);
  const mnemon = doc.find((item) => item?.id === 'mnemon');
  ok('摘除后 YAML 合法且 mnemon.include 只剩一条', Array.isArray(mnemon?.include) && mnemon.include.length === 1 && mnemon.include[0].id === 'mcp-good');
  const event = sentinel.events.find((e) => e.kind === 'mcp');
  ok('事件标记 removed 且带 mcp-shape', event?.action === 'removed' && event.blockedIds.includes('mcp-shape'), event);
  ok('摘除留了备份', (await readdir(env.root)).some((name) => name.includes('checkup.bak-')));
  sentinel.stop();
}

// ── 5) mcp-command 只告警不摘除 ─────────────────────────────────────────────
console.log('case 5: mcp-command 只告警不自动摘除');
{
  const env = await makeEnv();
  const entries = [];
  const sentinel = makeSentinel(env, { readMcpEntries: () => Promise.resolve(entries) });
  await sentinel.start();
  entries.push({ id: 'mcp-path', config: { transport: 'stdio', serverName: 'path', command: 'C:/definitely-missing-x/tool.exe' } });
  await writeFile(
    env.patchFile,
    [
      '- id: keep',
      '  include:',
      '    - id: mcp-path',
      '      name: "@deepseek-ai/dsh-mcp-client"',
      '      config:',
      '        transport: stdio',
      '        serverName: path',
      '        command: C:/definitely-missing-x/tool.exe',
      '',
    ].join('\n'),
    'utf8',
  );
  await sleep(400);
  const after = await readFile2(env.patchFile);
  ok('条目仍在（未被摘除）', after.includes('mcp-path'));
  const event = sentinel.events.find((e) => e.kind === 'mcp');
  ok('事件标记 warn-only 且带 mcp-command', event?.action === 'warn-only' && event.blockedIds.includes('mcp-command'), event);
  sentinel.stop();
}

// ── 6) 隔离区防穿越 ─────────────────────────────────────────────────────────
console.log('case 6: 隔离区操作防路径穿越');
{
  const env = await makeEnv();
  const sentinel = makeSentinel(env);
  await sentinel.start();
  let threw = false;
  try {
    await sentinel.releaseQuarantined(env.root, 'delete');
  } catch {
    threw = true;
  }
  ok('隔离区外路径被拒绝', threw);
  ok('项目根仍在', existsSync(env.root));
  sentinel.stop();
}

console.log(failures === 0 ? '\n全部通过' : `\n${failures} 项失败`);
process.exit(failures === 0 ? 0 : 1);
