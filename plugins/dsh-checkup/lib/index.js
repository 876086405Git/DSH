// Install Guard — host 入口
//
// 目标：在「安装插件 / skills / MCP」这一步之前做一次兼容性预检，不兼容就拦下，
// 把「装完才发现桌面端起不来」变成「装之前就知道为什么」。
//
// 拦截点：宿主 pluginManager.installBundle（插件市场的所有安装都走它）。
// 检查数据：npm registry 的 package.json（engines / peerDependencies / dsh 字段）+ 本机版本与已装包。
// 面板数据：GET /api-checkup/state，手动预检：POST /api-checkup/check。
//
// 设计约束（都是本机踩过的坑）：
//  · 插件自身不能让宿主 boot 失败 —— 所有可选服务（pluginManager / webServer）都用 ctx.inject 延迟拿，
//    缺服务时只降级，不抛错。
//  · 预检失败必须抛错（阻止安装），不能只打日志；错误里带完整明细供客户端展示。
//  · 包元数据只用 HTTP 读，不依赖 pnpm 可执行文件，避免换机器就失效。

import { randomUUID } from 'node:crypto';
import { homedir, platform } from 'node:os';
import { parse as parseYaml } from 'yaml';
import { join, resolve, sep } from 'node:path';
import { existsSync } from 'node:fs';
import { copyFile, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { checkCandidate, summarize, RULE_IDS, CATEGORIES, declaredDshRange } from './rules.js';
import { scanSourceText } from './security.js';
import { checkSkill, parseFrontmatter, skillContentHash } from './skill.js';
import { checkMcp, extractMcpTarget } from './mcp.js';
import { checkExpert, summarizeExpert } from './expert.js';
import { queryOsv } from './osv.js';
import { auditEnvironment } from './audit.js';
import { checkArmory, summarizeArmory, ARMORY_KINDS, ARMORY_RULE_IDS } from './armory.js';
import { satisfies, parseVersion } from './version.js';
import { InstallSentinel } from './guard.js';

export const name = 'checkup';

/// 宿主 logger（apply 时注入）。顶层工具函数没有 ctx，靠这个拿统一日志出口。
let moduleLogger = null;

/// 兼容旧名（改名前的导出），外部若有 import 不会断。
export { CheckupBlocked as ElectronicDogBlocked };

// 不声明 inject：宿主里 pluginManager / webServer 都是可选服务，缺了也要能加载。
export const inject = [];

const HOME = process.env.DSH_HOME || join(homedir(), '.dsh');
const STATE_DIR = join(HOME, 'checkup');
const HISTORY_FILE = join(STATE_DIR, 'history.json');
const SKILLS_ROOT = join(HOME, 'skills');
// 军械库（dsh-armory）装 skill 写的是 agents 根（ClawHub 兼容路径），与宿主
// dsh-skill-filesystem 的 user-agents root 一致；不监听它就漏一半安装来源。
const AGENTS_SKILLS_ROOT = join(HOME, '..', '.agents', 'skills');

/// #3 判定路径是否落在两个技能根之内（resolve 后按前缀比，防 .. 穿越）。
function isUnderSkillRoot(dirPath) {
  const roots = [SKILLS_ROOT, AGENTS_SKILLS_ROOT].map((root) => resolve(root));
  const target = resolve(dirPath);
  return roots.some((root) => target === root || target.startsWith(root + sep));
}
const QUARANTINE_DIR = join(STATE_DIR, 'quarantine');
const PROFILE_PATCH = join(HOME, 'profiles', 'desktop', 'cordis.patch.yml');
const HISTORY_LIMIT = 50;

// ── 环境探测（带缓存：一次会话内版本与包列表不会变）────────────────────────

/// 定位宿主 app 目录。`resourcesDirs` 可显式传入（测试用），默认从 execPath / resourcesPath 推导。
/// 三种形态都要认：
///   <resources>/app                  未打包（开发版 / 旧版）
///   <resources>/app.asar             打包（0.2.1-rc.5 起，Electron 内 asar 透明挂载）
///   <resources>/app.asar.unpacked/   只解包、不打包（防御性候选，目前没见到这种布局）
/// 顺序有讲究：完整打包的 app.asar 比「部分解包的 app.asar.unpacked」更权威，
/// 所以 unpacked 只作为兜底，不会抢在 app.asar 前面。
export function resourcesAppDir(resourcesDirs) {
  const candidates = [];
  if (process.env.DSH_APP_DIR) candidates.push(resolve(process.env.DSH_APP_DIR));

  let dirs;
  if (Array.isArray(resourcesDirs)) {
    dirs = resourcesDirs;
  } else {
    dirs = [];
    const execPath = process.execPath || '';
    if (execPath) dirs.push(resolve(execPath, '..', 'resources'));
    if (process.resourcesPath) dirs.push(process.resourcesPath);
  }

  for (const resources of dirs) {
    candidates.push(join(resources, 'app'));
    candidates.push(join(resources, 'app.asar'));
    // 防御性候选：某些打包工具只把 dsh 解包到 app.asar.unpacked，asar 本身不含 package.json。
    candidates.push(join(resources, 'app.asar.unpacked', 'dsh'));
    candidates.push(join(resources, 'app.asar.unpacked'));
  }
  return candidates.find((dir) => existsSync(join(dir, 'package.json')));
}

async function readJson(file) {
  try {
    return JSON.parse(await readFile(file, 'utf8'));
  } catch {
    return undefined;
  }
}

let cachedEnv;

export async function probeEnvironment() {
  if (cachedEnv) return cachedEnv;

  const appDir = resourcesAppDir();
  const appPkg = appDir ? await readJson(join(appDir, 'package.json')) : undefined;

  // DSH 版本：桌面端 app/package.json 是权威来源，其次 profile 依赖树。
  let dshVersion = appPkg?.version;
  if (!dshVersion) {
    const profilePkg = await readJson(join(HOME, 'profiles', 'desktop', 'package.json'));
    dshVersion = profilePkg?.dependencies?.['@deepseek-ai/dsh'];
  }

  // 客户端注入目标：宿主 dsh/node_modules/@deepseek-ai 下真实存在的包。
  const clientPackages = new Set();
  const hostModules = appDir ? join(appDir, 'dsh', 'node_modules', '@deepseek-ai') : undefined;
  if (hostModules && existsSync(hostModules)) {
    for (const entry of await readdir(hostModules)) clientPackages.add(`@deepseek-ai/${entry}`);
  }

  // profile 与宿主内置版本（peer 检查用）：宿主 dsh/node_modules 里的包才是运行时真实提供的版本。
  const installedVersions = {};
  const profileModules = join(HOME, 'profiles', 'desktop', 'node_modules');
  if (existsSync(profileModules)) {
    for (const scoped of await readdir(profileModules, { withFileTypes: true }).catch(() => [])) {
      if (scoped.isDirectory() && scoped.name.startsWith('@')) {
        const scopeDir = join(profileModules, scoped.name);
        for (const pkgEntry of await readdir(scopeDir, { withFileTypes: true }).catch(() => [])) {
          if (!pkgEntry.isDirectory()) continue;
          const pj = await readJson(join(scopeDir, pkgEntry.name, 'package.json'));
          if (pj?.version) installedVersions[`${scoped.name}/${pkgEntry.name}`] = pj.version;
        }
      } else if (scoped.isDirectory()) {
        const pj = await readJson(join(profileModules, scoped.name, 'package.json'));
        if (pj?.version) installedVersions[scoped.name] = pj.version;
      }
    }
  }
  // 宿主内置的 @deepseek-ai/* 覆盖 profile 层（宿主实际提供的就是这一套）。
  if (hostModules && existsSync(hostModules)) {
    for (const entry of await readdir(hostModules, { withFileTypes: true }).catch(() => [])) {
      if (!entry.isDirectory()) continue;
      const pj = await readJson(join(hostModules, entry.name, 'package.json'));
      if (pj?.version) installedVersions[`@deepseek-ai/${entry.name}`] = pj.version;
    }
  }

  const profilePkg = await readJson(join(HOME, 'profiles', 'desktop', 'package.json'));

  cachedEnv = {
    dshVersion: dshVersion || '0.0.0',
    dshVersionKnown: Boolean(dshVersion),
    nodeVersion: process.versions.node || '0.0.0',
    availableClientPackages: [...clientPackages],
    installedVersions,
    profileBundles: Array.isArray(profilePkg?.dsh?.profile?.bundles) ? profilePkg.dsh.profile.bundles : [],
    bundleSoftLimit: 40,
    knownBad: [],
  };
  return cachedEnv;
}

// ── 读取候选包的 manifest（HTTP，不依赖 pnpm）────────────────────────────────

const DEFAULT_REGISTRIES = [
  'https://registry.npmmirror.com',
  'https://registry.npmjs.org',
];

export function parseInstallSpec(spec) {
  if (typeof spec !== 'string' || !spec.trim()) return { kind: 'invalid' };
  const text = spec.trim();
  // file: 前缀与 Windows（反斜杠/正斜杠两种）绝对路径都按本地目录处理。
  if (text.startsWith('file:')) return { kind: 'path', path: text.slice(5) };
  if (/^[/.]|^[A-Za-z]:[\\/]|^\\\\/.test(text)) return { kind: 'path', path: text };
  if (/^(?:git\+|git@|github:|gitlab:|bitbucket:)/i.test(text) || /^https?:\/\/.+\.(?:tgz|tar\.gz)$/i.test(text)) {
    return { kind: 'remote' };
  }
  const at = text.lastIndexOf('@');
  const hasRange = at > 0;
  const pkgName = hasRange ? text.slice(0, at) : text;
  const range = hasRange ? text.slice(at + 1) : 'latest';
  return { kind: 'registry', name: pkgName, range: range || 'latest' };
}

// packument 进程内缓存：同一会话里重复预检同一个包不必反复下载整份元数据。
// 不采用缩略元数据（application/vnd.npm.install-v1+json）：实测能省 59% 体积，
// 但会丢掉 repository 字段，直接导致「来源可追溯」「维护信息」两条误报。
// 新鲜期 60 秒；过期后用 ETag 做条件请求，304 就复用旧文档（省流量又不吃旧数据）。
const PACKUMENT_TTL_MS = 60 * 1000;
const packumentCache = new Map();

/// 取一份 packument：返回 { doc } | { status } | { networkError }，让上层能区分「不存在」和「网络挂了」。
async function fetchJson(url, timeoutMs, attempts = 2) {
  const cached = packumentCache.get(url);
  if (cached && Date.now() - cached.at < PACKUMENT_TTL_MS) return { doc: cached.doc, cached: true };

  let networkError = false;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const headers = { accept: 'application/json' };
      if (cached?.etag) headers['if-none-match'] = cached.etag;
      const res = await fetch(url, { signal: controller.signal, headers });
      // 404/410 才是「这个包不存在」；5xx、超时、DNS 失败属于网络故障，不能混为一谈。
      if (res.status === 404 || res.status === 410) return { status: res.status };
      if (res.status === 304 && cached) {
        packumentCache.set(url, { ...cached, at: Date.now() });
        return { doc: cached.doc, cached: true };
      }
      if (!res.ok) {
        networkError = true;
        continue;
      }
      const doc = await res.json();
      packumentCache.set(url, { doc, etag: res.headers.get('etag') || '', at: Date.now() });
      return { doc };
    } catch (error) {
      networkError = true;
      const detail = error?.cause?.code || error?.name || String(error);
      if (moduleLogger) moduleLogger.warn?.(`checkup: registry 读取失败 ${url} · ${detail}`);
      else console.warn('[checkup] registry lookup failed:', url, detail);
    } finally {
      clearTimeout(timer);
    }
  }
  return networkError ? { networkError: true } : { status: 0 };
}

export async function resolveManifest(spec, options = {}) {
  const parsed = parseInstallSpec(spec);

  if (parsed.kind === 'invalid') return { parsed, manifest: undefined, reason: 'invalid-spec' };
  if (parsed.kind === 'path') {
    const pj = await readJson(join(parsed.path, 'package.json'));
    return { parsed, manifest: pj, reason: pj ? undefined : 'path-has-no-manifest' };
  }
  if (parsed.kind === 'remote') return { parsed, manifest: undefined, reason: 'remote-spec-needs-fetch' };

  const registries = options.registries?.length ? options.registries : DEFAULT_REGISTRIES;
  const attempts = Number.isFinite(options.attempts) ? options.attempts : 2;
  const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : 8000;
  let sawManifest = false;
  let sawNetworkError = false;

  for (const registry of registries) {
    const got = await fetchJson(
      `${registry}/${encodeURIComponent(parsed.name).replace('%2F', '/')}`,
      timeoutMs,
      attempts,
    );
    if (got.networkError) {
      sawNetworkError = true;
      continue;
    }
    const doc = got.doc;
    if (!doc) continue;
    sawManifest = true;
    const versions = doc.versions && typeof doc.versions === 'object' ? doc.versions : {};
    const candidates = Object.keys(versions);
    let picked;
    if (parsed.range === 'latest' || parsed.range === '*' || parsed.range === '') {
      picked = doc['dist-tags']?.latest;
    } else {
      picked = candidates
        .filter((version) => satisfies(version, parsed.range))
        .sort((a, b) => {
          const va = parseVersion(a);
          const vb = parseVersion(b);
          if (!va || !vb) return 0;
          return va.major - vb.major || va.minor - vb.minor || va.patch - vb.patch;
        })
        .pop();
    }
    if (picked && versions[picked]) {
      return { parsed, manifest: { ...versions[picked], _registry: registry }, reason: undefined };
    }
    if (picked) return { parsed, manifest: undefined, reason: 'version-not-published' };
  }
  if (sawManifest) return { parsed, manifest: undefined, reason: 'version-not-published' };
  return { parsed, manifest: undefined, reason: sawNetworkError ? 'network-error' : 'not-found' };
}

// ── 预检编排 ────────────────────────────────────────────────────────────────

// ── 源码扫描（只对本地目录安装生效）────────────────────────────────────────

const SOURCE_EXT = /\.(?:js|mjs|cjs|ts|tsx|jsx|sh|ps1|bat|cmd)$/i;
const SOURCE_MAX_FILES = 400;
const SOURCE_MAX_BYTES = 512 * 1024;
const SOURCE_SKIP_DIRS = new Set(['node_modules', '.git', 'dist', 'build', 'coverage', '.cache', 'test', 'tests', '__tests__', 'fixtures']);
// 测试文件里常放「恶意样本」（本插件自己就有一份），扫它等于自己拦自己。
const SOURCE_SKIP_FILE = /(?:^|[.-])(?:test|spec)\.[^\\/]+$/i;

/// 读取候选包目录里的脚本文件，交给纯函数扫描器判定隐私/恶意特征。
export async function scanSourceDir(rootDir) {
  const hits = [];
  let scanned = 0;
  // 本插件自己的规则表文件里就是这些正则的原文（security.js 的规则表、source-scan.js 的
  // 敏感特征表），装自己时必然「命中自己」。只对「包名就是本插件」这一种情况跳过这两个
  // 文件，别的包一律照扫 —— 换个同名包也只能让这两条从 block 降成 warn，不会变成通过。
  const selfPkg = await readJson(join(rootDir, 'package.json'));
  const isSelf = selfPkg?.name === 'dsh-checkup';
  const SELF_RULE_FILES = new Set(['lib/security.js', 'lib/source-scan.js']);

  async function walk(dir, depth) {
    if (scanned >= SOURCE_MAX_FILES || depth > 6) return;
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (scanned >= SOURCE_MAX_FILES) break;
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (SOURCE_SKIP_DIRS.has(entry.name)) continue;
        await walk(full, depth + 1);
        continue;
      }
      if (!SOURCE_EXT.test(entry.name)) continue;
      if (SOURCE_SKIP_FILE.test(entry.name)) continue;
      let text;
      try {
        const info = await stat(full);
        if (info.size > SOURCE_MAX_BYTES) continue;
        text = await readFile(full, 'utf8');
      } catch {
        continue;
      }
      scanned += 1;
      const rel = full.slice(rootDir.length + 1).replace(/\\/g, '/');
      if (isSelf && SELF_RULE_FILES.has(rel)) continue;
      hits.push(...scanSourceText(text, rel));
    }
  }

  await walk(rootDir, 0);

  const seen = new Set();
  return hits.filter((hit) => {
    const key = `${hit.id}:${hit.file}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

// ── Skill / MCP 检查（没有安装 API，只能检查目录与配置）──────────────────────

/// 解析可执行文件：绝对/相对路径直接判存在，裸命令按 PATH 找（Windows 补扩展名）。
export function resolveCommandPath(command) {
  if (typeof command !== 'string' || !command.trim()) return { path: '', exists: false };
  const text = command.trim();
  if (/[\\/]/.test(text)) return { path: text, exists: existsSync(text) };
  const exts = platform() === 'win32' ? ['', '.exe', '.cmd', '.bat'] : [''];
  const dirs = String(process.env.PATH || '').split(platform() === 'win32' ? ';' : ':');
  for (const dir of dirs) {
    if (!dir) continue;
    for (const ext of exts) {
      const candidate = join(dir, text + ext);
      if (existsSync(candidate)) return { path: candidate, exists: true };
    }
  }
  return { path: text, exists: false };
}

/// 读一个 skill 目录（文本文件上限 256KB，最多 500 个）。
export async function readSkillFiles(rootDir) {
  const files = [];
  async function walk(dir, depth) {
    if (depth > 4 || files.length > 500) return;
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (entry.name === 'node_modules' || entry.name === '.git') continue;
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full, depth + 1);
        continue;
      }
      const rel = full.slice(rootDir.length + 1).replace(/\\/g, '/');
      let text;
      if (/\.(md|txt|json|ya?ml|js|mjs|cjs|py|sh|ps1|bat|cmd)$/i.test(entry.name)) {
        try {
          const info = await stat(full);
          if (info.size <= 256 * 1024) text = await readFile(full, 'utf8');
        } catch {
          // 读不到就当没有文本：仍计入文件数
        }
      }
      files.push({ path: rel, text });
    }
  }
  await walk(rootDir, 0);
  return files;
}

/// 只读 SKILL.md 做指纹（其余文件不读，避免体检时把每个技能整个扫一遍）。
async function readSkillSignature(root, dirName) {
  const row = { dirName, root, skillName: '', hash: '' };
  const dir = join(root, dirName);
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
  const hit = entries.find((entry) => entry.isFile() && /^skill\.md$/i.test(entry.name));
  if (!hit) return row;
  let manifest;
  try {
    manifest = await readFile(join(dir, hit.name), 'utf8');
  } catch {
    return row;
  }
  row.hash = skillContentHash(manifest);
  row.skillName = parseFrontmatter(manifest)?.name || '';
  return row;
}

/// 检查一个 skill 目录（供面板/预检用）。
export async function checkSkillDir(dirPath) {
  const files = await readSkillFiles(dirPath);
  const scriptHits = [];
  for (const file of files) {
    if (!file.text) continue;
    if (!/\.(js|mjs|cjs|py|sh|ps1|bat|cmd)$/i.test(file.path)) continue;
    scriptHits.push(...scanSourceText(file.text, file.path));
  }
  // 被检查的目录自己不算「与已装技能重名」——按**完整路径**排除，不能按目录名：
  // 另一个技能根里可能有同名目录，那正是要报出来的冲突。
  const selfPath = resolve(String(dirPath || ''));
  // 两个技能根都要比对：宿主会同时发现 ~/.dsh/skills 与 ~/.agents/skills，
  // 只比前者会漏掉「agent 根里已有同名 / 同内容技能」这一类冲突。
  const existingNames = [];
  const existingSkills = [];
  for (const root of [SKILLS_ROOT, AGENTS_SKILLS_ROOT]) {
    const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const full = join(root, entry.name);
      if (resolve(full) === selfPath) continue;
      existingNames.push(entry.name);
      existingSkills.push(await readSkillSignature(root, entry.name));
    }
  }
  return summarize(
    checkSkill({ dirPath, files, existingNames, existingSkills, scriptHits }),
  );
}

/// 从 profile patch 里取出所有 MCP 条目（按行扫描，兼容 insert 嵌套写法）。
export async function readMcpEntries() {
  const text = existsSync(PROFILE_PATCH) ? await readFile(PROFILE_PATCH, 'utf8').catch(() => '') : '';
  if (!text.trim()) return [];

  // 优先走 YAML 解析：手写正则对「行尾注释 / 引号 / 嵌套 insert」太脆弱，
  // 一条 `- id: mcp-cad   # 备注` 就能让整个连接器从体检里消失。
  const viaYaml = parseMcpEntriesViaYaml(text);
  if (viaYaml !== null) return viaYaml;

  // YAML 解析失败（例如用户写了非法语法）时退回逐行扫描：宁可粗糙，也别整条丢失。
  return parseMcpEntriesViaLines(text);
}

/// 用 YAML 库解析 patch 里的 dsh-mcp-client 条目；解析失败返回 null 交给兜底。
function parseMcpEntriesViaYaml(text) {
  let doc;
  try {
    doc = parseYaml(text, { logLevel: 'error' });
  } catch {
    return null;
  }
  if (!Array.isArray(doc)) return null;

  const rows = [];
  const visit = (row) => {
    if (!row || typeof row !== 'object' || Array.isArray(row)) return;
    if (typeof row.id !== 'string') return;
    if (typeof row.name === 'string' && row.name.includes('dsh-mcp-client')) rows.push(row);
  };
  for (const row of doc) {
    visit(row);
    for (const key of ['insert', 'update']) {
      const list = row && row[key];
      if (Array.isArray(list)) for (const sub of list) visit(sub);
    }
  }

  return rows.map((row) => {
    let cfg = row.config;
    // `config: |` 这种块标量读出来是字符串，内容本身还是 YAML，再解析一次。
    if (typeof cfg === 'string') {
      try {
        cfg = parseYaml(cfg, { logLevel: 'error' }) || {};
      } catch {
        cfg = {};
      }
    }
    if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) cfg = {};

    const args = Array.isArray(cfg.args) ? cfg.args.map((value) => String(value)) : [];
    const env = cfg.env && typeof cfg.env === 'object' && !Array.isArray(cfg.env) ? cfg.env : {};
    let hasPlainSecret = false;
    for (const [key, value] of Object.entries(env)) {
      if (!/(?:api[_-]?key|token|secret|password|passwd)/i.test(key)) continue;
      const raw = String(value == null ? '' : value);
      if (raw.length >= 8 && !/^\$\{/.test(raw)) hasPlainSecret = true;
    }

    return {
      id: row.id,
      hasPlainSecret,
      config: {
        transport: String(cfg.transport || 'stdio'),
        serverName: cfg.serverName == null ? undefined : String(cfg.serverName),
        command: cfg.command == null ? undefined : String(cfg.command),
        args,
      },
    };
  });
}

/// 兜底：逐行扫描（YAML 解析失败时才用）。顺手容忍行尾注释与引号。
function parseMcpEntriesViaLines(text) {
  const lines = text.split(/\r?\n/);
  const entries = [];
  let current = null;
  for (const line of lines) {
    const idMatch = /^\s*-\s*id:\s*["']?([\w.@/-]+)["']?\s*(?:#.*)?$/.exec(line);
    if (idMatch) {
      if (current) entries.push(current);
      current = { id: idMatch[1], lines: [] };
      continue;
    }
    if (current) current.lines.push(line);
  }
  if (current) entries.push(current);

  const stripComment = (value) => String(value || '').replace(/\s+#.*$/, '').trim();
  const mcp = [];
  for (const entry of entries) {
    const body = entry.lines.join('\n');
    if (!body.includes('dsh-mcp-client')) continue;
    const transport = stripComment((/transport:\s*([\w-]+)/.exec(body) || [])[1]) || 'stdio';
    const serverName = stripComment((/serverName:\s*([\w.-]+)/.exec(body) || [])[1]);
    const command = stripComment((/command:\s*([^\n]+)/.exec(body) || [])[1]);
    const args = [];
    const argBlock = /args:\s*\n((?:\s+-\s*[^\n]+\n?)+)/.exec(body);
    if (argBlock) {
      for (const m of argBlock[1].matchAll(/-\s*([^\n]+)/g)) args.push(stripComment(m[1]).replace(/^["']|["']$/g, ''));
    }
    const envBlock = /env:\s*\n((?:\s+[A-Za-z0-9_-]+:\s*[^\n]+\n?)+)/.exec(body);
    let hasPlainSecret = false;
    if (envBlock) {
      for (const line of envBlock[1].split(/\r?\n/)) {
        const m = /^\s+([A-Za-z0-9_-]+):\s*(.+?)\s*$/.exec(line);
        if (!m) continue;
        if (!/(?:api[_-]?key|token|secret|password|passwd)/i.test(m[1])) continue;
        const value = stripComment(m[2]).replace(/^["']|["']$/g, '');
        if (value.length >= 8 && !/^\$\{/.test(value)) hasPlainSecret = true;
      }
    }
    mcp.push({
      id: entry.id,
      hasPlainSecret,
      config: {
        transport,
        serverName: serverName || undefined,
        command: command || undefined,
        args,
      },
    });
  }
  return mcp;
}

// ── 环境体检：采集已装插件 / skill / MCP 的真实状态 ─────────────────────────

const PROFILE_DIR = join(HOME, 'profiles', 'desktop');
const PROFILE_PKG = join(PROFILE_DIR, 'package.json');
const PROFILE_MODULES = join(PROFILE_DIR, 'node_modules');

/// 插件侧快照：bundle 登记、实体、依赖关系、版本兼容。
export async function collectAuditPlugins() {
  const pkg = await readJson(PROFILE_PKG);
  const bundles = Array.isArray(pkg?.dsh?.profile?.bundles) ? pkg.dsh.profile.bundles : [];
  const counts = new Map();
  for (const entry of bundles) {
    if (typeof entry !== 'string') continue;
    counts.set(entry, (counts.get(entry) || 0) + 1);
  }

  const manifests = new Map();
  for (const name of counts.keys()) {
    const file = join(PROFILE_MODULES, name, 'package.json');
    if (!existsSync(file)) {
      manifests.set(name, null);
      continue;
    }
    try {
      manifests.set(name, JSON.parse(await readFile(file, 'utf8')));
    } catch {
      manifests.set(name, null);
    }
  }

  const env = await probeEnvironment();
  const appDir = resourcesAppDir();
  const appModules = [
    appDir ? join(appDir, 'node_modules') : '',
    appDir ? join(appDir, 'dsh', 'node_modules') : '',
  ].filter(Boolean);

  const items = [];
  for (const [name, count] of counts) {
    const manifest = manifests.get(name);
    // 内置 bundle 不在 profile 的 node_modules 里，由宿主 app 提供，不能算「实体缺失」。
    const inApp = appModules.some((dir) => existsSync(join(dir, name)));
    // 兜底：@deepseek-ai/* 一定是 DSH 自己的包。即使 asar 内路径读不到（或磁盘上暂时不可见），
    // 也绝不能落到「实体缺失 → 建议卸载」那条分支上。
    const isOfficial = typeof name === 'string' && name.startsWith('@deepseek-ai/');
    // 谁依赖它：同 profile 内其他插件的 dependencies / peerDependencies
    const requiredBy = [];
    for (const [other, otherManifest] of manifests) {
      if (other === name || !otherManifest) continue;
      const deps = { ...(otherManifest.dependencies || {}), ...(otherManifest.peerDependencies || {}) };
      if (deps[name]) requiredBy.push(other);
    }
    const range = manifest ? declaredDshRange(manifest) : undefined;
    const patchRel = manifest?.dsh?.bundle?.patch;
    items.push({
      name,
      version: manifest?.version || '',
      inBundles: true,
      inNodeModules: Boolean(manifest) || inApp || isOfficial,
      builtin: isOfficial || (inApp && !manifest),
      duplicateBundles: count,
      declaresClient: Boolean(manifest?.dsh?.client),
      missingPatch: Boolean(patchRel) && !existsSync(join(PROFILE_MODULES, name, patchRel)),
      dshRange: range,
      incompatibleDsh: Boolean(range && env.dshVersion && !satisfies(env.dshVersion, range)),
      prerelease: /-(?:alpha|beta|rc|dev|canary|next)/i.test(manifest?.version || ''),
      requiredBy,
    });
  }
  return items;
}

/// skill 侧快照：目录内容、SKILL.md、脚本风险。
export async function collectAuditSkills() {
  if (!existsSync(SKILLS_ROOT)) return [];
  const entries = await readdir(SKILLS_ROOT, { withFileTypes: true }).catch(() => []);
  const items = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const dir = join(SKILLS_ROOT, entry.name);
    const files = await readSkillFiles(dir);
    const hasSkillMd = files.some((file) => /(?:^|\/)SKILL\.md$/i.test(file.path));
    let hasDangerousScript = false;
    for (const file of files) {
      if (!file.text) continue;
      if (!/\.(js|mjs|cjs|py|sh|ps1|bat|cmd)$/i.test(file.path)) continue;
      const hits = scanSourceText(file.text, file.path);
      if (hits.some((hit) => hit.level === 'block')) {
        hasDangerousScript = true;
        break;
      }
    }
    items.push({ name: entry.name, path: dir, exists: true, hasSkillMd, fileCount: files.length, hasDangerousScript });
  }
  return items;
}

/// MCP 侧快照：命令可用性、serverName、明文密钥。
export async function collectAuditMcp() {
  const entries = await readMcpEntries();
  const rows = [];
  for (const entry of entries) {
    const resolved = resolveCommandPath(entry.config.command);
    rows.push({
      id: entry.id,
      serverName: entry.config.serverName,
      transport: entry.config.transport,
      command: entry.config.command,
      commandExists: entry.config.transport === 'stdio' ? resolved.exists : true,
      hasPlainSecret: entry.hasPlainSecret === true,
    });
  }
  return rows;
}


/// #10 从一段 YAML 文本里取 persona 正文的有效长度。
/**
 * 支持三种写法：
 *   prefix: |            块标量（正文缩进，遇到不缩进的行即结束）
 *   prefix: >            折叠块标量（同上）
 *   prefix: "一段文本"    单行标量
 * 取不到就返回 0。
 */
export function readPersonaLength(chunk) {
  const lines = String(chunk || '').split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (!/^\s*prefix:/.test(line)) continue;
    const inline = line.replace(/^\s*prefix:\s*/, '').trim();
    // 单行标量：直接算长度；块标量记号的 | / > 跳过。
    if (inline !== '' && inline !== '|' && inline !== '>' && inline !== '|-' && inline !== '>-') {
      return inline.replace(/^['\"]|['\"]$/g, '').replace(/\s+/g, '').length;
    }
    // 块标量：收集比 prefix 行缩进更深的后续行，遇到不缩进的行即结束。
    const baseIndent = line.match(/^\s*/)[0].length;
    const body = [];
    for (let j = i + 1; j < lines.length; j += 1) {
      const next = lines[j];
      if (next.trim() === '') {
        body.push('');
        continue;
      }
      const indent = next.match(/^\s*/)[0].length;
      if (indent <= baseIndent) break;
      body.push(next);
    }
    return body.join('\n').replace(/\s+/g, '').length;
  }
  return 0;
}

/// 读出 profile 里所有 dsh-agent-preset 行（专家预设）。
export async function readExpertPresets() {
  const text = existsSync(PROFILE_PATCH) ? await readFile(PROFILE_PATCH, 'utf8').catch(() => '') : '';
  if (!text.trim()) return [];

  // 走 YAML 解析，别再按 `- id:` 切块：
  // 专家预设的 persona 是嵌套的 `config.plugins[].config.prefix`，
  // 按行切块会把内层 `- id: persona` 也当成条目边界，persona 永远读成空 → 误报「人设正文为空」。
  let doc;
  try {
    doc = parseYaml(text, { logLevel: 'error' });
  } catch {
    return [];
  }
  if (!Array.isArray(doc)) return [];

  const PREFIX = 'preset-wbexpert-';
  const rows = [];
  const visit = (row) => {
    if (!row || typeof row !== 'object' || Array.isArray(row)) return;
    if (typeof row.id === 'string' && row.id.startsWith(PREFIX)) {
      const cfg = row.config && typeof row.config === 'object' && !Array.isArray(row.config) ? row.config : {};
      let personaLen = 0;
      let persona = '';
      const consider = (value) => {
        if (typeof value !== 'string') return;
        personaLen = Math.max(personaLen, value.replace(/\s+/g, '').length);
        const cleaned = value.replace(/\s+/g, ' ').trim();
        if (cleaned.length > persona.length) persona = cleaned;
      };
      // 真实形态：config.plugins[<persona 行>].config.prefix / suffix
      for (const plugin of Array.isArray(cfg.plugins) ? cfg.plugins : []) {
        const inner = plugin && typeof plugin.config === 'object' ? plugin.config : null;
        if (!inner) continue;
        consider(inner.prefix);
        consider(inner.suffix);
      }
      // 兼容：有些写法把 person 直接放在 config.persona 下
      if (cfg.persona && typeof cfg.persona === 'object') {
        consider(cfg.persona.prefix);
        consider(cfg.persona.suffix);
      }
      // 专家引用的第三方插件包名（官方 @deepseek-ai/* 由宿主自带，不算孤儿来源）。
      // 召唤专家的 persona 是内嵌在 plugins[<persona>].config.prefix 里的，
      // 所以「plugin 字段只是个名字标识」——不能拿它去 bundles 里找包，否则必然误报。
      const externalRefs = [];
      for (const plugin of Array.isArray(cfg.plugins) ? cfg.plugins : []) {
        const pkgName = plugin && typeof plugin.name === 'string' ? plugin.name.trim() : '';
        // 官方包由宿主自带；`cordis:group` 这类是加载器内部标记，不是可安装的包。
        if (!pkgName || pkgName.startsWith('@deepseek-ai/') || pkgName.includes(':')) continue;
        if (!externalRefs.includes(pkgName)) externalRefs.push(pkgName);
      }
      rows.push({
        id: row.id,
        name: typeof cfg.name === 'string' ? cfg.name.trim() : '',
        plugin: row.id.slice(PREFIX.length),
        hasPersona: personaLen > 20,
        persona,
        externalRefs,
      });
    }
    for (const key of ['insert', 'update']) {
      if (Array.isArray(row[key])) for (const sub of row[key]) visit(sub);
    }
  };
  for (const row of doc) visit(row);
  return rows;
}

/// 扫一个技能根，返回 { name, root, hasSkillMd, fileCount }。
async function scanSkillRoot(root, label) {
  if (!existsSync(root)) return [];
  const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
  const rows = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const files = await readSkillFiles(join(root, entry.name));
    rows.push({
      name: entry.name,
      root: label,
      path: join(root, entry.name),
      hasSkillMd: files.some((file) => /(?:^|\/)SKILL\.md$/i.test(file.path)),
      fileCount: files.length,
    });
  }
  return rows;
}

/// 列出一个 node_modules 目录下的包名（`@scope/name` 会展开成两级）。
/// 读不到就当空集合——调用方据此判断「实体缺失」，不能因此抛错。
/// 列出一个 node_modules 目录下的包名（`@scope/name` 会展开成两级）。
/// 读不到就当空集合——调用方据此判断「实体缺失」，不能因此抛错。
async function listDirNames(dir) {
  const names = [];
  if (!dir) return names;
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return names;
  }
  // pnpm 的包绝大多数是 symlink，Dirent.isDirectory() 对它们返回 false。
  // 只看 isDirectory 会把 @dsh-pet/bridge 这类包漏掉 → 误报「实体缺失」。
  const isPkg = (entry) => entry.isDirectory() || entry.isSymbolicLink();
  for (const entry of entries) {
    if (!isPkg(entry)) continue;
    if (entry.name.startsWith('@')) {
      const scoped = await readdir(join(dir, entry.name), { withFileTypes: true }).catch(() => []);
      for (const sub of scoped) {
        if (isPkg(sub)) names.push(`${entry.name}/${sub.name}`);
      }
      continue;
    }
    names.push(entry.name);
  }
  return names;
}

/// 军械库四类快照（连接器 / 技能 / 插件 / 专家）。
export async function collectArmory() {
  const connectors = (await readMcpEntries()).map((entry) => ({
    id: entry.id,
    serverName: entry.config.serverName,
    transport: entry.config.transport,
    command: entry.config.command,
    commandExists: resolveCommandPath(entry.config.command).exists,
  }));

  const skills = [
    ...(await scanSkillRoot(SKILLS_ROOT, '.dsh/skills')),
    ...(await scanSkillRoot(AGENTS_SKILLS_ROOT, '.agents/skills')),
  ];

  const pkg = await readJson(PROFILE_PKG);
  const bundles = Array.isArray(pkg?.dsh?.profile?.bundles) ? pkg.dsh.profile.bundles : [];
  const counts = new Map();
  for (const name of bundles) {
    if (typeof name !== 'string') continue;
    counts.set(name, (counts.get(name) || 0) + 1);
  }
  const appDir = resourcesAppDir();
  const appModules = [
    appDir ? join(appDir, 'node_modules') : '',
    appDir ? join(appDir, 'dsh', 'node_modules') : '',
  ].filter(Boolean);
  // 一次性把几个 node_modules 的条目读成集合：26 个包 × 3 个目录 = 78 次 existsSync
  // 会长时间占住事件循环，换成 3 次 readdir 查表。
  const moduleLists = await Promise.all([PROFILE_MODULES, ...appModules].map((dir) => listDirNames(dir)));
  const knownModules = new Set(moduleLists.flat());
  const plugins = [];
  for (const [name, count] of counts) {
    const official = name.startsWith('@deepseek-ai/');
    plugins.push({
      name,
      inNodeModules: knownModules.has(name) || official,
      duplicateBundles: count,
      official,
    });
  }

  // persona 正文可能有几千字，不进面板快照：只留比对用的关键字段，
  // 需要正文比对时用 checkExpertConfig() 现读。
  const experts = (await readExpertPresets()).map(({ persona, ...row }) => ({
    ...row,
    // 孤儿判定只看「专家引用的第三方插件包」是否还在 bundles 里。
    // 不能用 row.plugin（那只是 WorkBuddy 的专家标识，如 code-review-expert），
    // 否则每个召回的专家都会被误报「来源插件已不存在」。
    pluginInstalled: (row.externalRefs || []).every((name) => counts.has(name)),
  }));

  return { connectors, skills, plugins, experts };
}

/// 环境体检入口：采集 + 判定 + 汇总。
export async function runAudit() {
  const env = await probeEnvironment();
  const [plugins, skills, mcp] = await Promise.all([collectAuditPlugins(), collectAuditSkills(), collectAuditMcp()]);
  const duplicateServerNames = mcp
    .map((row) => row.serverName)
    .filter((name, index, list) => name && list.indexOf(name) !== index);
  return auditEnvironment({
    plugins,
    skills,
    mcp,
    context: { dshVersion: env.dshVersion, duplicateServerNames },
  });
}

/// 检查一条 MCP 配置：静态规则 + 与已装连接器的交叉比对 + 若目标是包则复用插件那套 registry 预检。
export async function checkMcpConfig(config, options = {}) {
  const rows = (await readMcpEntries()).map((item) => ({
    id: item.id,
    serverName: item.config.serverName,
    command: item.config.command,
    args: item.config.args,
  }));
  const entries = Array.isArray(options.existingServerNames)
    ? options.existingServerNames
    : rows.map((row) => row.serverName).filter(Boolean);
  const target = extractMcpTarget(config);
  const checks = checkMcp(config, {
    resolvedCommand: resolveCommandPath(config && config.command),
    // 交叉比对要看到全部已装条目（含同名），「减掉自己那一份」由 candidatePersisted 控制。
    existingServerNames: entries,
    existingConnectors: rows,
    candidatePersisted: options.candidatePersisted === true,
    knownBad: Array.isArray(options.knownBad) ? options.knownBad : [],
  });

  let packageReport;
  // 只有 npm 包能在 npm registry 侧预检；python 包由 uv 解析，查 npm 只会得到无意义的 not-found。
  if (target.kind === 'npm-package') {
    try {
      packageReport = await runCheck(target.spec, options);
    } catch {
      packageReport = undefined;
    }
  }

  return {
    ...summarize(checks),
    target,
    packageReport,
    at: new Date().toISOString(),
  };
}

/// 检查一条候选专家配置：结构 + 与已装专家的交叉比对。
/// 专家是 patch 里的一行配置（不是包），所以没有 registry 侧可查，只做本地比对。
export async function checkExpertConfig(candidate, options = {}) {
  const experts = await readExpertPresets();
  const env = await probeEnvironment();
  const installedNames = [...new Set([...(env.profileBundles || []), ...Object.keys(env.installedVersions || {})])];
  const checks = checkExpert(candidate, {
    experts,
    installedNames,
    selfId: typeof options.selfId === 'string' ? options.selfId : '',
  });
  return {
    ...summarizeExpert(checks),
    candidate,
    at: new Date().toISOString(),
  };
}

export async function runCheck(spec, config = {}) {
  const env = await probeEnvironment();
  const { parsed, manifest, reason } = await resolveManifest(spec, {
    registries: config.registries,
    timeoutMs: config.lookupTimeoutMs,
    attempts: config.lookupAttempts,
  });

  // 本地路径安装能拿到源码 → 做隐私/恶意特征扫描；registry 包没有源码可扫。
  let sourceHits = [];
  const sourceScanned = Boolean(parsed && parsed.kind === 'path');
  if (sourceScanned) {
    sourceHits = await scanSourceDir(parsed.path);
  }

  // 包自带豁免：只能把 block 降成 warn（见 rules.js）。来源有两处：
  //   ① 本地目录里的 .checkup-allow.json；② package.json 的 checkupAllow 数组。
  const allowRules = [];
  if (sourceScanned) {
    const allowDoc = await readJson(join(parsed.path, '.checkup-allow.json'));
    if (Array.isArray(allowDoc?.allow)) allowRules.push(...allowDoc.allow.map(String));
  }
  if (Array.isArray(manifest?.checkupAllow)) allowRules.push(...manifest.checkupAllow.map(String));

  // 已知漏洞（OSV）：默认开启；查询失败只 warn，绝不因为断网就阻止安装。
  let vulnerabilities;
  if (config.vulnCheckEnabled !== false && manifest?.name && manifest?.version) {
    const osv = await queryOsv({
      name: manifest.name,
      version: manifest.version,
      fetchImpl: config.fetchImpl,
      timeoutMs: config.osvTimeoutMs,
    });
    vulnerabilities = { name: manifest.name, version: manifest.version, ...osv };
  }

  const report = checkCandidate({
    spec,
    manifest,
    sourceHits,
    sourceScanned,
    allowRules,
    vulnerabilities,
    levelOverrides: config.levelOverrides,
    env: {
      ...env,
      knownBad: Array.isArray(config.knownBad) ? config.knownBad : [],
      maliciousPackages: Array.isArray(config.maliciousPackages) ? config.maliciousPackages : [],
      installedNames: Object.keys(env.installedVersions || {}),
      // 拿不到元数据的原因要传下去：网络故障、包不存在、git 形式，三种处理不一样。
      manifestReason: reason,
      manifestUnavailablePolicy: config.manifestUnavailablePolicy,
    },
  });

  return {
    ...report,
    spec,
    manifest: manifest
      ? {
          name: manifest.name,
          version: manifest.version,
          dsh: manifest.dsh,
          engines: manifest.engines,
          peerDependencies: manifest.peerDependencies,
          registry: manifest._registry,
        }
      : undefined,
    at: new Date().toISOString(),
  };
}

// ── 历史记录 ────────────────────────────────────────────────────────────────

const LEGACY_STATE_DIR = join(HOME, 'electronic-dog');

/// #7 旧品牌状态目录：把 history 并进新位置，然后删掉旧目录。
async function migrateLegacyStateDir() {
  if (!existsSync(LEGACY_STATE_DIR)) return;
  const legacyHistory = join(LEGACY_STATE_DIR, 'history.json');
  if (existsSync(legacyHistory)) {
    const old = await readJson(legacyHistory);
    const oldEntries = Array.isArray(old?.entries) ? old.entries : [];
    if (oldEntries.length > 0) {
      const current = await readHistory();
      const merged = [...current, ...oldEntries]
        .filter((row) => row && typeof row === 'object')
        .sort((a, b) => String(b.at || '').localeCompare(String(a.at || '')))
        .slice(0, HISTORY_LIMIT);
      await mkdir(STATE_DIR, { recursive: true });
      await writeFile(HISTORY_FILE, JSON.stringify({ entries: merged }, undefined, 2), { mode: 0o600 });
    }
  }
  await rm(LEGACY_STATE_DIR, { recursive: true, force: true }).catch(() => {});
}

async function readHistory() {
  const doc = await readJson(HISTORY_FILE);
  return Array.isArray(doc?.entries) ? doc.entries : [];
}

async function recordReport(report) {
  try {
    await mkdir(STATE_DIR, { recursive: true });
    const entries = await readHistory();
    entries.unshift({
      at: report.at,
      spec: report.spec,
      ok: report.ok,
      blocked: report.blocked,
      warned: report.warned,
      checks: report.checks.map((c) => ({ id: c.id, level: c.level, title: c.title, detail: c.detail })),
    });
    await writeFile(HISTORY_FILE, JSON.stringify({ entries: entries.slice(0, HISTORY_LIMIT) }, undefined, 2), {
      mode: 0o600,
    });
  } catch {
    // 记录失败不影响拦截判定
  }
}

/// 拦截错误：客户端拿到 code 后弹窗展示 report。
/// message 必须自带完整原因 —— 插件市场的失败提示只会展示这一行文本，
/// 写清楚才能让用户不进日志就知道「为什么没装成」。
export class CheckupBlocked extends Error {
  constructor(report) {
    const blocked = report.checks.filter((c) => c.level === 'block');
    const lines = blocked.map((c) => {
      const hint = c.hint ? `（建议：${c.hint}）` : '';
      return `- ${c.title}：${c.detail ?? ''}${hint}`;
    });
    super(`安装被预检拦截（${blocked.length} 项未通过）：\n${lines.join('\n')}`);
    this.name = 'CheckupBlocked';
    this.code = 'checkup/blocked';
    this.report = report;
  }
}

// ── HTTP 面板数据 ───────────────────────────────────────────────────────────

/// 只放行「本机页面」发起的请求。
/**
 * 没有 Origin（curl / 本地脚本 / 非浏览器）→ 放行：这类调用者本来就能直接读写磁盘，
 * 拦不住也不该拦；真正的威胁是同机浏览器里的其它网站做跨源请求。
 * 有 Origin → 只接受 dsh-app 协议或本机 http(s)，挡掉 example.com 这类跨源页面。
 */
function isTrustedRequest(req) {
  const origin = req.headers && req.headers.origin;
  if (typeof origin !== 'string' || origin === '') return true;
  if (origin.startsWith('dsh-app://')) return true;
  return /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/i.test(origin);
}

function jsonRoute(path, handle) {
  return {
    kind: 'exact',
    path,
    handler: async (req, res) => {
      let status = 200;
      let payload;
      if (!isTrustedRequest(req)) {
        status = 403;
        payload = { ok: false, error: '拒绝跨源请求' };
      } else {
        try {
          [status, payload] = await handle(req);
        } catch (error) {
          status = 500;
          payload = { ok: false, error: error instanceof Error ? error.message : String(error) };
        }
      }
      res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      res.end(JSON.stringify(payload));
    },
  };
}

const MAX_BODY_BYTES = 1024 * 1024;

async function readBody(req) {
  const chunks = [];
  let total = 0;
  // 先看声明长度：能直接判定的就不读，排空后让路由回 400（连接不重置）。
  const declared = Number(req.headers && req.headers['content-length']);
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    req.resume();
    return { __tooLarge: true };
  }
  for await (const chunk of req) {
    total += chunk.length;
    // 边读边判（chunked 没有 content-length 时走这里）：超限停止累积并排空。
    if (total > MAX_BODY_BYTES) {
      req.resume();
      return { __tooLarge: true };
    }
    chunks.push(String(chunk));
  }
  try {
    return JSON.parse(chunks.join('') || '{}');
  } catch {
    return {};
  }
}

// ── 配置读写（持久化到 profile 的 cordis.patch.yml）────────────────────────
//
// DSH 的插件配置持久位置就是 profile 的 patch 层（config-editor 写同一个文件）。
// 这里只改自己这一条目的 config，写成单行 JSON —— YAML 是 JSON 超集，解析无需额外依赖。

const PROFILE_PATCH_FILE = join(HOME, 'profiles', 'desktop', 'cordis.patch.yml');

export function normalizeSettings(input, base) {
  const source = input && typeof input === 'object' ? input : {};
  const merged = { ...base };

  // 逐项自定义处理方式：{ <规则id>: 'block' | 'warn' | 'pass' }。非法值直接丢弃。
  if (source.levelOverrides && typeof source.levelOverrides === 'object' && !Array.isArray(source.levelOverrides)) {
    const cleaned = {};
    for (const [ruleId, level] of Object.entries(source.levelOverrides)) {
      if (typeof ruleId !== 'string' || ruleId === '') continue;
      if (level === 'block' || level === 'warn' || level === 'pass') cleaned[ruleId] = level;
    }
    merged.levelOverrides = cleaned;
  }

  if (typeof source.preflightEnabled === 'boolean') merged.preflightEnabled = source.preflightEnabled;
  if (typeof source.blockOnWarn === 'boolean') merged.blockOnWarn = source.blockOnWarn;

  if (Array.isArray(source.registries)) {
    const cleaned = [...new Set(source.registries
      .filter((entry) => typeof entry === 'string')
      .map((entry) => entry.trim().replace(/\/+$/, ''))
      .filter((entry) => /^https?:\/\/[^\s]+$/.test(entry)))];
    if (cleaned.length === 0) throw new Error('至少保留一个 http(s) 注册表地址');
    merged.registries = cleaned;
  }

  if (source.lookupTimeoutMs !== undefined) {
    const value = Number(source.lookupTimeoutMs);
    if (!Number.isFinite(value) || value < 1000 || value > 60000) throw new Error('超时需在 1000–60000 ms 之间');
    merged.lookupTimeoutMs = Math.round(value);
  }

  if (source.lookupAttempts !== undefined) {
    const value = Number(source.lookupAttempts);
    if (!Number.isFinite(value) || value < 1 || value > 5) throw new Error('重试次数需在 1–5 之间');
    merged.lookupAttempts = Math.round(value);
  }

  if (Array.isArray(source.knownBad)) {
    merged.knownBad = [...new Set(source.knownBad
      .filter((entry) => typeof entry === 'string')
      .map((entry) => entry.trim())
      .filter(Boolean))];
  }

  if (Array.isArray(source.maliciousPackages)) {
    merged.maliciousPackages = [...new Set(source.maliciousPackages
      .filter((entry) => typeof entry === 'string')
      .map((entry) => entry.trim())
      .filter(Boolean))];
  }

  return merged;
}

function renderConfigBlock(config) {
  // 必须覆盖 normalizeSettings 支持的**全部**字段。
  // 早前只写了 6 个，导致 maliciousPackages / levelOverrides / confirmTimeoutMs
  // 保存后不落盘 —— 重启即丢，用户以为设置没生效。
  const ordered = {
    preflightEnabled: config.preflightEnabled,
    blockOnWarn: config.blockOnWarn,
    registries: config.registries,
    lookupTimeoutMs: config.lookupTimeoutMs,
    lookupAttempts: config.lookupAttempts,
    knownBad: config.knownBad,
    maliciousPackages: Array.isArray(config.maliciousPackages) ? config.maliciousPackages : [],
    levelOverrides:
      config.levelOverrides && typeof config.levelOverrides === 'object' && !Array.isArray(config.levelOverrides)
        ? config.levelOverrides
        : {},
    confirmTimeoutMs: Number.isFinite(config.confirmTimeoutMs) ? config.confirmTimeoutMs : 180000,
  };
  return `  config: ${JSON.stringify(ordered)}`;
}

/// 把自己这一条目的 config 写进 profile patch（不存在则追加），返回 updated | appended。
export async function writeProfileConfig(file, config) {
  const exists = existsSync(file);
  const text = exists ? await readFile(file, 'utf8') : '';
  const lines = text.length > 0 ? text.split('\n') : [];

  // 匹配要宽松：用户可能写成 id: "checkup"、id: checkup   # 备注，
  // 旧的严格正则认不出就会追加第二条重复条目。
  const ID_LINE = /^-\s*id:\s*["']?checkup["']?\s*(?:#.*)?$/;
  const start = lines.findIndex((line) => ID_LINE.test(line));
  if (start === -1) {
    const tail = text.replace(/\s*$/, '');
    const appended = `${tail}${tail ? '\n' : ''}- id: checkup\n  name: dsh-checkup\n${renderConfigBlock(config)}\n`;
    // 覆盖前留一份备份，写坏了还能捞回来。
    if (exists) await copyFile(file, `${file}.checkup.bak`).catch(() => {});
    await writeFile(file, appended, { mode: 0o600 });
    return 'appended';
  }

  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^-\s/.test(lines[index])) {
      end = index;
      break;
    }
  }

  const entry = lines.slice(start, end);
  const nameLine = entry.find((line) => /^\s*name:/.test(line));
  const rest = [entry[0]];
  if (nameLine) rest.push(nameLine);
  rest.push(renderConfigBlock(config));

  const next = [...lines.slice(0, start), ...rest, ...lines.slice(end)].join('\n');
  await copyFile(file, `${file}.checkup.bak`).catch(() => {});
  await writeFile(file, next.endsWith('\n') ? next : `${next}\n`, { mode: 0o600 });
  return 'updated';
}

// ── 插件入口 ────────────────────────────────────────────────────────────────

export function apply(ctx, config) {
  moduleLogger = ctx?.logger || null;
  const settings = {
    preflightEnabled: config?.preflightEnabled !== false,
    registries: Array.isArray(config?.registries) && config.registries.length ? [...config.registries] : [...DEFAULT_REGISTRIES],
    lookupTimeoutMs: Number.isFinite(config?.lookupTimeoutMs) ? config.lookupTimeoutMs : 8000,
    lookupAttempts: Number.isFinite(config?.lookupAttempts) ? config.lookupAttempts : 2,
    knownBad: Array.isArray(config?.knownBad) ? [...config.knownBad] : [],
    // 安全性：命中的依赖包名（如 ["evil-pkg", "@bad/scoped"]）直接判恶意。
    maliciousPackages: Array.isArray(config?.maliciousPackages) ? [...config.maliciousPackages] : [],
    blockOnWarn: config?.blockOnWarn === true,
    // 逐项自定义处理方式：{ <规则id>: 'block' | 'warn' | 'pass' }，空对象 = 全部按规则默认。
    levelOverrides:
      config?.levelOverrides && typeof config.levelOverrides === 'object' && !Array.isArray(config.levelOverrides)
        ? { ...config.levelOverrides }
        : {},
    // 市场点安装后，面板确认的最长等待时间（超时按拒绝处理）。
    confirmTimeoutMs: Number.isFinite(config?.confirmTimeoutMs) ? config.confirmTimeoutMs : 180000,
  };

  const decide = async (spec) => {
    const report = await runCheck(spec, settings);
    if (settings.blockOnWarn && report.warned > 0) report.ok = false;
    report.preflightEnabled = settings.preflightEnabled;
    await recordReport(report);
    return report;
  };

  // 面板自己的安装入口用：绕过拦截器直接调用原方法（检查已在面板里做过）。
  let invokeInstall = null;
  // 最近一次「检查通过」的 spec / 时间 / 一次性 token。
  // 安装接口必须同时命中这三项才放行：只凭 spec 会让「谁先调 /check 谁就能装」成立。
  let approved = null;

  // 「市场点安装 → 先看检查面板」的核心：把这次安装挂起，等面板确认。
  // pending 里的每一项都持有原始 installBundle 的 resolve/reject。
  let pendingSeq = 0;
  const pending = new Map();

  function createPending(spec, report, run, confirmTimeoutMs) {
    const id = `p${Date.now()}-${++pendingSeq}`;
    let timer;
    const entry = {
      id,
      spec,
      report,
      createdAt: Date.now(),
      // 面板确认：真正执行安装
      confirm: () => {
        clearTimeout(timer);
        if (!pending.has(id)) return false;
        pending.delete(id);
        Promise.resolve()
          .then(() => run())
          .then(entry.resolve, entry.reject);
        return true;
      },
      // 面板放弃 / 超时：让市场的安装请求以明确原因失败
      cancel: () => {
        clearTimeout(timer);
        if (!pending.has(id)) return false;
        pending.delete(id);
        entry.reject(new CheckupBlocked(report));
        return true;
      },
      resolve: null,
      reject: null,
    };
    return new Promise((resolve, reject) => {
      entry.resolve = resolve;
      entry.reject = reject;
      pending.set(id, entry);
      timer = setTimeout(() => {
        if (!pending.has(id)) return;
        pending.delete(id);
        reject(new CheckupBlocked(report));
      }, Number.isFinite(confirmTimeoutMs) ? confirmTimeoutMs : 180000);
    });
  }

  // 0) 实时哨兵：skill / MCP 安装不走 installBundle（军械库直写目录与 patch 文件），
  //    这里 watch 文件系统兜底。纯 fs 依赖，不需要任何可选服务。
  // #7 改名遗留：把旧状态目录并进新位置后删掉。
  void migrateLegacyStateDir().catch((error) =>
    ctx.logger?.warn?.('checkup: 旧状态迁移失败：' + (error?.message || error)),
  );

  const sentinel = new InstallSentinel({
    skillsRoots: [SKILLS_ROOT, AGENTS_SKILLS_ROOT],
    patchFile: PROFILE_PATCH,
    quarantineDir: QUARANTINE_DIR,
    checkSkillDir,
    checkMcpConfig: (config, options) => checkMcpConfig(config, { ...options }),
    readMcpEntries: () => readMcpEntries(),
    logger: ctx.logger,
  });
  void sentinel.start().catch((error) => ctx.logger?.warn?.(`checkup: 哨兵启动失败：${error?.message || error}`));
  ctx.effect(() => () => sentinel.stop());

  // 1) 拦截安装（preflightEnabled=false 时只记录、不阻断）
  ctx.inject(['pluginManager'], (pmCtx) => {
    const manager = pmCtx.pluginManager;
    if (!manager || typeof manager.installBundle !== 'function') {
      ctx.logger?.warn?.('checkup: pluginManager.installBundle 不可用，跳过拦截');
      return;
    }
    const original = manager.installBundle;
    const guarded = async function guardedInstall(spec, ...rest) {
      if (!settings.preflightEnabled) return original.call(manager, spec, ...rest);
      const report = await decide(spec);
      // 所有经过拦截的安装都先交给面板确认：通过也要用户看见「✅ 检查通过」再点开始安装。
      return createPending(spec, report, () => original.call(manager, spec, ...rest), settings.confirmTimeoutMs);
    };
    manager.installBundle = guarded;
    invokeInstall = (spec, ...rest) => original.call(manager, spec, ...rest);
    pmCtx.effect(() => () => {
      if (manager.installBundle === guarded) manager.installBundle = original;
      invokeInstall = null;
      for (const entry of pending.values()) entry.cancel();
      pending.clear();
    });
    ctx.logger?.info?.('checkup: 已接上安装拦截（挂起等待面板确认）');
  });

  // 2) 面板数据 + 手动预检
  ctx.inject(['webServer'], (wsCtx) => {
    const ws = wsCtx.webServer;
    if (!ws || typeof ws.register !== 'function') return;

    ws.register(
      jsonRoute('/api-checkup/state', async () => {
        const env = await probeEnvironment();
        const entries = await readHistory();
        return [
          200,
          {
            ok: true,
            env: {
              dshVersion: env.dshVersion,
              dshVersionKnown: env.dshVersionKnown,
              nodeVersion: env.nodeVersion,
              clientPackages: env.availableClientPackages.length,
              bundles: env.profileBundles.length,
            },
            rules: RULE_IDS,
            categories: CATEGORIES,
            config: { ...settings },
            configFile: PROFILE_PATCH_FILE,
            history: entries,
          },
        ];
      }),
    );

    ws.register(
      jsonRoute('/api-checkup/config', async (req) => {
        if (req.method === 'POST') {
          const body = await readBody(req);
          let next;
          try {
            next = normalizeSettings(body, settings);
          } catch (error) {
            return [400, { ok: false, error: error instanceof Error ? error.message : String(error) }];
          }

          try {
            if (existsSync(PROFILE_PATCH_FILE)) {
              await writeFile(`${PROFILE_PATCH_FILE}.checkup.bak`, await readFile(PROFILE_PATCH_FILE));
            }
          } catch {
            // 备份失败不阻塞保存
          }

          let saved;
          try {
            saved = await writeProfileConfig(PROFILE_PATCH_FILE, next);
          } catch (error) {
            return [500, { ok: false, error: `写入配置失败：${error instanceof Error ? error.message : String(error)}` }];
          }

          Object.assign(settings, next);
          return [200, { ok: true, config: { ...settings }, saved, file: PROFILE_PATCH_FILE }];
        }
        return [200, { ok: true, config: { ...settings }, file: PROFILE_PATCH_FILE }];
      }),
    );

    // 面板轮询：是否有被挂起的安装等待确认（市场点安装后立刻出现检查面板）。
    ws.register(
      jsonRoute('/api-checkup/pending', async () => {
        const entries = [...pending.values()].sort((a, b) => b.createdAt - a.createdAt);
        const latest = entries[0];
        if (!latest) return [200, { ok: true, pending: null }];
        return [
          200,
          {
            ok: true,
            pending: {
              id: latest.id,
              spec: latest.spec,
              createdAt: latest.createdAt,
              report: latest.report,
            },
          },
        ];
      }),
    );

    // 面板按钮：确认安装 / 放弃安装。
    ws.register(
      jsonRoute('/api-checkup/confirm', async (req) => {
        const body = await readBody(req);
        const id = typeof body.id === 'string' ? body.id : '';
        const action = body.action === 'cancel' ? 'cancel' : 'install';
        const entry = pending.get(id);
        if (!entry) return [404, { ok: false, error: '该安装请求已过期或已完成' }];
        const handled = action === 'install' ? entry.confirm() : entry.cancel();
        return [200, { ok: handled, action, spec: entry.spec }];
      }),
    );

    // Skill 检查：skill 没有安装 API（就是一个目录），所以提供「装前检查目录」。
    ws.register(
      jsonRoute('/api-checkup/check-skill', async (req) => {
        const body = await readBody(req);
        const dirPath = typeof body.path === 'string' ? body.path.trim() : '';
        if (!dirPath) return [400, { ok: false, error: '缺少 path' }];
        // #3 只允许技能根及其子目录：这个接口会递归读目录里的文本文件，
        // 不加限制就变成「传任意路径读本机目录」。
        if (!isUnderSkillRoot(dirPath)) {
          return [403, { ok: false, error: '只允许检查 ~/.dsh/skills 或 ~/.agents/skills 下的目录' }];
        }
        if (!existsSync(dirPath)) return [404, { ok: false, error: `目录不存在：${dirPath}` }];
        const report = await checkSkillDir(dirPath);
        return [200, { ok: true, report, path: dirPath }];
      }),
    );

    // MCP 检查：一条准备写入 profile 的 MCP 配置。
    ws.register(
      jsonRoute('/api-checkup/check-mcp', async (req) => {
        const body = await readBody(req);
        const config = body && typeof body.config === 'object' ? body.config : null;
        if (!config) return [400, { ok: false, error: '缺少 config' }];
        const report = await checkMcpConfig(config, {
          registries: settings.registries,
          lookupTimeoutMs: settings.lookupTimeoutMs,
          lookupAttempts: settings.lookupAttempts,
          knownBad: settings.knownBad,
          maliciousPackages: settings.maliciousPackages,
        });
        return [200, { ok: true, report }];
      }),
    );

    // 专家检查：一条准备写进 profile 的 dsh-agent-preset 配置。
    ws.register(
      jsonRoute('/api-checkup/check-expert', async (req) => {
        const body = await readBody(req);
        const candidate = body && typeof body.candidate === 'object' ? body.candidate : null;
        if (!candidate) return [400, { ok: false, error: '缺少 candidate' }];
        const report = await checkExpertConfig(candidate, {
          selfId: typeof body.selfId === 'string' ? body.selfId : '',
        });
        return [200, { ok: true, report }];
      }),
    );

    // 已装项体检：扫 ~/.dsh/skills 与 profile 里所有 MCP 条目。
    ws.register(
      jsonRoute('/api-checkup/inventory', async () => {
        const skills = [];
        if (existsSync(SKILLS_ROOT)) {
          for (const entry of await readdir(SKILLS_ROOT, { withFileTypes: true }).catch(() => [])) {
            if (!entry.isDirectory()) continue;
            const dir = join(SKILLS_ROOT, entry.name);
            const report = await checkSkillDir(dir);
            skills.push({
              name: entry.name,
              path: dir,
              ok: report.ok,
              blocked: report.blocked,
              warned: report.warned,
              passed: report.passed,
              checks: report.checks.filter((c) => c.level !== 'pass'),
            });
          }
        }

        const mcpEntries = await readMcpEntries();
        const mcp = [];
        for (const item of mcpEntries) {
          const report = await checkMcpConfig(item.config, {
            existingServerNames: mcpEntries.map((x) => x.config.serverName).filter(Boolean),
            // 这里检查的是已经写进 patch 的条目：重复计数要减掉自己那一份。
            candidatePersisted: true,
            knownBad: settings.knownBad,
          });
          mcp.push({
            id: item.id,
            config: item.config,
            ok: report.ok,
            blocked: report.blocked,
            warned: report.warned,
            passed: report.passed,
            checks: report.checks.filter((c) => c.level !== 'pass'),
          });
        }

        return [200, { ok: true, skills, mcp, skillsRoot: SKILLS_ROOT }];
      }),
    );

    // 军械库四类检查：连接器 / 技能 / 插件 / 专家
    ws.register(
      jsonRoute('/api-checkup/armory', async () => {
        const items = await collectArmory();
        const checks = checkArmory(items);
        return [
          200,
          {
            ok: true,
            checks,
            byKind: summarizeArmory(checks),
            kinds: ARMORY_KINDS,
            rules: ARMORY_RULE_IDS,
            counts: {
              connector: items.connectors.length,
              skill: items.skills.length,
              plugin: items.plugins.length,
              expert: items.experts.length,
            },
          },
        ];
      }),
    );

    // 环境体检：已装插件 / skill / MCP 的保留或卸载建议
    ws.register(
      jsonRoute('/api-checkup/audit', async () => {
        const report = await runAudit();
        return [200, { ok: true, report }];
      }),
    );

    // 实时哨兵：拦截事件 + 隔离区内容（面板轮询展示）。
    ws.register(
      jsonRoute('/api-checkup/guard', async () => {
        const quarantined = await sentinel.listQuarantined();
        return [200, { ok: true, events: [...sentinel.events], quarantined, roots: [SKILLS_ROOT, AGENTS_SKILLS_ROOT] }];
      }),
    );

    // 隔离区处置：放行（移回 skill 根）或删除。
    ws.register(
      jsonRoute('/api-checkup/guard/release', async (req) => {
        if (req.method !== 'POST') return [405, { ok: false, error: '仅支持 POST' }];
        const body = await readBody(req);
        const dir = typeof body.dir === 'string' ? body.dir.trim() : '';
        const action = body.action === 'delete' ? 'delete' : 'restore';
        if (!dir) return [400, { ok: false, error: '缺少 dir' }];
        // 二次校验（哨兵内部也会校验一次）：路由层是外部入口，别把用户路径直接透传下去。
        const quarantineRoot = resolve(sentinel.quarantineDir || '');
        const targetDir = resolve(dir);
        if (quarantineRoot === '' || (targetDir !== quarantineRoot && !targetDir.startsWith(quarantineRoot + sep))) {
          return [403, { ok: false, error: '只允许操作隔离区内的目录' }];
        }
        try {
          const result = await sentinel.releaseQuarantined(dir, action);
          return [200, { ok: true, ...result }];
        } catch (error) {
          return [400, { ok: false, error: error instanceof Error ? error.message : String(error) }];
        }
      }),
    );

    ws.register(
      jsonRoute('/api-checkup/check', async (req) => {
        const body = await readBody(req);
        const spec = typeof body.spec === 'string' ? body.spec : '';
        if (!spec.trim()) return [400, { ok: false, error: '缺少 spec' }];
        const report = await decide(spec);
        if (report.ok) approved = { spec: spec.trim(), at: Date.now(), token: randomUUID() };
        // 只有本轮检查通过才发 token；面板要拿它才能调 /install。
        return [200, { ok: true, report, approvalToken: report.ok ? approved.token : null }];
      }),
    );

    // 面板的「开始安装插件」：只在检查通过、且刚通过（10 分钟内同一 spec）时才执行。
    ws.register(
      jsonRoute('/api-checkup/install', async (req) => {
        const body = await readBody(req);
        const spec = typeof body.spec === 'string' ? body.spec : '';
        if (!spec.trim()) return [400, { ok: false, error: '缺少 spec' }];

        const report = await decide(spec);
        if (!report.ok) return [409, { ok: false, blocked: true, report, error: '检查未通过，未执行安装' }];

        const token = typeof body.token === 'string' ? body.token.trim() : '';
        const fresh =
          approved &&
          approved.spec === spec.trim() &&
          token !== '' &&
          approved.token === token &&
          Date.now() - approved.at < 10 * 60 * 1000;
        if (!fresh) return [409, { ok: false, stale: true, report, error: '请先在检查面板完成检查，再点「开始安装插件」' }];

        if (typeof invokeInstall !== 'function') {
          return [503, { ok: false, report, error: '安装服务未就绪（pluginManager 不可用）' }];
        }

        approved = null;
        try {
          const result = await invokeInstall(spec);
          return [200, { ok: true, report, spec: spec.trim(), result: { accepted: true, detail: describeInstallResult(result) } }];
        } catch (error) {
          return [500, { ok: false, report, error: error instanceof Error ? error.message : String(error) }];
        }
      }),
    );
  });
}

/// 安装返回值只取用户能理解的部分（形状由宿主决定，不做假设）。
function describeInstallResult(result) {
  if (!result || typeof result !== 'object') return '已提交安装';
  if (typeof result.status === 'string') return `宿主动作：${result.status}`;
  if (typeof result.id === 'string') return `安装任务：${result.id}`;
  return '已提交安装';
}
