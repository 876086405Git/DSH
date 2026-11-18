// Build-time only. The original npm package and its other consumers stay unchanged.
import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const re2Root = resolve(dirname(require.resolve('re2js')), '..');
const esbuildPrefix = process.argv[2] || join(here, '../node/build-tools');
const buildRequire = createRequire(join(resolve(esbuildPrefix), 'package.json'));
const esbuild = buildRequire('esbuild');
if (esbuild.version !== '0.27.3') throw new Error('require esbuild 0.27.3');
const manifest = JSON.parse(await readFile(join(re2Root, 'package.json'), 'utf8'));
if (manifest.name !== 're2js' || manifest.version !== '1.3.3') throw new Error('require re2js 1.3.3');
const bytes = await readFile(join(re2Root, 'build/index.esm.js.map'));
const hash = value => createHash('sha256').update(value).digest('hex');
if (hash(bytes) !== 'a138e051f8d439b750f1af5f039c23ab67daac86361356e514280560057f28b6') throw new Error('unexpected re2js source map');
const sourceMap = JSON.parse(bytes), originals = new Map(), sources = new Map();
for (let i = 0; i < sourceMap.sources.length; i++) {
  const name = sourceMap.sources[i];
  if (!/^\.\.\/src\/[A-Za-z0-9]+\.js$/.test(name)) throw new Error('unexpected source path');
  originals.set(name.slice(3), sourceMap.sourcesContent[i]); sources.set(name.slice(3), sourceMap.sourcesContent[i]);
}
const patch = await readFile(join(here, 'regex-src/re2js-unicode.diff'), 'utf8');
// A strict, zero-fuzz applicator for this pinned non-generated-source patch.
for (const section of patch.split(/(?=^--- a\/)/m).filter(Boolean)) {
  const lines = section.trimEnd().split('\n');
  const name = lines.shift().slice(6);
  if (lines.shift() !== '+++ b/' + name || !sources.has(name)) throw new Error('unexpected source patch target');
  const old = sources.get(name).split('\n');
  if (old.pop() !== '') throw new Error('source must end in LF');
  const output = []; let cursor = 0, index = 0;
  while (index < lines.length) {
    const match = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(lines[index++]);
    if (!match) throw new Error('invalid source patch hunk');
    const start = Number(match[1]) - 1;
    if (start < cursor) throw new Error('overlapping source patch');
    output.push(...old.slice(cursor, start)); cursor = start;
    let consumed = 0, produced = 0;
    while (index < lines.length && !lines[index].startsWith('@@ ')) {
      const line = lines[index++], sign = line[0], value = line.slice(1);
      if (sign === ' ' || sign === '-') {
        if (old[cursor++] !== value) throw new Error('source patch context mismatch'); consumed++;
      } else if (sign !== '+') throw new Error('invalid source patch line');
      if (sign === ' ' || sign === '+') { output.push(value); produced++; }
    }
    if (consumed !== Number(match[2] ?? 1) || produced !== Number(match[4] ?? 1)) throw new Error('source patch count mismatch');
  }
  output.push(...old.slice(cursor)); sources.set(name, output.join('\n') + '\n');
}
const staging = await mkdtemp(join(tmpdir(), 'ohos-rg-build-'));
try {
  for (const [name, text] of sources) await writeFile(join(staging, name.slice(4)), text);
  const modification = await readFile(join(here, 'regex-src/UnicodeGroups.js'));
  await writeFile(join(staging, 'UnicodeGroups.js'), modification);
  const license = await readFile(join(re2Root, 'LICENSE'), 'utf8');
  const result = await esbuild.build({ absWorkingDir: staging, entryPoints: ['index.js'], bundle: true, format: 'esm', platform: 'node', target: 'es2022', minify: true, write: false,
    banner: { js: '/* OHOS rg private build of re2js 1.3.3; Unicode 16 shorthand/boundary changes.\n' + license.replace(/\*\//g, '* /') + '\n*/' } });
  const target = join(here, 'build/re2js-unicode.mjs');
  await mkdir(dirname(target), { recursive: true }); await writeFile(target, result.outputFiles[0].contents);
  const proof = { re2js: manifest.version, esbuild: esbuild.version, sourceMapSHA256: hash(bytes),
    sourceFiles: Object.fromEntries([...originals].map(([name, text]) => [name, hash(text)])),
    sourcePatchSHA256: hash(patch), modificationSourceSHA256: hash(modification),
    outputSHA256: hash(result.outputFiles[0].contents), outputBytes: result.outputFiles[0].contents.length };
  await writeFile(join(here, 'build/re2js-unicode-build.json'), JSON.stringify(proof, null, 2) + '\n');
  console.log(JSON.stringify(proof));
} finally { await rm(staging, { recursive: true, force: true }); }
