#!/usr/bin/env node
// Builds the companion asset pack (docs/design/companion.md): the Live2D runtime
// plus one character, as one zip. None of it lives in this repository: Cubism
// Core is Live2D's proprietary code and the framework and the model have their
// own terms, so the pack is built from local copies and hosted apart.
//
//   node tooling/companion/build-pack.mjs \
//     --core <live2dcubismcore.min.js> --framework <CubismWebFramework checkout> \
//     --character <dir with *.model3.json> --config <character.json> --out <pack.zip>
//
// Prints the runtime digest for `companionRuntimeDigest` in
// app/lib/companion/companion_pack.dart, and the zip's size and SHA-256.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32, deflateRawSync } from 'node:zlib';

const args = Object.fromEntries(
  process.argv.slice(2).flatMap((arg, i, all) => (arg.startsWith('--') ? [[arg.slice(2), all[i + 1]]] : [])),
);
for (const key of ['core', 'framework', 'character', 'config', 'out']) {
  if (!args[key]) throw new Error(`missing --${key}`);
}

const here = dirname(fileURLToPath(import.meta.url));
const framework = resolve(args.framework);
const work = mkdtempSync(join(tmpdir(), 'companion-pack-'));

try {
  // Runtime: Core, the bundled framework, its shaders and licences.
  const runtime = join(work, 'runtime');
  mkdirSync(join(runtime, 'shaders'), { recursive: true });
  cpSync(args.core, join(runtime, 'live2dcubismcore.min.js'));
  cpSync(join(framework, 'Shaders', 'WebGL'), join(runtime, 'shaders'), { recursive: true });
  cpSync(join(framework, 'LICENSE.md'), join(runtime, 'LICENSE-framework.md'));
  execFileSync(
    process.platform === 'win32' ? 'npx.cmd' : 'npx',
    [
      '--yes',
      'esbuild@0.28.2',
      join(here, 'framework-entry.ts'),
      '--bundle',
      '--format=iife',
      '--global-name=CubismFw',
      '--target=es2020',
      '--minify',
      '--legal-comments=inline',
      `--alias:@framework=${join(framework, 'src')}`,
      `--outfile=${join(runtime, 'cubism-framework.js')}`,
    ].map((arg) => process.platform === 'win32' ? `"${arg}"` : arg),
    { stdio: 'inherit', shell: process.platform === 'win32' },
  );

  // Character: model data only. The app refuses scripts in this folder.
  const character = join(work, 'character');
  const output = resolve(args.out);
  cpSync(args.character, character, { recursive: true, filter: (source) => resolve(source) !== output });
  cpSync(args.config, join(character, 'character.json'));

  const files = walk(work).sort();
  const zip = makeZip(files);
  mkdirSync(dirname(resolve(args.out)), { recursive: true });
  writeFileSync(args.out, zip);

  // Same recipe as runtimeDigest() in companion_pack.dart.
  const digest = createHash('sha256');
  for (const file of files.filter((f) => relative(work, f).startsWith(`runtime${sep}`))) {
    const name = relative(work, file).split(sep).join('/');
    digest.update(`${name}\0${createHash('sha256').update(readFileSync(file)).digest('hex')}\n`);
  }
  console.log(`runtime digest  ${digest.digest('hex')}`);
  console.log(`pack            ${args.out}`);
  console.log(`bytes           ${zip.length}`);
  console.log(`sha256          ${createHash('sha256').update(zip).digest('hex')}`);
} finally {
  rmSync(work, { recursive: true, force: true });
}

function makeZip(files) {
  const parts = [];
  const central = [];
  let offset = 0;
  for (const file of files) {
    const name = Buffer.from(relative(work, file).split(sep).join('/'), 'utf8');
    const data = readFileSync(file);
    const deflated = deflateRawSync(data, { level: 9 });
    const stored = deflated.length >= data.length;
    const body = stored ? data : deflated;
    const head = Buffer.alloc(26);
    head.writeUInt16LE(20, 0); // version needed
    head.writeUInt16LE(0x0800, 2); // UTF-8 names
    head.writeUInt16LE(stored ? 0 : 8, 4);
    head.writeUInt32LE(0x00210000, 6); // fixed time: same input, same zip
    head.writeUInt32LE(crc32(data), 10);
    head.writeUInt32LE(body.length, 14);
    head.writeUInt32LE(data.length, 18);
    head.writeUInt16LE(name.length, 22);
    const local = Buffer.concat([u32(0x04034b50), head, name, body]);
    const tail = Buffer.alloc(14);
    tail.writeUInt32LE(offset, 10);
    central.push(Buffer.concat([u32(0x02014b50), u16(20), head, tail, name]));
    parts.push(local);
    offset += local.length;
  }
  const directory = Buffer.concat(central);
  const end = Buffer.alloc(18);
  end.writeUInt16LE(files.length, 4);
  end.writeUInt16LE(files.length, 6);
  end.writeUInt32LE(directory.length, 8);
  end.writeUInt32LE(offset, 12);
  return Buffer.concat([...parts, directory, u32(0x06054b50), end]);
}

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? walk(path) : [path];
  });
}

function u16(value) {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16LE(value);
  return buffer;
}

function u32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value);
  return buffer;
}
