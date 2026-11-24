import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import { brotliCompressSync } from 'node:zlib';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;

test('brotli loads the same shared word dictionary from its compact representation', { skip: !prefix }, () => {
  const require = createRequire(resolve(prefix, 'package.json'));
  const path = require.resolve('brotli/dec/dictionary-data.js');
  const data = require(path);
  const words = data.init();
  assert.equal(Object.getPrototypeOf(words), Uint8Array.prototype);
  assert.equal(words, data.dictionary);
  assert.equal(words.byteOffset, 0);
  assert.equal(words.buffer.byteLength, 122784);
  assert.equal(words.byteLength, 122784);
  assert.equal(createHash('sha256').update(words).digest('hex'),
    '20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70');
  const sample = Buffer.from('The compression dictionary contains common words and phrases.');
  assert.deepEqual(Buffer.from(require('brotli/decompress.js')(brotliCompressSync(sample))), sample);
  assert.ok(statSync(path).size < words.byteLength);
});
