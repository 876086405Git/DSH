import assert from 'node:assert/strict';
import test from 'node:test';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

test('reading each new stdout chunk does not copy an already delivered tail', {
  skip: !process.env.DSH_PREFIX && 'requires a prepared DSH_PREFIX',
}, async t => {
  const path = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-subprocess-local/lib/output.js');
  const { OutputCollector } = await import(pathToFileURL(path));
  const output = new OutputCollector(65536, 'stdout');
  output.push(Buffer.alloc(65536, 97));
  let cursor = output.readFrom(0).nextOffset;
  const concat = Buffer.concat;
  let copiedBytes = 0;
  const probe = t.mock.method(Buffer, 'concat', function (chunks, ...args) {
    copiedBytes += chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    return concat.call(this, chunks, ...args);
  });
  for (let i = 0; i < 128; i++) {
    const chunk = Buffer.alloc(1024, 65 + i % 26);
    output.push(chunk);
    const next = output.readFrom(cursor);
    assert.deepEqual(next, { text: chunk.toString('utf8'), nextOffset: cursor + chunk.length, lossy: false });
    cursor = next.nextOffset;
  }
  probe.mock.restore();
  assert.equal(copiedBytes, 0);
});
