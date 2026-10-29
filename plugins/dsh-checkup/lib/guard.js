// Install Guard — 实时哨兵（skill / MCP 落盘兜底拦截）
//
// 为什么需要它：插件安装走 pluginManager.installBundle（index.js 已拦），但 skill 和
// MCP 的安装根本不经过那条路——军械库（dsh-armory）装 skill 是自己下载解压直写
// skills 目录（~/.dsh/skills 与 ~/.agents/skills），装 MCP 是直接写 profile 的
// cordis.patch.yml，宿主也没有 skill 安装 API（dsh-skill-filesystem 只做目录发现）。
// 所以 installBundle 拦截器对这两类安装完全不触发——这就是「装 skill / MCP 不出检查」
// 的根因。这里 watch 文件系统兜底：任何来源（市场、手工复制、脚本）写的 skill / MCP
// 都在落盘后数秒内被检查。
//
// 拦截动作（自动的只有零误伤的两类，其余只告警）：
//   · skill：sk-scripts（恶意脚本特征）→ 目录移入隔离区，可放行/删除（rename 同盘
//     原子、完全可逆）。sk-manifest（缺 SKILL.md）可能是解压未完成的瞬时状态，先
//     复查一次仍缺才隔离。
//   · MCP：mcp-shape / mcp-known-bad（结构性问题、黑名单）→ 行级摘除该条目（写前
//     备份整份 patch、写后 yaml parse 验证、失败自动回滚）。mcp-command（命令不存
//     在）受宿主进程 PATH 与终端差异影响误报率高，只告警不摘除。
//
// 启动基线：插件加载那一刻已存在的 skill 目录 / MCP 条目不拦（存量由体检面板
// /api-checkup/inventory 覆盖），只拦运行期新出现的——升级/重启不会把现有环境
// 整个隔离一遍。
//
// 去抖：目录复制与 patch 写入都不是原子的，事件到达后等写完再检；skill-filesystem
// 的 watch（chokidar，默认 200ms 稳定窗）可能先一步加载 skill——隔离动作在毫秒级，
// 且移走后下次扫描即消失，窗口可接受。

import { watch as fsWatch } from 'node:fs';
import { mkdir, readdir, rename, readFile, writeFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';
import { parse as parseYaml } from 'yaml';

const EVENT_LIMIT = 60;
const DEFAULT_TIMINGS = {
  skillDebounceMs: 1200,
  mcpDebounceMs: 1000,
  inspectDelayMs: 400,
  manifestRecheckMs: 2500,
};

const now = () => new Date().toISOString();

export class InstallSentinel {
  /**
   * @param options.skillsRoots string[] skill 根目录（~/.dsh/skills 与 ~/.agents/skills）
   * @param options.patchFile string profile cordis.patch.yml 路径
   * @param options.quarantineDir string 隔离区目录
   * @param options.checkSkillDir async (dir) => report 复用 index.js 的检查
   * @param options.checkMcpConfig async (config, options) => report
   * @param options.readMcpEntries async () => [{id, config}] 复用 index.js 的解析
   */
  constructor({ skillsRoots, patchFile, quarantineDir, checkSkillDir, checkMcpConfig, readMcpEntries, logger, timings }) {
    this.skillsRoots = (skillsRoots || []).filter((root) => typeof root === 'string' && root.length > 0);
    this.patchFile = patchFile || '';
    this.quarantineDir = quarantineDir;
    this.checkSkillDir = checkSkillDir;
    this.checkMcpConfig = checkMcpConfig;
    this.readMcpEntries = readMcpEntries;
    this.logger = logger;
    // 时序可覆盖：单测用小值加速，运行期用默认去抖。
    this.timings = { ...DEFAULT_TIMINGS, ...(timings && typeof timings === 'object' ? timings : {}) };
    this.watchers = [];
    this.events = [];
    this.timers = new Map();
    this.stopped = false;
    // 基线与去重：已见目录 / 已登记 MCP id / 自己摘除过的 id（防回写后再触发）
    this.seenSkillDirs = new Set();
    this.seenMcpIds = new Set();
    this.removedMcpIds = new Set();
    this.seq = 0;
  }

  pushEvent(event) {
    const record = { id: `g${Date.now()}-${++this.seq}`, at: now(), ...event };
    this.events.unshift(record);
    if (this.events.length > EVENT_LIMIT) this.events.length = EVENT_LIMIT;
    this.logger?.info?.(`checkup: 哨兵 ${record.kind} → ${record.action} · ${record.name || record.mcpId || ''}`);
    return record;
  }

  // ── 启动：先拍基线，再挂 watcher ──────────────────────────────────────────

  async start() {
    await this.snapshotSkillBaseline();
    await this.snapshotMcpBaseline();

    for (const root of this.skillsRoots) {
      try {
        await mkdir(root, { recursive: true });
        const watcher = fsWatch(root, { persistent: false }, () => {
          if (this.stopped) return;
          this.scheduleSkillScan();
        });
        watcher.on('error', (error) => this.logger?.warn?.(`checkup: skill watch(${root}) 异常：${error?.message || error}`));
        this.watchers.push(watcher);
      } catch (error) {
        this.logger?.warn?.(`checkup: skill watch(${root}) 启动失败：${error?.message || error}`);
      }
    }

    if (this.patchFile) {
      const lastSlash = Math.max(this.patchFile.lastIndexOf('\\'), this.patchFile.lastIndexOf('/'));
      const patchDir = lastSlash > 0 ? this.patchFile.slice(0, lastSlash) : '.';
      const targetName = this.patchFile.slice(lastSlash + 1);
      try {
        const watcher = fsWatch(patchDir, { persistent: false }, (_event, filename) => {
          if (this.stopped) return;
          if (String(filename || '') === targetName) this.scheduleMcpScan();
        });
        watcher.on('error', (error) => this.logger?.warn?.(`checkup: mcp watch 异常：${error?.message || error}`));
        this.watchers.push(watcher);
      } catch (error) {
        this.logger?.warn?.(`checkup: mcp watch 启动失败：${error?.message || error}`);
      }
    }

    this.logger?.info?.(
      `checkup: 实时哨兵已启动（skill 根 ${this.skillsRoots.length} 个，MCP patch ${this.patchFile ? '已监听' : '未配置'}；基线 skill ${this.seenSkillDirs.size} / MCP ${this.seenMcpIds.size}）`,
    );
  }

  async snapshotSkillBaseline() {
    for (const root of this.skillsRoots) {
      const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
      for (const entry of entries) if (entry.isDirectory()) this.seenSkillDirs.add(`${root}::${entry.name}`);
    }
  }

  async snapshotMcpBaseline() {
    try {
      const entries = (await this.readMcpEntries?.()) || [];
      for (const entry of entries) if (entry?.id) this.seenMcpIds.add(entry.id);
    } catch {
      // 基线读不到就当没有存量：第一次 patch 变化时会全量过一遍检查。
    }
  }

  scheduleSkillScan() {
    if (this.stopped) return;
    clearTimeout(this.timers.get('skill'));
    this.timers.set('skill', setTimeout(() => void this.scanSkillRoots().catch(() => {}), this.timings.skillDebounceMs));
  }

  scheduleMcpScan() {
    if (this.stopped) return;
    clearTimeout(this.timers.get('mcp'));
    this.timers.set('mcp', setTimeout(() => void this.scanMcpPatch().catch(() => {}), this.timings.mcpDebounceMs));
  }

  stop() {
    this.stopped = true;
    for (const timer of this.timers.values()) clearTimeout(timer);
    this.timers.clear();
    for (const watcher of this.watchers.splice(0)) {
      try {
        watcher.close();
      } catch {
        // 已关闭则忽略
      }
    }
  }

  // ── Skill：扫描各根目录，新目录 → 检查 → 按规则隔离 ──────────────────────

  async scanSkillRoots() {
    for (const root of this.skillsRoots) {
      const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        const key = `${root}::${entry.name}`;
        if (this.seenSkillDirs.has(key)) continue;
        this.seenSkillDirs.add(key);
        await this.inspectSkillDir(root, entry.name);
      }
    }
  }

  async inspectSkillDir(root, name) {
    const dir = join(root, name);
    // 目录刚出现可能还没写完：等一拍再读；读不到（被装方改名/删除）就静默放弃。
    await sleep(this.timings.inspectDelayMs);
    if (!existsSync(dir)) return;
    let report;
    try {
      report = await this.checkSkillDir(dir);
    } catch (error) {
      this.logger?.warn?.(`checkup: skill ${name} 检查失败（不拦截）：${error?.message || error}`);
      return;
    }
    const blocks = blockIdsOf(report);
    if (blocks.length > 0 && blocks.every((id) => id === 'sk-manifest')) {
      // 唯一问题是缺 SKILL.md：可能是解压未完成的瞬时状态，复查一次再判定。
      await sleep(this.timings.manifestRecheckMs);
      if (!existsSync(dir)) return;
      try {
        report = await this.checkSkillDir(dir);
      } catch {
        return; // 复查时目录已不可读，交给下一次事件
      }
    }
    return this.applySkillDecision(root, name, dir, report);
  }

  async applySkillDecision(root, name, dir, report) {
    const blocks = blockIdsOf(report);
    const warned = Number(report?.warned) || 0;
    const nonPassChecks = report?.checks?.filter((c) => c.level !== 'pass') || [];

    if (blocks.length > 0) {
      const dest = await this.quarantine(name, dir);
      this.pushEvent({
        kind: 'skill',
        name,
        action: dest ? 'quarantined' : 'quarantine-failed',
        from: dir,
        to: dest || undefined,
        blockedIds: blocks,
        warned,
        checks: nonPassChecks,
      });
      return;
    }
    this.pushEvent({ kind: 'skill', name, action: 'passed', from: dir, blockedIds: [], warned });
  }

  async quarantine(name, dir) {
    try {
      await mkdir(this.quarantineDir, { recursive: true });
      const dest = join(this.quarantineDir, `${name}-${Date.now()}`);
      await rename(dir, dest);
      return dest;
    } catch (error) {
      this.logger?.warn?.(`checkup: 隔离 skill ${name} 失败：${error?.message || error}`);
      return '';
    }
  }

  // ── MCP：patch 新增条目 → 检查 → 结构性/黑名单问题行级摘除 ────────────────

  async scanMcpPatch() {
    let entries = [];
    try {
      entries = (await this.readMcpEntries?.()) || [];
    } catch {
      return;
    }
    const current = entries.filter((e) => e?.id);
    for (const entry of current) {
      if (this.seenMcpIds.has(entry.id)) continue;
      this.seenMcpIds.add(entry.id);
      await this.inspectMcpEntry(entry.id, entry);
    }
  }

  async inspectMcpEntry(id, entry) {
    if (this.removedMcpIds.has(id)) return;
    let report;
    try {
      report = await this.checkMcpConfig(entry.config, {});
    } catch (error) {
      this.logger?.warn?.(`checkup: MCP ${id} 检查失败（不拦截）：${error?.message || error}`);
      return;
    }
    const blocks = blockIdsOf(report);
    const nonPassChecks = report?.checks?.filter((c) => c.level !== 'pass') || [];
    if (blocks.length === 0) {
      this.pushEvent({ kind: 'mcp', mcpId: id, action: 'passed', blockedIds: [], warned: Number(report?.warned) || 0 });
      return;
    }
    // mcp-command 的误报源是宿主进程 PATH 与终端不同，不自动摘除；其余结构性
    // block（mcp-shape）与黑名单（mcp-known-bad）才摘。
    const autoRemovable = blocks.filter((id2) => id2 !== 'mcp-command');
    if (autoRemovable.length === 0) {
      this.pushEvent({ kind: 'mcp', mcpId: id, action: 'warn-only', blockedIds: blocks, checks: nonPassChecks });
      return;
    }
    const removed = await this.removeMcpEntryFromPatch(id);
    this.pushEvent({
      kind: 'mcp',
      mcpId: id,
      action: removed ? 'removed' : 'remove-failed',
      blockedIds: blocks,
      checks: nonPassChecks,
    });
  }

  /// 从 patch 文件里行级摘除一条 mcp-client 条目（按缩进块匹配，删前备份、删后验证）。
  async removeMcpEntryFromPatch(id) {
    if (!this.patchFile || !existsSync(this.patchFile)) return false;
    const text = await readFile(this.patchFile, 'utf8').catch(() => '');
    if (!text) return false;
    const lines = text.split(/\r?\n/);
    // 找到含目标 id 且其块内声明 dsh-mcp-client 的 `- id:` 行（任意缩进）。
    let start = -1;
    for (let index = 0; index < lines.length; index += 1) {
      const match = /^(\s*)-\s*id:\s*([\w.@/-]+)\s*$/.exec(lines[index]);
      if (!match || match[2] !== id) continue;
      const body = lines.slice(index, blockEnd(lines, index, match[1].length)).join('\n');
      if (body.includes('dsh-mcp-client')) {
        start = index;
        break;
      }
    }
    if (start === -1) return false;

    const indent = /^(\s*)-/.exec(lines[start])[1].length;
    const end = blockEnd(lines, start, indent);
    const backup = `${this.patchFile}.checkup.bak-${Date.now()}`;
    await writeFile(backup, text, { mode: 0o600 });
    const next = [...lines.slice(0, start), ...lines.slice(end)].join('\n');

    // 摘除后必须仍然是一份合法 YAML —— 解析失败说明行级判断切坏了结构，回滚。
    try {
      parseYaml(next);
    } catch (error) {
      this.logger?.warn?.(`checkup: MCP ${id} 摘除后 YAML 校验失败，已回滚：${error?.message || error}`);
      await writeFile(this.patchFile, text, { mode: 0o600 }).catch(() => {});
      return false;
    }

    await writeFile(this.patchFile, next.endsWith('\n') || next === '' ? next : `${next}\n`, { mode: 0o600 });
    this.removedMcpIds.add(id);
    this.seenMcpIds.add(id);
    this.logger?.info?.(`checkup: 已从 patch 摘除 MCP 条目 ${id}（备份：${backup}）`);
    return true;
  }

  // ── 面板操作：隔离区查询 / 放行 / 删除 ──────────────────────────────────

  async listQuarantined() {
    const entries = await readdir(this.quarantineDir, { withFileTypes: true }).catch(() => []);
    return entries.filter((e) => e.isDirectory()).map((e) => join(this.quarantineDir, e.name));
  }

  async releaseQuarantined(dir, action) {
    // 必须先规范化再比前缀：
    //   - 裸 startsWith 会让 `<quarantine>-evil` 通过；
    //   - 不 resolve 则 `<quarantine>\..\skills` 这类穿越也能通过，随后 rm -rf 就是灾难。
    const rootDir = resolve(this.quarantineDir);
    const normalized = resolve(String(dir || ''));
    const inside = normalized === rootDir || normalized.startsWith(rootDir + sep);
    // 隔离区根目录本身不允许被删除/放行（它是个容器，不是某一条隔离项）。
    if (!inside || normalized === rootDir) throw new Error('只允许操作隔离区内的目录');
    if (!existsSync(normalized)) throw new Error(`目录不存在：${normalized}`);
    if (action === 'delete') {
      await rm(normalized, { recursive: true, force: true });
      this.pushEvent({ kind: 'skill', name: normalized.split(/[\\/]/).pop(), action: 'deleted', from: normalized });
      return { action: 'deleted' };
    }
    const name = normalized.slice(rootDir.length + 1).replace(/-\d+$/, '');
    // 放行目标：优先放回第一个 skill 根（宿主确定的 skill 根），目录名去掉隔离时间戳。
    const targetRoot = this.skillsRoots[0] || this.quarantineDir;
    const target = join(targetRoot, name);
    if (existsSync(target)) throw new Error(`放行目标已存在：${target}`);
    await rename(normalized, target);
    this.seenSkillDirs.add(`${targetRoot}::${name}`);
    this.pushEvent({ kind: 'skill', name, action: 'released', to: target });
    return { action: 'released', to: target };
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function blockIdsOf(report) {
  return (Array.isArray(report?.checks) ? report.checks : [])
    .filter((c) => c?.level === 'block')
    .map((c) => c.id);
}

/// 块结束行：从 start 向下找第一个缩进 <= indent 的 `-\s` 行（同级/上级条目开始）。
function blockEnd(lines, start, indent) {
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    const match = /^(\s*)-\s/.exec(line);
    if (match && match[1].length <= indent) return index;
    // 顶层非列表行同样结束当前块（覆盖顶层条目后跟普通键的写法）。
    if (indent === 0 && /^\S/.test(line)) return index;
  }
  return lines.length;
}
