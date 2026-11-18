import { basename, dirname, join, relative, resolve } from 'node:path';
import { RE2JS } from './build/re2js-unicode.mjs';

const escape = character => character.replace(/[\\.*+?()[\]{}|^$]/g, '\\$&');
// rg's glob engine matches bytes; this bijection keeps one regex scalar per UTF-8 byte.
const byteString = text => Buffer.from(text, 'utf8').toString('latin1');

// Glob matching is against the current entry. Descendant exclusion is enforced
// by walking/pruning directories, so an explicit root does not inherit a pruned parent.
function globRule(pattern, ignoreFile = false) {
  pattern = byteString(pattern);
  while (pattern.endsWith(' ') && !pattern.endsWith('\\ ')) pattern = pattern.slice(0, -1);
  if (!pattern || (ignoreFile && pattern[0] === '#')) return;
  const negative = pattern[0] === '!';
  if (negative) pattern = pattern.slice(1);
  if (!pattern) return;
  const directoryOnly = pattern.endsWith('/');
  if (directoryOnly) pattern = pattern.slice(0, -1);
  const rooted = pattern.startsWith('/');
  if (rooted) pattern = pattern.slice(1);
  const basenameOnly = !rooted && !pattern.includes('/');
  let i = 0;
  function sequence(inBrace = false) {
    let out = '';
    while (i < pattern.length) {
      const char = pattern[i++];
      if (char === '}') { if (!inBrace) throw new Error('rg: glob 有未配对的 }'); i--; break; }
      if (char === ',' && inBrace) { i--; break; }
      if (char === '\\') {
        if (i === pattern.length) throw new Error('rg: glob 有不完整的转义');
        out += escape(pattern[i++]);
      } else if (char === '*') {
        const before = i - 2;
        if (pattern[i] === '*' && (before < 0 || pattern[before] === '/') && (i + 1 === pattern.length || pattern[i + 1] === '/')) {
          i++;
          if (pattern[i] === '/') { i++; out += '(?:.*/)?'; }
          else out += '.*';
        } else out += '[^/]*';
      } else if (char === '?') out += '[^/]';
      else if (char === '[') {
        let cls = '';
        if (pattern[i] === '!' || pattern[i] === '^') { cls += '^'; i++; }
        if (pattern[i] === ']') { cls += '\\]'; i++; }
        let closed = false;
        while (i < pattern.length) {
          const c = pattern[i++];
          if (c === ']') { closed = true; break; }
          // glob classes treat backslash as a member, not as a regex escape.
          if (c === '\\') cls += '\\\\';
          else if (c === '[' || c === '^') cls += '\\' + c;
          else cls += c;
        }
        if (!closed) throw new Error('rg: glob 有未闭合的字符类');
        out += '[' + cls + ']';
      } else if (char === '{') {
        const parts = [];
        while (true) {
          parts.push(sequence(true));
          if (pattern[i] === '}') { i++; break; }
          if (pattern[i] !== ',') throw new Error('rg: glob 有未闭合的花括号');
          i++;
        }
        out += '(?:' + parts.join('|') + ')';
      } else out += escape(char);
    }
    return out;
  }
  const regex = RE2JS.compile('^(?:' + sequence() + ')$', RE2JS.DOTALL);
  return { negative, matches(path, directory) { return (!directoryOnly || directory) && regex.matches(byteString(basenameOnly ? basename(path) : path.replace(/^\.\//, ''))); } };
}

function lastMatch(rules, absolute, directory) {
  for (let i = rules.length - 1; i >= 0; i--) {
    const { base, rule } = rules[i], path = relative(base, absolute);
    if (!path.startsWith('../') && rule.matches(path, directory)) return rule.negative;
  }
}

export function validateRgGlobs(globs) { for (const glob of globs) globRule(glob); }

class SelectionLimitError extends Error {}
const filesystemErrorCodes = new Set(['EACCES', 'EPERM', 'ENOENT', 'ENOTDIR', 'ELOOP', 'EMFILE', 'ENFILE', 'EIO', 'ESTALE']);
export function isRgFilesystemError(error) {
  const code = typeof error?.code === 'string' ? error.code : /^([A-Z]+):/.exec(error?.message ?? '')?.[1];
  return filesystemErrorCodes.has(code);
}

export function rgDiagnostic(error) {
  const message = String(error?.message ?? error).replace(/^rg: /, '');
  return `rg: ${message}\n`;
}

export async function selectRgFiles(ctx, options, globs, roots) {
  const overrides = globs.map(pattern => globRule(pattern)).filter(Boolean);
  const hasPositive = overrides.some(rule => !rule.negative);
  const hidden = options.includes('--hidden'), noIgnore = options.includes('--no-ignore');
  const contexts = new Map(), result = [], diagnostics = [];
  const diagnostic = error => diagnostics.push(rgDiagnostic(error));
  let visited = 0;
  const checkpoint = () => { if (++visited > ctx.limits.maxGlobOperations) throw new SelectionLimitError(`遍历检查超过鸿蒙本机上限（${ctx.limits.maxGlobOperations}）；结果不完整`); };
  async function readRules(base, name) {
    const path = join(base, name);
    if (!await ctx.fs.exists(path)) return [];
    const text = await ctx.fs.readFile(path, 'utf8');
    return text.split(/\r?\n/).map(line => globRule(line, true)).filter(Boolean).map(rule => ({ base, rule }));
  }
  async function context(base) {
    if (contexts.has(base)) return contexts.get(base);
    const parent = dirname(base);
    const inherited = parent === base ? { repo: false, rg: [], ignore: [], git: [] } : await context(parent);
    const value = { repo: inherited.repo, rg: inherited.rg, ignore: inherited.ignore, git: inherited.git };
    if (!noIgnore) {
      if (await ctx.fs.exists(join(base, '.git'))) {
        const stat = await ctx.fs.stat(join(base, '.git'));
        if (!stat.isDirectory && !stat.isFile) throw new Error('rg: .git 不是普通文件或目录');
        value.repo = true;
        // Worktree/submodule gitdir can lie outside the authorized workspace.
        // A .git file starts a repository boundary; do not follow its pointer.
        value.git = stat.isDirectory ? await readRules(base, '.git/info/exclude') : [];
      }
      value.rg = [...value.rg, ...await readRules(base, '.rgignore')];
      value.ignore = [...value.ignore, ...await readRules(base, '.ignore')];
      if (value.repo) value.git = [...value.git, ...await readRules(base, '.gitignore')];
    }
    contexts.set(base, value);
    return value;
  }
  function decision(path, directory, rules) {
    let override;
    const fromCwd = relative(ctx.cwd, path);
    for (const rule of overrides) if (rule.matches(fromCwd, directory)) override = !rule.negative;
    if (override !== undefined) return override;
    if (!directory && hasPositive) return false;
    let ignored;
    for (const list of [rules.rg, rules.ignore, rules.git]) {
      const negative = lastMatch(list, path, directory);
      if (negative !== undefined) { ignored = !negative; break; }
    }
    if (ignored === true) return false;
    if (basename(path).startsWith('.') && !hidden && ignored !== false) return false;
    return true;
  }
  async function walk(path, display) {
    checkpoint();
    let rules, entries;
    try {
      rules = await context(path);
      entries = ctx.fs.readdirWithFileTypes ? await ctx.fs.readdirWithFileTypes(path) : await Promise.all((await ctx.fs.readdir(path)).map(async name => ({ name, ...await ctx.fs.lstat(join(path, name)) })));
    } catch (error) {
      // An unreadable directory does not discard files selected elsewhere.
      // A resource budget still stops the entire traversal below.
      if (!isRgFilesystemError(error)) throw error;
      diagnostic(error);
      return;
    }
    for (const entry of entries) {
      checkpoint();
      if (entry.isSymbolicLink) continue;
      const absolute = join(path, entry.name);
      if (!decision(absolute, entry.isDirectory, rules)) continue;
      const shown = display === '.' ? entry.name : display === './' ? './' + entry.name : display.replace(/\/$/, '') + '/' + entry.name;
      if (entry.isDirectory) await walk(absolute, shown);
      else if (entry.isFile) {
        if (result.length >= ctx.limits.maxArrayElements) throw new SelectionLimitError(`候选文件数超过鸿蒙本机上限（${ctx.limits.maxArrayElements}）；结果不完整`);
        result.push(shown);
      }
    }
  }
  try {
    for (const root of roots.length ? roots : ['.']) await walk(resolve(ctx.cwd, root), root);
  } catch (error) {
    if (!(error instanceof SelectionLimitError)) throw error;
    diagnostic(error);
  }
  return { stdout: result.join('\0') + (result.length ? '\0' : ''), stderr: diagnostics.join(''), exitCode: diagnostics.length ? 2 : result.length ? 0 : 1 };
}
