import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { openAsBlob } from 'node:fs';
import { mkdtemp, open, rm, utimes } from 'node:fs/promises';
import http from 'node:http';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const api = process.env.DSH_GO_UNDICI_BUNDLE
  ? require(path.resolve(process.env.DSH_GO_UNDICI_BUNDLE)) : globalThis;
const dispatcher = process.env.DSH_GO_HTTP_DISPATCHER
  ? (await import(pathToFileURL(path.resolve(process.env.DSH_GO_HTTP_DISPATCHER)))).createHttpDispatcher()
  : undefined;
after(async () => { await dispatcher?.close(); });

async function redirectRound(status, makeRequest, verify) {
  const rows = [];
  const server = http.createServer(async (request, response) => {
    try {
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const body = Buffer.concat(chunks);
      rows.push({
        method: request.method, type: request.headers['content-type'],
        declaredLength: request.headers['content-length'], bytes: body.byteLength,
        bodyBoundary: body.toString().split('\r\n')[0].slice(2),
        digest: createHash('sha256').update(body).digest('hex'),
        body: body.toString(),
      });
      if (request.url === '/start') response.writeHead(status, { location: '/end' });
      response.end('ok');
    } catch (error) {
      response.destroy(error);
    }
  }).listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const request = makeRequest(`http://127.0.0.1:${server.address().port}/start`);
    const response = await api.fetch(request, { dispatcher });
    assert.equal(await response.text(), 'ok');
    assert.equal(rows.length, 2);
    verify(rows);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

function form() {
  const body = new api.FormData();
  body.append('名称', '中文\n第二行');
  body.append('重复', '一');
  body.append('重复', '二');
  body.append('附件', new Blob(['file bytes\0\r\n']), '中文文件.txt');
  return body;
}

function assertReplay(rows) {
  for (const row of rows) {
    assert.equal(row.type.split('boundary=')[1], row.bodyBoundary, 'header/body boundary differs');
    assert.equal(Number(row.declaredLength), row.bytes, 'content-length differs');
  }
  assert.equal(rows[0].type, rows[1].type);
  assert.equal(rows[0].digest, rows[1].digest, 'redirect changed serialized body');
  assert.equal(rows[0].method, rows[1].method);
}

for (const [status, method] of [[307, 'POST'], [308, 'POST'], [301, 'PUT'], [302, 'PUT']]) {
  test(`FormData ${method} ${status} replays the same multipart bytes`, async () => {
    await redirectRound(status, (url) => new api.Request(url, { method, body: form() }), assertReplay);
  });
}

test('empty FormData keeps its closing boundary across 307', async () => {
  await redirectRound(307, (url) => new api.Request(url, {
    method: 'POST', body: new api.FormData(),
  }), (rows) => {
    // An empty body starts with the closing delimiter, which has two extra dashes.
    for (const row of rows) row.bodyBoundary = row.bodyBoundary.slice(0, -2);
    assertReplay(rows);
  });
});

test('changing the original FormData after Request creation cannot change a replay', async () => {
  await redirectRound(308, (url) => {
    const body = form();
    const request = new api.Request(url, { method: 'POST', body });
    body.set('名称', 'later mutation');
    body.delete('附件');
    return request;
  }, (rows) => {
    assertReplay(rows);
    assert.ok(rows.every((row) => !row.body.includes('later mutation')));
  });
});

test('a cloned Request retains the same replayable body', async () => {
  let original;
  await redirectRound(307, (url) => {
    original = new api.Request(url, { method: 'POST', body: form() });
    return original.clone();
  }, assertReplay);
  const originalBytes = await original.arrayBuffer();
  assert.ok(originalBytes.byteLength > 0);
});

test('303 still drops POST body and body headers', async () => {
  await redirectRound(303, (url) => new api.Request(url, { method: 'POST', body: form() }), (rows) => {
    assert.equal(rows[0].method, 'POST');
    assert.equal(rows[1].method, 'GET');
    assert.equal(rows[1].bytes, 0);
    assert.equal(rows[1].type, undefined);
    assert.equal(rows[1].declaredLength, undefined);
  });
});

test('the replay Blob retains a lazy file-backed handle', async (t) => {
  assert.ok(process.env.DSH_GO_UNDICI_SOURCE, 'set DSH_GO_UNDICI_SOURCE to the exact Undici source directory');
  const sourceRoot = path.resolve(process.env.DSH_GO_UNDICI_SOURCE);
  const { extractBody } = require(path.join(sourceRoot, 'lib/web/fetch/body.js'));
  const { FormData } = require(path.join(sourceRoot, 'lib/web/fetch/formdata.js'));
  const directory = await mkdtemp(path.join(os.tmpdir(), 'ohos-formdata-'));
  try {
    const filename = path.join(directory, '大型文件.bin');
    const file = await open(filename, 'wx');
    await file.truncate(128 * 1024 * 1024);
    await file.close();
    const body = new FormData();
    body.append('data', await openAsBlob(filename), 'large.bin');
    // Isolate replay-source construction from the upstream first-send producer.
    // That producer is unchanged by this patch; this is not a peak-upload-memory test.
    body.get('data').stream = () => new ReadableStream({ start(controller) { controller.close(); } });
    const before = process.memoryUsage();
    const [extracted] = extractBody(body);
    const after = process.memoryUsage();
    await new Response(extracted.stream).arrayBuffer();
    assert.ok(extracted.source instanceof Blob);
    assert.ok(extracted.source.size > 128 * 1024 * 1024);
    t.diagnostic(JSON.stringify({ sparseFileBytes: 128 * 1024 * 1024,
      rssDelta: after.rss - before.rss, arrayBuffersDelta: after.arrayBuffers - before.arrayBuffers }));
    const prefix = Buffer.from(await extracted.source.slice(0, 256).arrayBuffer());
    const fileStart = prefix.indexOf('\r\n\r\n') + 4;
    assert.ok(fileStart >= 4);
    await utimes(filename, 1, 2);
    await assert.rejects(extracted.source.slice(fileStart, fileStart + 1).arrayBuffer(),
      (error) => error.name === 'NotReadableError');
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
