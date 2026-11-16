import git from 'isomorphic-git';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';
import { createHash } from 'node:crypto';
import { createGitFs, gitStorage, repository, normalizeGitFilesystem, requireGitOwnership, isGitOwnershipError } from './git-fs.mjs';
import { readIndex, stageTree } from './git-index.mjs';
import { changes, formatChanges, objectBytes, treeEntries, quoteGitPath } from './git-diff.mjs';
import { normalizeAutoCrlf } from './git-eol.mjs';

const unavailable = '这个命令在鸿蒙本机不可用，可以连接电脑执行';
const missing = error => error?.code === 'ENOENT' || error?.code === 'ENOTDIR';
const abort = ctx => ctx.signal?.throwIfAborted();
const unsupported = message => { throw Object.assign(new Error(`${message}；${unavailable}`), { exitCode: 127 }); };
const fault = message => { throw Object.assign(new Error(message), { exitCode: 128 }); };
const output = (stdout = '', stderr = '', exitCode = 0) => ({ stdout, stderr, exitCode });
const below = (root, path) => path === root || path.startsWith(root + sep);
const sort = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const envObject = ctx => ctx.env instanceof Map ? Object.fromEntries(ctx.env) : (ctx.env ?? {});

async function quoteHighBytes(options) {
  const value = await git.getConfig({ ...options, path: 'core.quotePath' });
  if (value === undefined) return true;
  const text = String(value).trim().toLowerCase();
  if (['true', 'yes', 'on'].includes(text)) return true;
  if (['false', 'no', 'off', ''].includes(text)) return false;
  // Git accepts signed/base-prefixed integers, with its ordinary unit suffixes.
  const match = /^([+-]?)(0x[0-9a-f]+|0[0-7]*|[1-9][0-9]*)([kmg]?)$/.exec(text);
  if (match) {
    const digits = match[2], base = /^0[0-7]+$/.test(digits) ? '0o' + digits.slice(1) : digits;
    const number = BigInt(base) * (match[1] === '-' ? -1n : 1n) * (1024n ** BigInt(match[3] ? 'kmg'.indexOf(match[3]) + 1 : 0));
    if (number >= -2147483648n && number <= 2147483647n) return number !== 0n;
  }
  fault('bad boolean config value for core.quotePath');
}

function splitPaths(args) {
  const separator = args.indexOf('--');
  return separator < 0 ? { flags: args, paths: [] } : { flags: args.slice(0, separator), paths: args.slice(separator + 1) };
}
function filePath(ctx, options, path) {
  if (path.startsWith(':') || /[*?\[\]]/.test(path)) unsupported('Git pathspec 目前只支持字面路径/目录和快照专用 exclude；shell glob 请先展开');
  const absolute = resolve(ctx.cwd, path);
  if (!below(options.dir, absolute)) fault('Git path is outside this repository');
  const result = relative(options.dir, absolute).split(sep).join('/') || '.';
  if (result.split('/').includes('.git')) fault('Git work-tree paths cannot name .git metadata');
  return result;
}
function pathMatches(path, selected) { return selected === '.' || path === selected || path.startsWith(selected + '/'); }
async function indexEntries(options) {
  return new Map((await readIndex(options)).filter(entry => entry.stage === 0).map(entry =>
    [entry.path, { ...entry, type: entry.mode === 0o160000 ? 'commit' : 'blob' }]));
}
async function headEntries(options, ref = 'HEAD') {
  try { return await treeEntries(git, options, ref); }
  catch (error) {
    if (ref === 'HEAD' && error.code === 'NotFoundError') return new Map();
    throw error;
  }
}

async function addFiles(args, ctx, options, settings = {}) {
  const owner = requireGitOwnership(ctx);
  const target = options.indexFile ?? join(options.gitdir, 'index');
  await ctx.fs.mkdir(dirname(target), { recursive: true });
  let bytes;
  try { bytes = await ctx.fs.readFileBuffer(target); }
  catch (error) {
    if (!missing(error)) throw error;
    const header = Buffer.alloc(12); header.write('DIRC'); header.writeUInt32BE(2, 4);
    bytes = Buffer.concat([header, createHash('sha1').update(header).digest()]);
  }
  // reserve -> exclusive create -> durable identify -> seed write is entirely
  // parent-owned, including a result that arrives after this Worker is killed.
  const resource = await owner.createIndex({ target, content: Buffer.from(bytes), mode: 0o600 });
  let active = true, failure;
  try {
    const transaction = { ...options, indexFile: resource.path, ownedIndex: resource, cache: {} };
    transaction.fs = createGitFs(ctx, transaction);
    const result = await addFilesToIndex(args, ctx, transaction, settings);
    abort(ctx);
    if (!result.skipIndexWrite) {
      try { await owner.commitIndex(resource.id); active = false; }
      catch (error) {
        // A committed final is never rolled back. The owner's mandatory finish
        // barrier retains any failed cleanup after a successful native rename.
        if (error.committed) active = false;
        throw error;
      }
    }
    delete result.skipIndexWrite;
    return result;
  } catch (error) { failure = error; throw error; }
  finally {
    if (active) {
      try { await owner.releaseIndex(resource.id); }
      catch (error) {
        if (!failure) throw error;
        throw Object.assign(new AggregateError([failure, error],
          `${failure.message}; Git index cleanup also failed: ${error.message}`, { cause: failure }),
          { code: error.code ?? failure.code });
      }
    }
  }
}

async function addFilesToIndex(args, ctx, options, { onlyTracked = false } = {}) {
  const { flags, paths: afterDash } = splitPaths(args);
  let all = false, ignoreErrors = false, force = false;
  const paths = [...afterDash];
  for (const arg of flags) {
    if (arg === '-A' || arg === '--all') all = true;
    else if (arg === '--ignore-errors') ignoreErrors = true;
    else if (arg === '-f' || arg === '--force') force = true;
    else if (arg === '-u' || arg === '--update') { all = true; onlyTracked = true; }
    else if (arg.startsWith('-')) unsupported(`git add 参数 ${arg} 未实现`);
    else paths.push(arg);
  }
  if (!paths.length && !all) return { ...output('', 'Nothing specified, nothing added.\n'), skipIndexWrite: true };
  const excludes = paths.filter(path => path.startsWith(':(exclude)')).map(path => filePath(ctx, options, path.slice(10)));
  const selected = paths.filter(path => !path.startsWith(':(exclude)')).map(path => filePath(ctx, options, path));
  if (!selected.length) selected.push(all ? '.' : filePath(ctx, options, '.'));
  const wanted = path => selected.some(base => pathMatches(path, base)) && !excludes.some(base => pathMatches(path, base));
  const original = await readIndex(options), tracked = new Map(original.map(entry => [entry.path, entry]));
  for (const path of selected) if (path !== '.' && ![...tracked.keys()].some(key => pathMatches(key, path))) {
    try { await ctx.fs.lstat(join(options.dir, path)); }
    catch (error) { if (missing(error)) fault(`pathspec ${JSON.stringify(path)} did not match any files`); throw error; }
  }
  const filemode = String(await git.getConfig({ ...options, path: 'core.filemode' })).toLowerCase() !== 'false';
  const symlinks = String(await git.getConfig({ ...options, path: 'core.symlinks' })).toLowerCase() !== 'false';
  if (!filemode || !symlinks) {
    const base = options.fs.promises;
    options = { ...options, fs: { promises: { ...base, lstat: async path => {
      const stat = await base.lstat(path);
      if (stat.isFile() && below(options.dir, resolve(path)) && !below(options.gitdir, resolve(path))) {
        const old = tracked.get(relative(options.dir, path).split(sep).join('/'));
        if (!symlinks && old?.mode === 0o120000) stat.mode = 0o120000;
        else if (!filemode) stat.mode = old?.mode === 0o100755 ? 0o100755 : 0o100644;
      }
      return stat;
    } } } };
  }
  const present = new Set(); let hadError = false;
  const visit = async path => {
    abort(ctx);
    if (path !== '.' && (path.split('/').includes('.git') || excludes.some(base => pathMatches(path, base)))) return;
    if (!wanted(path) && !selected.some(base => pathMatches(base, path))) return;
    const full = join(options.dir, path);
    // Exclude this exact live resource, never a filename prefix or foreign file.
    if (options.ownedIndex?.path === full) return;
    let info;
    try { info = await ctx.fs.lstat(full); }
    catch (error) { if (missing(error)) return; if (ignoreErrors) { hadError = true; return; } throw error; }
    if (info.isDirectory) {
      if (path !== '.') {
        const trackedBelow = [...tracked.keys()].some(key => key.startsWith(path + '/'));
        // Selection rules apply before recognizing a nested repository. An
        // untracked gitlink is still an untracked path, including under -u.
        if (onlyTracked && !tracked.has(path) && !trackedBelow) return;
        if (!force && !tracked.has(path) && !trackedBelow && await git.isIgnored({ ...options, filepath: path + '/' })) {
          if (selected.includes(path)) throw Object.assign(new Error('Explicitly selected path is ignored; use git add --force to include it'), { exitCode: 1 });
          return;
        }
        let nested = false;
        try { nested = (await ctx.fs.stat(join(full, '.git'))).isDirectory; }
        catch (error) { if (!missing(error)) throw error; }
        // A repository created around files already tracked by the outer
        // repository must not replace those tracked descendants with a gitlink.
        if ((nested && !trackedBelow) || tracked.get(path)?.mode === 0o160000) {
          present.add(path);
          if (nested && wanted(path)) {
            const sub = { ...options, fs: createGitFs(ctx, { gitdir: join(full, '.git') }), dir: full, gitdir: join(full, '.git'), cache: {} };
            const oid = await git.resolveRef({ ...sub, ref: 'HEAD' });
            await git.updateIndex({ ...options, filepath: path, oid, mode: 0o160000, add: true });
          }
          return;
        }
      }
      for (const name of (await ctx.fs.readdir(full)).sort(sort)) await visit(path === '.' ? name : `${path}/${name}`);
      return;
    }
    if (!wanted(path) || (onlyTracked && !tracked.has(path))) return;
    present.add(path);
    if (!force && !tracked.has(path) && await git.isIgnored({ ...options, filepath: path })) {
      if (selected.includes(path)) throw Object.assign(new Error('Explicitly selected path is ignored; use git add --force to include it'), { exitCode: 1 });
      return;
    }
    try { await git.add({ ...options, filepath: path, force: force || tracked.has(path), parallel: false }); }
    catch (error) { if (!ignoreErrors || isGitOwnershipError(error)) throw error; hadError = true; }
  };
  await visit('.');
  for (const [path] of tracked) {
    abort(ctx);
    if (!wanted(path) || present.has(path)) continue;
    try { await ctx.fs.lstat(join(options.dir, path)); }
    catch (error) {
      if (missing(error)) await git.remove({ ...options, filepath: path });
      else if (ignoreErrors) hadError = true;
      else throw error;
    }
  }
  return output('', hadError ? 'Some inaccessible files could not be staged.\n' : '', hadError ? 1 : 0);
}

async function workEntries(ctx, options, tracked) {
  const result = new Map();
  const autocrlf = await git.getConfig({ ...options, path: 'core.autocrlf' });
  const filemode = String(await git.getConfig({ ...options, path: 'core.filemode' })).toLowerCase() !== 'false';
  const symlinks = String(await git.getConfig({ ...options, path: 'core.symlinks' })).toLowerCase() !== 'false';
  for (const [path, staged] of tracked) {
    abort(ctx);
    if (staged.mode === 0o160000) { result.set(path, staged); continue; }
    let info;
    try { info = await ctx.fs.lstat(join(options.dir, path)); }
    catch (error) { if (missing(error)) continue; throw error; }
    if (info.isDirectory) continue;
    let bytes = info.isSymbolicLink ? Buffer.from(await ctx.fs.readlink(join(options.dir, path)))
      : Buffer.from(await ctx.fs.readFileBuffer(join(options.dir, path)));
    const link = info.isSymbolicLink || (!symlinks && staged.mode === 0o120000);
    if (['true', 'input'].includes(autocrlf) && !link) {
      bytes = normalizeAutoCrlf(bytes, await objectBytes(git, options, staged));
    }
    const oid = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
    const executable = filemode ? Boolean(info.mode & 0o111) : staged.mode === 0o100755;
    result.set(path, { path, type: 'blob', mode: link ? 0o120000 : executable ? 0o100755 : 0o100644, oid, bytes });
  }
  return result;
}

async function gitDiff(args, ctx, options, treesOnly = false) {
  const { flags, paths } = splitPaths(args); const refs = [];
  let cached = false, numstat = false, nul = false, nameOnly = false, renames = false;
  for (const arg of flags) {
    if (arg === '--cached' || arg === '--staged') cached = true;
    else if (arg === '--numstat') numstat = true;
    else if (arg === '-z') nul = true;
    else if (arg === '--name-only') nameOnly = true;
    else if (arg === '-M' || arg === '--find-renames') renames = true;
    else if (['-r', '--no-color', '--no-ext-diff', '--no-textconv'].includes(arg)) { /* Supported fixed behavior. */ }
    else if (arg.startsWith('-')) unsupported(`git diff 参数 ${arg} 未实现`);
    else refs.push(arg);
  }
  if (refs.length > 2 || (treesOnly && refs.length !== 2)) unsupported('git diff 需要至多两个 tree-ish');
  let before, after;
  if (refs.length === 2) {
    before = await treeEntries(git, options, refs[0]); after = await treeEntries(git, options, refs[1]);
  } else if (cached) {
    before = await headEntries(options, refs[0] ?? 'HEAD'); after = await indexEntries(options);
  } else {
    const index = await indexEntries(options);
    before = refs.length ? await headEntries(options, refs[0]) : index;
    after = await workEntries(ctx, options, new Map([...before, ...index]));
  }
  if (paths.length) {
    const selected = paths.map(path => filePath(ctx, options, path));
    before = new Map([...before].filter(([path]) => selected.some(base => pathMatches(path, base))));
    after = new Map([...after].filter(([path]) => selected.some(base => pathMatches(path, base))));
  }
  const rows = await changes(git, options, before, after, { renames });
  return output(formatChanges(rows, { numstat, nul, nameOnly,
    quoteHighBytes: await quoteHighBytes(options) }));
}

function authorFrom(ctx, kind) {
  const env = envObject(ctx), result = {};
  if (env[`GIT_${kind}_NAME`]) result.name = env[`GIT_${kind}_NAME`];
  if (env[`GIT_${kind}_EMAIL`]) result.email = env[`GIT_${kind}_EMAIL`];
  if (env[`GIT_${kind}_DATE`]) {
    const date = /^@?(\d+) ([+-])(\d{2})(\d{2})$/.exec(env[`GIT_${kind}_DATE`]);
    if (!date) unsupported('Git 日期只支持 Unix 秒数与时区偏移');
    result.timestamp = Number(date[1]); result.timezoneOffset = (date[2] === '+' ? -1 : 1) * (Number(date[3]) * 60 + Number(date[4]));
  }
  return Object.keys(result).length ? result : undefined;
}

function fetchTransport(ctx) {
  const fetch = ctx.fetch ?? globalThis[Symbol.for('dsh.go.ohos.net')]?.fetch;
  if (typeof fetch !== 'function') unsupported('git clone 需要已安装并验证的 O5 网络传输');
  return { request: async ({ url, method = 'GET', headers = {}, body }) => {
    abort(ctx);
    const iterator = body?.[Symbol.asyncIterator]?.() ?? body?.[Symbol.iterator]?.();
    const stream = iterator ? new ReadableStream({
      async pull(controller) { const item = await iterator.next(); item.done ? controller.close() : controller.enqueue(item.value); },
      async cancel(reason) { await iterator.return?.(reason); },
    }) : undefined;
    const response = await fetch(url, {
      method, headers, body: stream, ...(stream ? { duplex: 'half' } : {}), signal: ctx.signal,
    });
    return { url: response.url, method, statusCode: response.status, statusMessage: response.statusText,
      headers: Object.fromEntries(response.headers), body: response.body ?? (async function* () {})() };
  } };
}

/** just-bash custom command / worker dispatch. No native process or unrestricted fs. */
export async function executeGit(input, context) {
  const args = [...input], ctx = { ...context, fs: normalizeGitFilesystem(context.fs), cwd: resolve(context.cwd) };
  try {
    abort(ctx);
    while (args[0] === '-C') {
      args.shift(); const next = args.shift(); if (next === undefined) unsupported('git -C 缺少目录');
      ctx.cwd = resolve(ctx.cwd, next); if (!(await ctx.fs.stat(ctx.cwd)).isDirectory) fault('git -C target is not a directory');
    }
    if (args[0] === '--version') return output(`git version isomorphic-git/${git.version()} (OHOS subset)\n`);
    const command = args.shift();
    if (command === 'init') {
      let branch = 'main', destination = '.';
      for (let i = 0; i < args.length; ++i) {
        if (args[i] === '-b' || args[i] === '--initial-branch') branch = args[++i] ?? fault('Missing initial branch');
        else if (args[i] === '-q' || args[i] === '--quiet') { /* Output remains small. */ }
        else if (args[i].startsWith('-')) unsupported(`git init 参数 ${args[i]} 未实现`);
        else if (destination === '.') destination = args[i]; else unsupported('git init 只接受一个目录');
      }
      const dir = resolve(ctx.cwd, destination), gitdir = join(dir, '.git');
      await ctx.fs.mkdir(dir, { recursive: true });
      await git.init({ fs: createGitFs(ctx, { gitdir }), dir, gitdir, defaultBranch: branch });
      return output(`Initialized Git repository in ${gitdir}/\n`);
    }
    if (command === 'clone') {
      let depth, ref, singleBranch = false; const positional = [];
      for (let i = 0; i < args.length; ++i) {
        if (args[i] === '--depth') depth = Number(args[++i]);
        else if (args[i] === '-b' || args[i] === '--branch') ref = args[++i];
        else if (args[i] === '--single-branch') singleBranch = true;
        else if (args[i].startsWith('-')) unsupported(`git clone 参数 ${args[i]} 未实现`);
        else positional.push(args[i]);
      }
      if (positional.length < 1 || positional.length > 2) unsupported('git clone 需要 URL 与可选目录');
      let url; try { url = new URL(positional[0]); } catch { unsupported('git clone 只支持 HTTP/HTTPS'); }
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) unsupported('git clone 不支持 SSH、URL 凭证或 credential helper');
      if (depth !== undefined && (!Number.isSafeInteger(depth) || depth < 1)) fault('Invalid clone depth');
      const http = fetchTransport(ctx);
      const dir = resolve(ctx.cwd, positional[1] ?? basename(url.pathname).replace(/\.git$/, ''));
      if (await ctx.fs.exists(dir) && (await ctx.fs.readdir(dir)).length) fault('Clone destination is not empty');
      const owner = requireGitOwnership(ctx);
      if (['createClone', 'commitClone', 'releaseClone'].some(name => typeof owner[name] !== 'function')) {
        throw Object.assign(new Error('Git clone requires main-engine directory ownership'), { code: 'ERR_OHOS_OWNERSHIP_UNAVAILABLE' });
      }
      await ctx.fs.mkdir(dirname(dir), { recursive: true });
      const staging = await owner.createClone({ target: dir });
      try {
        await git.clone({ fs: createGitFs(ctx, { gitdir: join(staging.path, '.git') }), http, dir: staging.path,
          url: url.href, ref, depth, singleBranch: singleBranch || depth !== undefined });
        abort(ctx);
        await owner.commitClone(staging.id);
      } catch (error) {
        // A terminated Worker cannot run this branch. The main job owner also
        // releases uncommitted clones, after joining Worker and pending writes.
        if (!ctx.signal?.aborted) await owner.releaseClone(staging.id);
        abort(ctx);
        throw Object.assign(new Error('Git clone transport or repository operation failed'), { code: error.code });
      }
      return output('Repository cloned.\n');
    }
    const options = gitStorage(ctx, await repository(ctx));
    if (command === 'rev-parse') {
      let text = '';
      for (let i = 0; i < args.length; ++i) {
        const arg = args[i];
        if (arg === '--show-toplevel') text += options.dir + '\n';
        else if (arg === '--absolute-git-dir') text += options.gitdir + '\n';
        else if (arg === '--git-dir') text += (relative(ctx.cwd, options.gitdir) || '.') + '\n';
        else if (arg === '--is-inside-work-tree') text += 'true\n';
        else if (arg === '--git-path' && args[++i] === 'objects') text += join(options.gitdir, 'objects') + '\n';
        else if (arg.startsWith('-')) unsupported(`git rev-parse 参数 ${arg} 未实现`);
        else text += await git.resolveRef({ ...options, ref: arg }) + '\n';
      }
      return output(text);
    }
    if (command === 'add') return await addFiles(args, ctx, options);
    if (command === 'write-tree') {
      if (args.length) unsupported('git write-tree 不接受额外参数');
      return output(await stageTree(git, options) + '\n');
    }
    if (command === 'diff' || command === 'diff-tree') return await gitDiff(args, ctx, options, command === 'diff-tree');
    if (command === 'ls-files') {
      if (args.some(arg => !['-z', '--stage', '-s'].includes(arg))) unsupported('git ls-files 仅支持 --stage/-z');
      const entries = await readIndex(options), staged = args.includes('--stage') || args.includes('-s');
      const rows = staged ? entries : [...new Map(entries.map(entry => [entry.path, entry])).values()];
      const highBytes = await quoteHighBytes(options);
      return output(rows.map(entry => `${staged ? `${entry.mode.toString(8).padStart(6, '0')} ${entry.oid} ${entry.stage}\t` : ''}${args.includes('-z') ? entry.path : quoteGitPath(entry.path, highBytes)}${args.includes('-z') ? '\0' : '\n'}`).join(''));
    }
    if (command === 'check-ignore') {
      if (args.some(arg => !['-z', '--stdin'].includes(arg)) || !args.includes('--stdin')) unsupported('git check-ignore 仅支持 --stdin 与 -z');
      const delimiter = args.includes('-z') ? '\0' : '\n';
      const input = String(ctx.stdin ?? '').split(delimiter).filter(Boolean), ignored = [];
      const tracked = new Set((await readIndex(options)).map(entry => entry.path));
      for (const path of input) {
        const rel = filePath(ctx, options, path);
        if (!tracked.has(rel) && await git.isIgnored({ ...options, filepath: rel })) ignored.push(path);
      }
      return output(ignored.length ? ignored.join(delimiter) + delimiter : '', '', ignored.length ? 0 : 1);
    }
    if (command === 'ls-tree') {
      const { flags, paths } = splitPaths(args); const refs = flags.filter(arg => !arg.startsWith('-'));
      if (refs.length !== 1 || flags.some(arg => arg.startsWith('-') && !['-z', '-l', '-r'].includes(arg))) unsupported('git ls-tree 参数未实现');
      const entries = await treeEntries(git, options, refs[0]); let text = '';
      for (const entry of entries.values()) {
        if (paths.length && !paths.includes(entry.path)) continue;
        const bytes = entry.type === 'blob' ? await objectBytes(git, options, entry) : undefined;
        text += `${entry.mode.toString(8).padStart(6, '0')} ${entry.type} ${entry.oid}${flags.includes('-l') ? ` ${String(bytes?.length ?? '-').padStart(7, ' ')}` : ''}\t${entry.path}${flags.includes('-z') ? '\0' : '\n'}`;
      }
      return output(text);
    }
    if (command === 'cat-file') {
      if (args.length !== 2 || args[0] !== 'blob') unsupported('git cat-file 仅支持 blob <oid>');
      const object = await git.readObject({ ...options, oid: args[1], format: 'content' });
      if (object.type !== 'blob') fault('Requested object is not a blob');
      return { ...output(Buffer.from(object.object).toString('latin1')), stdoutKind: 'bytes' };
    }
    if (command === 'status') {
      if (args.some(arg => !['--short', '-s', '--porcelain', '--porcelain=v1', '-z', '--untracked-files=all'].includes(arg))) unsupported('git status 参数未实现');
      const matrix = await git.statusMatrix({ ...options, refresh: false });
      const rawIndex = await readIndex(options), unmerged = new Map();
      for (const entry of rawIndex) if (entry.stage) unmerged.set(entry.path, (unmerged.get(entry.path) ?? 0) | (1 << (entry.stage - 1)));
      const indexed = new Map(rawIndex.filter(entry => !entry.stage).map(entry => [entry.path, entry]));
      const headFiles = await headEntries(options);
      const filemode = String(await git.getConfig({ ...options, path: 'core.filemode' })).toLowerCase() !== 'false';
      const symlinks = String(await git.getConfig({ ...options, path: 'core.symlinks' })).toLowerCase() !== 'false';
      let text = ''; const delimiter = args.includes('-z') ? '\0' : '\n';
      const highBytes = await quoteHighBytes(options);
      for (const [path, head, work, stage] of matrix) {
        const display = args.includes('-z') ? path : quoteGitPath(path, highBytes, true);
        if (unmerged.has(path)) {
          text += `${({ 1: 'DD', 2: 'AU', 3: 'UD', 4: 'UA', 5: 'DU', 6: 'AA', 7: 'UU' })[unmerged.get(path)]} ${display}${delimiter}`;
          continue;
        }
        if (!head && !stage) { text += `?? ${display}${delimiter}`; continue; }
        let x = head === stage ? ' ' : stage === 0 ? 'D' : head === 0 ? 'A' : 'M';
        let y = work === stage ? ' ' : work === 0 ? 'D' : 'M';
        const indexMode = indexed.get(path)?.mode, headMode = headFiles.get(path)?.mode;
        if (head && stage && indexMode !== headMode)
          x = (indexMode & 0o170000) === (headMode & 0o170000) ? 'M' : 'T';
        if (work && stage) {
          const info = await ctx.fs.lstat(join(options.dir, path));
          const workMode = info.isSymbolicLink || (!symlinks && indexMode === 0o120000) ? 0o120000
            : (filemode ? info.mode & 0o111 : indexMode === 0o100755) ? 0o100755 : 0o100644;
          if (workMode !== indexMode) y = (workMode & 0o170000) === (indexMode & 0o170000) ? 'M' : 'T';
        }
        if (stage === 0 && work !== 0) { text += `${x}  ${display}${delimiter}?? ${display}${delimiter}`; continue; }
        if (x !== ' ' || y !== ' ') text += `${x}${y} ${display}${delimiter}`;
      }
      return output(text);
    }
    if (command === 'config') {
      const values = args.filter(arg => arg !== '--local');
      if (values.some(arg => arg.startsWith('-')) || values.length < 1 || values.length > 2) unsupported('git config 只支持仓库内单个键的读取/设置');
      if (values.length === 1) { const value = await git.getConfig({ ...options, path: values[0] }); return output(value === undefined ? '' : `${value}\n`, '', value === undefined ? 1 : 0); }
      await git.setConfig({ ...options, path: values[0], value: values[1] }); return output();
    }
    if (command === 'commit') {
      const messages = []; let all = false, amend = false, allowEmpty = false;
      for (let i = 0; i < args.length; ++i) {
        if (args[i] === '-m' || args[i] === '--message') messages.push(args[++i] ?? fault('Missing commit message'));
        else if (args[i] === '-a' || args[i] === '--all') all = true;
        else if (args[i] === '--amend') amend = true;
        else if (args[i] === '--allow-empty') allowEmpty = true;
        else unsupported(`git commit 参数 ${args[i]} 未实现`);
      }
      if (!messages.length) unsupported('git commit 需要 -m，不启动外部编辑器');
      if (all) await addFiles(['--all'], ctx, options, { onlyTracked: true });
      const tree = await stageTree(git, options), head = await git.resolveRef({ ...options, ref: 'HEAD' }).catch(error => error.code === 'NotFoundError' ? undefined : Promise.reject(error));
      if (!allowEmpty && !amend && head && (await git.readCommit({ ...options, oid: head })).commit.tree === tree)
        return output('nothing to commit\n', '', 1);
      const oid = await git.commit({ ...options, message: messages.join('\n\n'), amend,
        author: authorFrom(ctx, 'AUTHOR'), committer: authorFrom(ctx, 'COMMITTER') });
      return output(`[${(await git.currentBranch(options)) ?? 'detached'} ${oid.slice(0, 7)}] ${messages[0]}\n`);
    }
    if (command === 'log') {
      let depth, ref = 'HEAD', oneline = false;
      for (let i = 0; i < args.length; ++i) {
        if (args[i] === '--oneline') oneline = true;
        else if (args[i] === '-n' || args[i] === '--max-count') depth = Number(args[++i]);
        else if (/^-\d+$/.test(args[i])) depth = Number(args[i].slice(1));
        else if (args[i].startsWith('-')) unsupported(`git log 参数 ${args[i]} 未实现`);
        else if (ref === 'HEAD') ref = args[i]; else unsupported('git log 只支持一个起始 ref');
      }
      if (depth !== undefined && (!Number.isSafeInteger(depth) || depth < 1)) fault('Invalid log count');
      const commits = await git.log({ ...options, ref, depth });
      return output(commits.map(({ oid, commit }) => oneline ? `${oid.slice(0, 7)} ${commit.message.split('\n')[0]}\n`
        : `commit ${oid}\nAuthor: ${commit.author.name} <${commit.author.email}>\nDate:   ${new Date(commit.author.timestamp * 1000).toISOString()}\n\n    ${commit.message.trimEnd().replaceAll('\n', '\n    ')}\n\n`).join(''));
    }
    if (command === 'branch') {
      if (!args.length || args[0] === '--list') {
        if (args.length > 1) unsupported('git branch --list 的 pattern 尚未实现');
        const current = await git.currentBranch(options);
        return output((await git.listBranches(options)).map(name => `${name === current ? '* ' : '  '}${name}\n`).join(''));
      }
      if (args[0] === '-d' || args[0] === '-D') {
        if (args.length !== 2) unsupported('git branch 删除需要一个分支');
        const ref = args[1]; if (await git.currentBranch(options) === ref) fault('Cannot delete the current branch');
        if (args[0] === '-d') {
          const oid = await git.resolveRef({ ...options, ref: 'HEAD' }), ancestor = await git.resolveRef({ ...options, ref });
          if (oid !== ancestor && !await git.isDescendent({ ...options, oid, ancestor })) fault('Branch is not fully merged');
        }
        await git.deleteBranch({ ...options, ref }); return output(`Deleted branch ${ref}.\n`);
      }
      if (args.some(arg => arg.startsWith('-')) || args.length > 2) unsupported('git branch 参数未实现');
      await git.branch({ ...options, ref: args[0], object: args[1] ?? 'HEAD' }); return output();
    }
    if (command === 'checkout') {
      const { flags, paths } = splitPaths(args);
      let create = false, force = false; const refs = [];
      for (const arg of flags) {
        if (arg === '-b') create = true;
        else if (arg === '-f' || arg === '--force') force = true;
        else if (arg.startsWith('-')) unsupported('git checkout 参数未实现');
        else refs.push(arg);
      }
      const [ref, start] = refs;
      if (paths.length) {
        if (create || refs.length > 1) unsupported('git checkout 文件模式不支持 -b 或多个 ref');
        // Explicit path checkout is a request to replace those working files.
        await git.checkout({ ...options, ref, filepaths: paths.map(path => filePath(ctx, options, path)), noUpdateHead: true, force: true });
        return output();
      }
      if (refs.length > (create ? 2 : 1)) unsupported('git checkout 分支参数过多');
      if (!ref) unsupported('git checkout 缺少 ref');
      if (create) await git.branch({ ...options, ref, object: start });
      await git.checkout({ ...options, ref, force }); return output(`Switched to ${ref}.\n`);
    }
    unsupported(`git 子命令 ${command ?? '(空)'} 未实现`);
  } catch (error) {
    if (ctx.signal?.aborted) throw error;
    const exitCode = error.exitCode ?? 128;
    return output('', `git: ${error.message}\n`, exitCode);
  }
}
