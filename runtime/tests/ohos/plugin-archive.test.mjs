import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm, truncate, symlink } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { gzipSync, gunzipSync } from 'node:zlib';
import { setImmediate as immediate } from 'node:timers/promises';
import { npmArchive, npmBomArchive } from './plugin-archive-fixture.mjs';
import { extractPackage, ARCHIVE_LIMITS } from '../../ohos/plugins/archive.mjs';

const manifest = { name: '@ohos-test/pure-js', version: '1.0.0' };
const sri = (bytes, algorithm = 'sha512') => `${algorithm}-${createHash(algorithm).update(bytes).digest('base64')}`;
// Independent USTAR encoder, including raw PAX/GNU extension records for adversarial fixtures.
function entry(name, body = '', type = '0', linkname = '', declaredSize) {
  body = Buffer.from(body);
  const header = Buffer.alloc(512);
  header.write(name, 0, 100);
  for (const [offset, length, value] of [[100, 8, 0o644], [108, 8, 0], [116, 8, 0], [124, 12, declaredSize ?? body.length], [136, 12, 0]]) {
    header.write(value.toString(8).padStart(length - 1, '0') + '\0', offset, length);
  }
  header.fill(32, 148, 156); header.write(type, 156, 1); header.write(linkname, 157, 100);
  header.write('ustar\0', 257); header.write('00', 263);
  const sum = header.reduce((a, b) => a + b, 0);
  header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8);
  return Buffer.concat([header, body, Buffer.alloc((512 - body.length % 512) % 512)]);
}
function pax(key, value) {
  const text = `${key}=${value}\n`;
  let size = Buffer.byteLength(text) + 2;
  while (Buffer.byteLength(`${size} ${text}`) !== size) size = Buffer.byteLength(`${size} ${text}`);
  return `${size} ${text}`;
}
const archive = (entries, meta = manifest) => gzipSync(Buffer.concat([
  ...(meta === null ? [] : [entry('package/package.json', JSON.stringify(meta))]),
  ...entries, Buffer.alloc(1024),
]));
async function fixture(run) {
  const root = await mkdtemp(join(tmpdir(), 'ohos-plugin-archive-'));
  const stagingRoot = join(root, 'stage'), archivePath = join(root, 'package.tgz');
  await mkdir(stagingRoot); await writeFile(join(root, 'outside'), 'original');
  const extract = async (bytes, options = {}) => {
    await writeFile(archivePath, bytes);
    return extractPackage({ archivePath, stagingRoot, ...manifest, integrity: sri(bytes), ...options });
  };
  const clean = async () => {
    assert.deepEqual(await readdir(stagingRoot), []);
    assert.equal(await readFile(join(root, 'outside'), 'utf8'), 'original');
  };
  try { await run({ root, stagingRoot, archivePath, extract, clean }); }
  finally { await rm(root, { recursive: true, force: true }); }
}

test('real npm pack archive preserves JS, bin, prepare/build and long UTF-8 paths', async () => fixture(async f => {
  const result = await f.extract(npmArchive);
  assert.equal(result.manifest.name, manifest.name);
  assert.equal(result.directory.startsWith(f.stagingRoot + '/'), true);
  assert.equal(await readFile(join(result.directory, 'index.js'), 'utf8'), 'export const answer = 42;\n');
  assert.equal((await import(pathToFileURL(join(result.directory, 'index.js')))).answer, 42);
  assert.equal(await readFile(join(result.directory, 'cli.js'), 'utf8'), '#!/usr/bin/env node\nconsole.log(42);\n');
  assert.equal(await readFile(join(result.directory, 'long-segment-'.repeat(10), 'unicode-中文.txt'), 'utf8'), 'Long path preserved.\n');
}));

test('raw SRI is checked before gzip and strongest supported algorithm cannot downgrade', async () => fixture(async f => {
  const wrong = sri(Buffer.from('wrong'));
  for (const [bytes, integrity] of [[Buffer.from('not gzip'), wrong], [npmArchive, `${sri(npmArchive, 'sha256')} ${wrong}`], [npmArchive, 'sha512-not-base64!'], [npmArchive, 'md5-YQ==']]) {
    await assert.rejects(f.extract(bytes, { integrity }), { code: 'ERR_OHOS_PLUGIN_INTEGRITY' }); await f.clean();
  }
  const result = await f.extract(npmArchive, { integrity: `${wrong} ${sri(npmArchive)}` });
  assert.equal(result.manifest.version, '1.0.0');
}));

for (const [label, entries] of [
  ['parent path', [entry('package/../../outside', 'changed')]],
  ['absolute path', [entry('/tmp/ohos-extract-escape', 'changed')]],
  ['PAX path', [entry('PaxHeader', pax('path', 'package/../../outside'), 'x'), entry('package/innocent', 'changed')]],
  ['GNU long path', [entry('././@LongLink', 'package/../../outside\0', 'L'), entry('package/innocent', 'changed')]],
  ['symlink parent', [entry('package/out', '', '2', '../..'), entry('package/out/outside', 'changed')]],
  ['hardlink', [entry('package/out', '', '1', '../../outside')]],
  ['FIFO', [entry('package/pipe', '', '6')]],
  ['duplicate file', [entry('package/package.json', '{}')]],
  ['file parent', [entry('package/a', 'file'), entry('package/a/b', 'child')]],
  ['directory conflict', [entry('package/a/', '', '5'), entry('package/a', 'file')]],
  ['bundled node_modules', [entry('package/node_modules/hidden/index.js', 'code')]],
  ['sparse metadata', [entry('PaxHeader', pax('GNU.sparse.size', '1024'), 'x'), entry('package/sparse', 'x')]],
]) test(`reject ${label} and preserve outside files`, async () => fixture(async f => {
  await assert.rejects(f.extract(archive(entries))); await f.clean();
}));

test('PAX and GNU normal long paths are accepted', async () => fixture(async f => {
  const a = 'a'.repeat(180), b = 'b'.repeat(180);
  const result = await f.extract(archive([
    entry('PaxHeader', pax('path', `package/${a}`), 'x'), entry('package/a', 'pax'),
    entry('././@LongLink', `package/${b}\0`, 'L'), entry('package/b', 'gnu'),
  ]));
  assert.equal(await readFile(join(result.directory, a), 'utf8'), 'pax');
  assert.equal(await readFile(join(result.directory, b), 'utf8'), 'gnu');
}));

for (const [label, entries, meta] of [
  ['name mismatch', [], { ...manifest, name: 'other' }],
  ['version mismatch', [], { ...manifest, version: '2.0.0' }],
  ['missing manifest', [entry('package/index.js', 'code')], null],
  ['invalid manifest', [entry('package/package.json', '{')], null],
  ['native binary', [entry('package/native.node', 'binary')], manifest],
  ['binding.gyp', [entry('package/binding.gyp', '{}')], manifest],
  ['gypfile', [], { ...manifest, gypfile: true }],
  ['wasm', [entry('package/code.wasm', '\0asm')], manifest],
]) test(`reject ${label} and clean owned stage`, async () => fixture(async f => {
  await assert.rejects(f.extract(archive(entries, meta))); await f.clean();
}));
for (const script of ['preinstall', 'install', 'postinstall']) test(`never run ${script}`, async () => fixture(async f => {
  const scripts = { [script]: `node -e "require('node:fs').writeFileSync('${f.root}/outside','changed')"` };
  await assert.rejects(f.extract(archive([], { ...manifest, scripts })), { code: 'ERR_OHOS_PLUGIN_UNSUPPORTED' });
  await f.clean();
}));

test('reject malformed gzip and tar after valid raw SRI', async () => fixture(async f => {
  const tar = gunzipSync(npmArchive);
  const badChecksum = Buffer.from(tar); badChecksum[0] ^= 1;
  const badGzip = Buffer.from(npmArchive); badGzip[badGzip.length - 8] ^= 1;
  for (const bytes of [badGzip, npmArchive.subarray(0, -10), gzipSync(badChecksum), gzipSync(tar.subarray(0, 700)), gzipSync(Buffer.concat([tar, Buffer.from('nonzero')]))]) {
    await assert.rejects(f.extract(bytes)); await f.clean();
  }
}));

test('pre-cancel and mid-extraction cancellation clean only owned directories', { timeout: 15000 }, async () => fixture(async f => {
  const before = new AbortController(); before.abort();
  await assert.rejects(f.extract(npmArchive, { signal: before.signal }), { name: 'AbortError' }); await f.clean();
  await mkdir(join(f.stagingRoot, 'unrelated')); await writeFile(join(f.stagingRoot, 'unrelated', 'keep'), 'keep');
  const during = new AbortController();
  const bytes = archive(Array.from({ length: 2000 }, (_, i) => entry(`package/files/${i}`, 'x'.repeat(512))));
  const result = f.extract(bytes, { signal: during.signal });
  const observed = result.then(() => 'success', error => error);
  while ((await readdir(f.stagingRoot)).length === 1) await immediate();
  during.abort();
  assert.equal((await observed).name, 'AbortError');
  assert.deepEqual(await readdir(f.stagingRoot), ['unrelated']);
  assert.equal(await readFile(join(f.stagingRoot, 'unrelated', 'keep'), 'utf8'), 'keep');
}));

test('declared file and entry count limits reject before accepting unbounded work', async () => fixture(async f => {
  await assert.rejects(f.extract(archive([entry('package/large', Buffer.alloc(ARCHIVE_LIMITS.fileBytes + 1))])), { code: 'ERR_OHOS_PLUGIN_ARCHIVE_LIMIT' });
  await f.clean();
  const bytes = archive(Array.from({ length: ARCHIVE_LIMITS.entries }, (_, i) => entry(`package/${i}`)));
  await assert.rejects(f.extract(bytes), { code: 'ERR_OHOS_PLUGIN_ARCHIVE_LIMIT' }); await f.clean();
}));


test('compressed and full expanded stream limits include tar padding', async () => fixture(async f => {
  await writeFile(f.archivePath, '');
  await truncate(f.archivePath, ARCHIVE_LIMITS.compressedBytes + 1);
  await assert.rejects(extractPackage({ archivePath: f.archivePath, stagingRoot: f.stagingRoot,
    ...manifest, integrity: sri(npmArchive) }), { code: 'ERR_OHOS_PLUGIN_ARCHIVE_LIMIT' });
  await f.clean();
  const tar = gunzipSync(npmArchive);
  const bytes = gzipSync(Buffer.concat([tar, Buffer.alloc(ARCHIVE_LIMITS.expandedBytes)]));
  await assert.rejects(f.extract(bytes), { code: 'ERR_OHOS_PLUGIN_ARCHIVE_LIMIT' });
  await f.clean();
}));

function peImage() {
  const bytes = Buffer.alloc(512);
  bytes.write('MZ'); bytes.writeUInt32LE(64, 0x3c);
  bytes.write('PE\0\0', 64); bytes.writeUInt16LE(0x8664, 68); bytes.writeUInt16LE(1, 70);
  bytes.writeUInt16LE(240, 84); bytes.writeUInt16LE(0x2022, 86); bytes.writeUInt16LE(0x20b, 88);
  bytes.write('.text', 328); bytes.writeUInt32LE(512, 344); bytes.writeUInt32LE(0, 348);
  return bytes;
}
for (const [format, bytes] of [
  ['ELF', Buffer.from('7f454c46020101000000000000000000' + '00'.repeat(48), 'hex')],
  ['WebAssembly', Buffer.from('0061736d01000000', 'hex')],
  ...['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']
    .map(magic => ['Mach-O ' + magic, Buffer.from(magic + '00'.repeat(60), 'hex')]),
  ['PE', peImage()],
]) test(`reject extensionless ${format} payload`, async () => fixture(async f => {
  await assert.rejects(f.extract(archive([entry('package/payload', bytes)])), { code: 'ERR_OHOS_PLUGIN_UNSUPPORTED' });
  await f.clean();
}));
test('ordinary MZ text and invalid PE offsets are retained as data', async () => fixture(async f => {
  const text = 'MZ is ordinary text, not a native image.\n';
  const badOffset = Buffer.alloc(128); badOffset.write('MZ'); badOffset.writeUInt32LE(0xfffffff0, 0x3c);
  const result = await f.extract(archive([entry('package/text.txt', text), entry('package/offset.dat', badOffset)]));
  assert.equal(await readFile(join(result.directory, 'text.txt'), 'utf8'), text);
  assert.deepEqual(await readFile(join(result.directory, 'offset.dat')), badOffset);
}));


test('real npm pack BOM manifest loads without rewriting archive or extracted bytes', async () => fixture(async f => {
  const digest = sri(npmBomArchive);
  const result = await f.extract(npmBomArchive, { name: 'ohos-owned-js-bundle' });
  const bytes = await readFile(join(result.directory, 'package.json'));
  assert.equal(bytes.subarray(0, 3).toString('hex'), 'efbbbf');
  assert.equal(result.manifest.name, 'ohos-owned-js-bundle');
  assert.equal(sri(await readFile(f.archivePath)), digest);
  let tool;
  const modules = join(f.root, 'node_modules');
  await mkdir(modules);
  await symlink(result.directory, join(modules, 'ohos-owned-js-bundle'), 'dir');
  assert.equal(createRequire(join(f.root, 'control.cjs')).resolve('ohos-owned-js-bundle'), join(result.directory, 'index.mjs'));
  await writeFile(join(f.root, 'control.mjs'), "export * from 'ohos-owned-js-bundle';");
  const module = await import(pathToFileURL(join(f.root, 'control.mjs')));
  module.apply({ tools: { register(value) { tool = value; } } });
  assert.deepEqual(await tool.execute({ text: 'BOM' }), { text: 'BOM', version: '1.0.0' });
}));

for (const [label, prefix, suffix, accepted] of [
  ['plain', '', '', true],
  ['single BOM', '\uFEFF', '', true],
  ['double BOM', '\uFEFF\uFEFF', '', false],
  ['space before BOM', ' \uFEFF', '', false],
  ['malformed JSON', '', '!', false],
]) test(`manifest decoding agrees with Node package loader: ${label}`, async () => fixture(async f => {
  const text = prefix + JSON.stringify({ ...manifest, type: 'module', main: './index.js' }) + suffix;
  const control = join(f.root, 'node_modules', '@ohos-test', 'pure-js');
  await mkdir(control, { recursive: true });
  await writeFile(join(control, 'package.json'), text);
  await writeFile(join(control, 'index.js'), 'export const answer = 42;');
  await writeFile(join(f.root, 'control.mjs'), "export * from '@ohos-test/pure-js';");
  const resolve = () => createRequire(join(f.root, 'control.cjs')).resolve(manifest.name);
  const load = () => import(pathToFileURL(join(f.root, 'control.mjs')));
  const bytes = archive([entry('package/package.json', text), entry('package/index.js', 'export const answer = 42;')], null);
  if (accepted) {
    assert.equal(resolve(), join(control, 'index.js'));
    assert.equal((await load()).answer, 42);
    const result = await f.extract(bytes);
    assert.equal(await readFile(join(result.directory, 'package.json'), 'utf8'), text);
    assert.equal((await import(pathToFileURL(join(result.directory, 'index.js')))).answer, 42);
  } else {
    assert.throws(resolve, { code: 'ERR_INVALID_PACKAGE_CONFIG' });
    await assert.rejects(load(), { code: 'ERR_INVALID_PACKAGE_CONFIG' });
    await assert.rejects(f.extract(bytes), SyntaxError);
    await f.clean();
  }
}));
