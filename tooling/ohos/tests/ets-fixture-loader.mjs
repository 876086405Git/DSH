// Test-only loader: Node's built-in .mts stripping needs WebAssembly, which is
// disabled by --jitless. Compile the same ETS boundary fixture bodies with the
// supplied pinned TypeScript compiler; do not install this in a product runtime.
import { registerHooks, createRequire } from 'node:module';
import { readFileSync, mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
if (!prefix) throw new Error('OHOS_TYPESCRIPT_PREFIX is required for jitless ETS fixtures');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
registerHooks({ load(url, context, nextLoad) {
  if (!url.startsWith('file:') || !url.endsWith('.mts')) return nextLoad(url, context);
  const source = readFileSync(fileURLToPath(url), 'utf8');
  const output = ts.transpileModule(source, { fileName: fileURLToPath(url), compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022, useDefineForClassFields: true,
  } }).outputText;
  const artifacts = process.env.OHOS_ETS_FIXTURE_ARTIFACTS;
  if (artifacts) {
    mkdirSync(artifacts, {recursive:true});
    const digest = value => createHash('sha256').update(value).digest('hex');
    const outputSHA256 = digest(output), sourceSHA256 = digest(source);
    writeFileSync(join(artifacts, outputSHA256 + '.mjs'), output);
    writeFileSync(join(artifacts, sourceSHA256 + '.mts'), source);
    appendFileSync(join(artifacts, 'transforms.jsonl'), JSON.stringify({pid:process.pid,url,sourceSHA256,outputSHA256,
      typescriptVersion:ts.version,compilerSHA256:digest(readFileSync(createRequire(resolve(prefix,'package.json')).resolve('typescript')))}) + '\n');
  }
  return { format: 'module', shortCircuit: true, source: output };
} });
