// OHOS build input only. Composes the unchanged, already accepted O7a body fix
// with O5 abort-reason preservation. Does not modify runtime/ohos/node/.
import { createHash } from 'node:crypto';
import { readFile, rename, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { transcode } from 'node:buffer';
import { parseArgs } from 'node:util';
import path from 'node:path';

const { values, positionals } = parseArgs({ options: {
  target: { type: 'string' }, 'build-tools': { type: 'string' },
}, allowPositionals: true });
if (values.target !== 'ohos' || !values['build-tools'] || positionals.length !== 1) {
  throw new Error('Usage: node prepare-node-fetch.mjs --target ohos --build-tools /locked/esbuild-prefix /node-v24.22.1-source');
}
const esbuild = createRequire(path.resolve(values['build-tools'], 'package.json'))('esbuild');
if (esbuild.version !== '0.27.3') throw new Error('Requires locked esbuild 0.27.3');
const root = path.resolve(positionals[0]);
const version = await readFile(path.join(root, 'src/node_version.h'), 'utf8');
for (const [key, value] of [['MAJOR', 24], ['MINOR', 22], ['PATCH', 1]]) {
  if (!version.includes(`#define NODE_${key}_VERSION ${value}\n`)) throw new Error('Requires Node 24.22.1 source');
}
const pins = {
  bodyBefore: 'fd7e1fe68e263f3296ecf0f4f799b3099717ecd8c9626db9bab73b7a4db7eb7d',
  bodyAfter: '3e57dbca4505d41f0eff63be2d7c631bb4bd0dce8562b4d098e38d1c10281eb7',
  indexBefore: '2cf8903bb2c17d83794edbd800adac4e8077cf9a21d315acf812d2f614e24bd6',
  indexAfter: '26701b1c1fd7a2b1240476165fde7661071da4d8ffba1e4624d7b9904cd14fd8',
  bundleOriginal: '50a6f643f00499ef75c5a36a0a610e7db4f5fbb0a2093ad4942b46fc797f7e26',
  bundleFormdata: '2c28f6f03b582ab4b4fb5db594386a50041c28f9050fe5c70b9a8e4422fe2b22',
  bundleAfter: 'db17946f41981758f1d4328836360fe3d62818b12b73eb12a7198b39e2e61630',
};
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const sourceRoot = path.join(root, 'deps/undici/src');
const bodyPath = path.join(sourceRoot, 'lib/web/fetch/body.js');
const indexPath = path.join(sourceRoot, 'lib/web/fetch/index.js');
const bundlePath = path.join(root, 'deps/undici/undici.js');
const [body, index, bundle] = await Promise.all([readFile(bodyPath, 'utf8'), readFile(indexPath, 'utf8'), readFile(bundlePath)]);
const before = { body: hash(body), index: hash(index), bundle: hash(bundle) };
if (![pins.bodyBefore, pins.bodyAfter].includes(before.body) ||
  ![pins.indexBefore, pins.indexAfter].includes(before.index) ||
  ![pins.bundleOriginal, pins.bundleFormdata, pins.bundleAfter].includes(before.bundle) ||
  (before.body === pins.bodyBefore && before.index === pins.indexAfter)) throw new Error('Unknown Undici input SHA256');

async function generate(expected) {
  const result = await esbuild.build({ absWorkingDir: sourceRoot, entryPoints: ['index-fetch.js'],
    bundle: true, platform: 'node', outfile: 'undici-fetch.js',
    define: { esbuildDetection: '1' }, keepNames: true, write: false });
  const output = Buffer.from(transcode(Buffer.from(result.outputFiles[0].contents), 'utf8', 'latin1').toString('latin1'));
  if (hash(output) !== expected) throw new Error('Regenerated Undici bundle SHA256 mismatch');
  return output;
}
async function replaceFile(filename, bytes) {
  const temporary = `${filename}.dsh-go-${process.pid}.tmp`;
  await writeFile(temporary, bytes, { flag: 'wx' });
  try { await rename(temporary, filename); }
  finally { await rm(temporary, { force: true }); }
}

// Verify every bundled transitive source before writing, not only the two leaves.
const currentExpected = before.body === pins.bodyBefore ? pins.bundleOriginal
  : before.index === pins.indexBefore ? pins.bundleFormdata : pins.bundleAfter;
await generate(currentExpected);
const bodyAfter = before.body === pins.bodyAfter ? body : body.replace(
  '    // Set source to object.\n    source = object\n\n    action = async function * () {',
  '    // Keep the boundary and entry snapshot when a redirect replays the body.\n    source = new Blob(blobParts)\n\n    action = async function * () {');
const indexAfter = before.index === pins.indexAfter ? index : index.replace('    if (!error) {', '    if (error === undefined) {');
if (hash(bodyAfter) !== pins.bodyAfter || hash(indexAfter) !== pins.indexAfter) throw new Error('Source transformation SHA256 mismatch');
try {
  if (before.body !== pins.bodyAfter) await replaceFile(bodyPath, bodyAfter);
  if (before.index !== pins.indexAfter) await replaceFile(indexPath, indexAfter);
  await replaceFile(bundlePath, await generate(pins.bundleAfter));
} catch (error) {
  await replaceFile(bodyPath, body);
  await replaceFile(indexPath, index);
  throw error;
}
console.log(JSON.stringify({ target: 'ohos', node: '24.22.1', undici: '7.30.1', esbuild: esbuild.version,
  before, after: { body: pins.bodyAfter, index: pins.indexAfter, bundle: pins.bundleAfter },
  recoveredKnownSourceBundleMismatch: before.bundle !== currentExpected,
  scope: 'Node build inputs; this command does not compile a native binary' }));
