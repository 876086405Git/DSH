import { isUtf8 } from 'node:buffer';
import { isRgFilesystemError, rgDiagnostic, selectRgFiles, validateRgGlobs } from './rg-select.mjs';
const unsupported = detail => ({ stdout: '', stderr: `rg: 鸿蒙本机尚不支持${detail}，可以连接电脑执行\n`, exitCode: 2 });
const flags = new Set(['--files', '--json', '--no-ignore', '--hidden', '--case-sensitive', '--ignore-case', '-i', '-s', '-n', '--line-number', '-F', '--fixed-strings', '--text', '-a']);
// UTF-8 字节预算：先检查，再展开为 RE2JS 的 number[]；不降低原 JSON 输出预算。
const maxJsonLineBytes = 4 * 1024 * 1024;

// 先覆盖 DSH 的批量搜索模板；未等价实现的语义明确拒绝，不能悄悄给出漏项。
async function executeRgBody(args, ctx) {
  const normalized = ['--case-sensitive'];
  const globs = [], paths = [], rawPatterns = [];
  let modified = false, literal = false, patternSeen = false;
  const options = [];
  for (let index = 0; index < args.length && args[index] !== '--'; index++) {
    if (['--regexp', '-e', '--glob', '-g'].includes(args[index])) index++;
    else options.push(args[index]);
  }
  const files = options.includes('--files'), json = options.includes('--json');
  const fixed = options.includes('-F') || options.includes('--fixed-strings');
  const pattern = value => {
    rawPatterns.push(value);
    if (fixed) return value;
    if (!json && /(^|[^\\])(?:\\\\)*\\[wWdDsSbB]/.test(value)) throw new Error('非 JSON 输出的 Unicode 正则字符类或词边界');
    const mode = value.match(/^\(\?(-?i)\)/);
    if (mode) {
      normalized.push(mode[1] === 'i' ? '--ignore-case' : '--case-sensitive');
      value = value.slice(mode[0].length);
    }
    if (/\(\?[imsRUux-]/.test(value)) throw new Error('局部或组合正则标志');
    return value;
  };
  try {
    for (let index = 0; index < args.length; index++) {
      const arg = args[index];
      if (literal) { paths.push(arg); continue; }
      if (arg === '--') { literal = true; continue; }
      if (arg === '--no-config') continue;
      if (arg === '--sort=modified') { modified = true; continue; }
      if (flags.has(arg)) { normalized.push(arg); continue; }
      if (arg.startsWith('--regexp=') || arg === '--regexp' || arg === '-e') {
        const value = arg.startsWith('--regexp=') ? arg.slice(9) : args[++index];
        if (value === undefined) return unsupported('缺少值的 regexp 参数');
        normalized.push(`--regexp=${pattern(value)}`); patternSeen = true; continue;
      }
      if (arg.startsWith('--glob=') || arg === '--glob' || arg === '-g') {
        const value = arg.startsWith('--glob=') ? arg.slice(7) : args[++index];
        if (value === undefined) return unsupported('缺少值的 glob 参数');
        globs.push(value); continue;
      }
      if (arg.startsWith('-')) return unsupported(`参数 ${arg}`);
      if (!files && !patternSeen) { normalized.push(`--regexp=${pattern(arg)}`); patternSeen = true; }
      else paths.push(arg);
    }
  } catch (error) { return unsupported(error.message); }
  if (modified && !files) return unsupported('在 --files 以外按修改时间排序');
  if (!files && !json && globs.some(value => !value.startsWith('!'))) return unsupported('非 JSON 输出的正向 include glob');
  if (files && globs.some(value => !value.startsWith('!') && (value.includes('**') || /[{}]/.test(value)))) return unsupported('包含 ** 或花括号的正向 glob');
  normalized.push(...globs.map(value => `--glob=${value}`));
  for (const path of paths) {
    if (path.includes('\n')) return unsupported('含换行符的搜索路径');
    // just-bash 3.6.0 不接受 --；绝对化以短横开头的字面路径，防止再解析成选项。
    normalized.push(path.startsWith('-') ? ctx.fs.resolvePath(ctx.cwd, path) : path);
  }
  if (!files && !json && !options.includes('--text') && !options.includes('-a')) {
    for (const path of paths) {
      const absolute = ctx.fs.resolvePath(ctx.cwd, path);
      if ((await ctx.fs.stat(absolute)).isFile && (await ctx.fs.readFileBuffer(absolute)).includes(0)) return unsupported('默认二进制文件搜索；可明确使用 --text');
    }
  }
  const result = json
    ? await searchJson({ ctx, normalized, options, rawPatterns, fixed, globs, paths })
    : await ctx.origCommand(normalized);
  if (result.stderr.includes('invalid regex:')) result.stderr = result.stderr.replace('invalid regex:', 'regex parse error:');
  if (result.exitCode !== 0 && result.stderr) result.exitCode = 2;
  if (modified && result.exitCode === 0) {
    const facts = await Promise.all(result.stdout.split('\n').filter(Boolean).map(async path => ({ path, mtime: +(await ctx.fs.stat(ctx.fs.resolvePath(ctx.cwd, path))).mtime })));
    facts.sort((a, b) => a.mtime - b.mtime || a.path.localeCompare(b.path, 'en'));
    result.stdout = facts.map(item => item.path).join('\n') + (facts.length ? '\n' : '');
  }
  return result;
}
// 仅本 OHOS rg 使用的私有源码构建；不改原 npm 包或其他使用者，见 M4-1.md。
import { RE2JS } from './build/re2js-unicode.mjs';


async function searchJson({ ctx, options, rawPatterns, fixed, globs, paths }) {
  let ignoreCase = false;
  for (const option of options) {
    if (option === '-i' || option === '--ignore-case') ignoreCase = true;
    else if (option === '-s' || option === '--case-sensitive') ignoreCase = false;
  }
  if (!rawPatterns.length) return { stdout: '', stderr: 'rg: no pattern given\n', exitCode: 2 };
  let regex;
  try {
    const patterns = rawPatterns.map(value => fixed ? value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') : value);
    regex = RE2JS.compile(patterns.length === 1 ? patterns[0] : patterns.map(value => `(?:${value})`).join('|'), ignoreCase ? RE2JS.CASE_INSENSITIVE : 0);
  } catch (error) { return { stdout: '', stderr: `rg: regex parse error: ${error.message}\n`, exitCode: 2 }; }
  validateRgGlobs(globs);
  // 显式文件不受 glob / 隐藏 / ignore 过滤；目录采用有序 override 与 ignore 优先级。
  const explicit = [], directories = [];
  for (const path of paths) {
    if ((await ctx.fs.stat(ctx.fs.resolvePath(ctx.cwd, path))).isFile) explicit.push(path);
    else directories.push(path);
  }
  const selected = paths.length && !directories.length ? { stdout: '', stderr: '', exitCode: 0 }
    : await selectRgFiles(ctx, options, globs, directories.map(path => path.startsWith('-') ? ctx.fs.resolvePath(ctx.cwd, path) : path));
  if (selected.exitCode === 1 && !paths.length) return { stdout: '', stderr: "rg: No files were searched, which means ripgrep probably applied a filter you didn't expect.\nRunning with --debug will show why files are being skipped.\n", exitCode: 2 };
  if (selected.exitCode === 1 && !explicit.length) return selected;
  // Selection errors retain already-selected files. A nonempty result with
  // an error remains exit 2; it must not look like a complete successful search.
  const records = [], diagnostics = selected.stderr ? [selected.stderr] : [];
  let outputBytes = 0, failed = selected.exitCode > 1;
  const filePaths = [...explicit, ...selected.stdout.split('\0').filter(Boolean)];
  for (let fileIndex = 0; fileIndex < filePaths.length; fileIndex++) {
    const path = filePaths[fileIndex];
    let content;
    try {
      content = await ctx.fs.readFileBuffer(ctx.fs.resolvePath(ctx.cwd, path));
    } catch (error) {
      if (!isRgFilesystemError(error)) throw error;
      failed = true;
      diagnostics.push(rgDiagnostic(error));
      continue;
    }
    // IFileSystem 的公开返回类型为 Uint8Array；使用同一 backing store，不再复制整文件。
    let bytes = Buffer.from(content.buffer, content.byteOffset, content.byteLength);
    // rg 的 UTF-8 BOM 探测仅移除文件最前的一枚 BOM；JSON 坐标以解码后字节计。
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) bytes = bytes.subarray(3);
    if (!options.includes('--text') && !options.includes('-a') && bytes.includes(0)) {
      if (fileIndex < explicit.length) return unsupported('默认二进制文件搜索；可明确使用 --text');
      continue;
    }
    // 公开 API 只验证编码，不为验证分配整文件的临时 UTF-16 字符串。
    if (!isUtf8(bytes)) return unsupported('非 UTF-8 文件的 JSON 文本搜索');
    let displayPath = path;
    for (const literal of paths.filter(value => value.startsWith('-'))) {
      const absolute = ctx.fs.resolvePath(ctx.cwd, literal);
      if (path === absolute || path.startsWith(absolute + '/')) { displayPath = literal + path.slice(absolute.length); break; }
    }
    for (let start = 0, number = 1; start < bytes.length; number++) {
      const newline = bytes.indexOf(10, start), end = newline < 0 ? bytes.length : newline;
      if (end - start > maxJsonLineBytes) return unsupported(`超过 ${maxJsonLineBytes} 字节的 JSON 搜索单行（第 ${number} 行为 ${end - start} 字节；不含 LF，含 CR，文件首 UTF-8 BOM 不计入）`);
      const line = bytes.subarray(start, end), matcher = regex.matcher(Array.from(line)), submatches = [];
      let matched = false, nonemptyEnd = -1;
      while (matcher.find()) {
        matched = true;
        const from = matcher.start(), to = matcher.end();
        // Rust regex 不报告紧邻非空匹配后的空匹配；rg JSON 也不列出 EOF 空子匹配。
        if (from === to && (from === nonemptyEnd || (newline < 0 && from === line.length))) continue;
        if (submatches.length >= ctx.limits.maxArrayElements) throw new Error('rg: 单行匹配数超过解释器上限');
        submatches.push({ match: { text: line.subarray(from, to).toString('utf8') }, start: from, end: to });
        if (from !== to) nonemptyEnd = to;
      }
      if (matched) {
        const record = JSON.stringify({ type: 'match', data: { path: { text: displayPath }, lines: { text: bytes.subarray(start, newline < 0 ? end : end + 1).toString('utf8') }, line_number: number, absolute_offset: start, submatches } });
        outputBytes += Buffer.byteLength(record) + 1;
        if (outputBytes > ctx.limits.maxOutputSize) throw new Error('rg: JSON 输出超过解释器上限');
        records.push(record);
      }
      start = end + 1;
    }
  }
  return { stdout: records.join('\n') + (records.length ? '\n' : ''), stderr: diagnostics.join(''), exitCode: failed ? 2 : records.length ? 0 : 1 };
}

export async function executeRg(args, ctx) {
  try { return await executeRgBody(args, ctx); }
  catch (error) { return { stdout: '', stderr: `rg: ${error.message}\n`, exitCode: 2 }; }
}
