// Build-time only. Parse every packaged JavaScript file without evaluating it.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { createRequire, isBuiltin } from 'node:module';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
function javascriptFiles(root) {
  const files = [];
  function walk(directory) {
    for (const item of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const file = join(directory, item.name);
      if (item.isDirectory()) walk(file);
      else if (item.isFile() && /\.(?:mjs|cjs|js)$/.test(item.name)) files.push(file);
    }
  }
  walk(root);
  return files;
}

export async function auditImports(payload, esbuildPrefix, exceptions = []) {
  const root = realpathSync(payload);
  const esbuild = createRequire(join(resolve(esbuildPrefix), 'package.json'))('esbuild');
  if (esbuild.version !== '0.27.3') throw new Error('The import parser requires fixed esbuild 0.27.3');
  const files = javascriptFiles(root), imports = [], errors = [], warnings = [];
  for (let offset = 0; offset < files.length; offset += 100) {
    const batch = files.slice(offset, offset + 100);
    let result;
    try {
      result = await esbuild.build({ absWorkingDir: root,
        entryPoints: batch.map((file, index) => ({ in: file, out: `module-${index}` })), outdir: '/unused-ohos-import-audit',
        bundle: false, write: false, metafile: true, platform: 'node', format: 'esm',
        treeShaking: false, logLevel: 'silent' });
    } catch (error) {
      for (const entry of error.errors ?? [{ text: error.message }]) {
        errors.push({ kind: 'parse', file: entry.location?.file, line: entry.location?.line, message: entry.text });
      }
      continue;
    }
    for (const warning of result.warnings) warnings.push({ file: warning.location?.file, message: warning.text });
    for (const output of Object.values(result.metafile.outputs)) {
      const importer = resolve(root, output.entryPoint);
      for (const entry of output.imports) {
        const row = { importer: relative(root, importer).split('\\').join('/'),
          kind: entry.kind, specifier: entry.path };
        if (isBuiltin(entry.path)) { imports.push({ ...row, resolved: entry.path }); continue; }
        try {
          const url = entry.kind.startsWith('require-') ? pathToFileURL(createRequire(importer).resolve(entry.path)).href :
            import.meta.resolve(entry.path, pathToFileURL(importer).href);
          if (!url.startsWith('file:')) throw new Error('Non-file module URL is outside the payload');
          const target = fileURLToPath(url);
          if (!existsSync(target) || !statSync(target).isFile()) throw new Error('Resolved target is not a regular file');
          const actual = realpathSync(target), local = relative(root, actual);
          if (local === '..' || local.startsWith('../') || isAbsolute(local)) throw new Error('Resolution escaped the payload');
          imports.push({ ...row, resolved: local.split('\\').join('/') });
        } catch (error) {
          imports.push({ ...row, missing: true, message: error.code ?? error.message });
        }
      }
    }
  }
  const used = new Set();
  for (const entry of imports.filter(row => row.missing && !row.kind.startsWith('require-'))) {
    const exception = exceptions.find(item => item.importer === entry.importer && item.specifier === entry.specifier);
    if (entry.kind !== 'dynamic-import' || !exception) {
      errors.push({ ...entry, message: 'Unresolved static import or unlisted dynamic import' });
      continue;
    }
    const matches = imports.filter(row => row.importer === entry.importer && row.kind === 'dynamic-import' &&
      row.specifier === entry.specifier);
    if (matches.length !== exception.occurrences || sha256(readFileSync(join(root, entry.importer))) !== exception.importerSha256 ||
        !exception.reason) {
      errors.push({ ...entry, message: 'Dynamic omission evidence differs from the exact allowlist' });
      continue;
    }
    used.add(exception);
  }
  for (const exception of exceptions) {
    if (!used.has(exception)) errors.push({ ...exception, message: 'Unused or stale dynamic omission exception' });
  }
  return { schema: 1, scope: 'Every .js/.mjs/.cjs static ESM import/export and literal dynamic import; parse only, no module execution. Literal require calls are recorded separately; nonliteral specifiers need execution coverage.',
    parser: { name: 'esbuild', version: esbuild.version }, files: files.map(file => ({ path: relative(root, file).split('\\').join('/'),
      sha256: sha256(readFileSync(file)) })), imports, dynamicOmissions: exceptions,
    unresolvedRequireCalls: imports.filter(row => row.missing && row.kind.startsWith('require-')), warnings, errors,
    passed: errors.length === 0 };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.execArgv.includes('--experimental-import-meta-resolve')) throw new Error('Run with --experimental-import-meta-resolve to resolve each importer independently');
  const [payload, esbuildPrefix, allowlist, reportPath] = process.argv.slice(2);
  const report = await auditImports(payload, esbuildPrefix, JSON.parse(readFileSync(allowlist, 'utf8')));
  writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
  console.log(JSON.stringify({ files: report.files.length, imports: report.imports.length,
    unresolvedRequireCalls: report.unresolvedRequireCalls.length, errors: report.errors.length, passed: report.passed }));
  if (!report.passed) process.exitCode = 1;
}
