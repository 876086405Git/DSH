// Execute the actual P2 consumer, with only its type syntax erased on Node 24.
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { stripTypeScriptTypes } from 'node:module';

if (process.version !== 'v24.22.1') throw new Error('Manifest validation requires Node 24.22.1');
const source = await readFile(process.argv[2], 'utf8');
const code = stripTypeScriptTypes(source, { mode: 'strip' });
const { validateManifest } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const manifest = validateManifest(JSON.parse(await readFile(process.argv[3], 'utf8')));
console.log(JSON.stringify({ status: 'PASS', runtimeVersion: manifest.runtimeVersion,
  files: manifest.files.length, sourceSha256: createHash('sha256').update(source).digest('hex'),
  scope: 'Actual P2 RuntimeCore manifest consumer on Linux; not Ark compilation or installation' }));
