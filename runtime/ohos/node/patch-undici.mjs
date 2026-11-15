import { createHash } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { transcode } from 'node:buffer';

const require = createRequire(new URL('./build-tools/package.json', import.meta.url));
const esbuild = require('esbuild');
const pins = {
  sourceBefore: 'fd7e1fe68e263f3296ecf0f4f799b3099717ecd8c9626db9bab73b7a4db7eb7d',
  sourceAfter: '3e57dbca4505d41f0eff63be2d7c631bb4bd0dce8562b4d098e38d1c10281eb7',
  bundleBefore: '50a6f643f00499ef75c5a36a0a610e7db4f5fbb0a2093ad4942b46fc797f7e26',
  bundleAfter: '2c28f6f03b582ab4b4fb5db594386a50041c28f9050fe5c70b9a8e4422fe2b22',
};
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
async function replaceFile(filename, bytes) {
  const temporary = `${filename}.dsh-go-${process.pid}.tmp`;
  await writeFile(temporary, bytes, { flag: 'wx' });
  await rename(temporary, filename);
}

if (process.argv.length !== 3) throw new Error('Usage: node patch-undici.mjs /absolute/node-v24.22.1-source');
if (esbuild.version !== '0.27.3') throw new Error('Requires the locked esbuild 0.27.3');
const root = path.resolve(process.argv[2]);
const version = await readFile(path.join(root, 'src/node_version.h'), 'utf8');
for (const [key, value] of [['MAJOR', 24], ['MINOR', 22], ['PATCH', 1]]) {
  if (!version.includes(`#define NODE_${key}_VERSION ${value}\n`)) throw new Error('Requires Node 24.22.1 source');
}
const sourceRoot = path.join(root, 'deps/undici/src');
const source = path.join(sourceRoot, 'lib/web/fetch/body.js');
const bundle = path.join(root, 'deps/undici/undici.js');
const original = await readFile(source, 'utf8');
const sourceHash = hash(original);
if (![pins.sourceBefore, pins.sourceAfter].includes(sourceHash)) throw new Error('Undici body.js SHA256 mismatch');
if (![pins.bundleBefore, pins.bundleAfter].includes(hash(await readFile(bundle)))) throw new Error('Undici bundle SHA256 mismatch');

async function generate(expected) {
  // Node 24.22.1 deps/undici/src/package.json build:node and scripts/strip-comments.js.
  const result = await esbuild.build({ absWorkingDir: sourceRoot, entryPoints: ['index-fetch.js'],
    bundle: true, platform: 'node', outfile: 'undici-fetch.js',
    define: { esbuildDetection: '1' }, keepNames: true, write: false });
  const output = Buffer.from(transcode(Buffer.from(result.outputFiles[0].contents), 'utf8', 'latin1').toString('latin1'));
  if (hash(output) !== expected) throw new Error('Regenerated Undici bundle SHA256 mismatch');
  return output;
}

if (sourceHash === pins.sourceBefore) {
  await generate(pins.bundleBefore);
  const before = '    // Set source to object.\n    source = object\n\n    action = async function * () {';
  const after = '    // Keep the boundary and entry snapshot when a redirect replays the body.\n    source = new Blob(blobParts)\n\n    action = async function * () {';
  const modified = original.replace(before, after);
  if (hash(modified) !== pins.sourceAfter) throw new Error('Undici source transformation SHA256 mismatch');
  await replaceFile(source, modified);
}
try {
  await replaceFile(bundle, await generate(pins.bundleAfter));
} catch (error) {
  if (sourceHash === pins.sourceBefore) await replaceFile(source, original);
  throw error;
}
console.log(JSON.stringify({ node: '24.22.1', undici: '7.30.1', esbuild: esbuild.version, ...pins,
  scope: 'OHOS build input only; no target binary built by this command' }));
