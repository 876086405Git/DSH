import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const prefix = resolve(process.env.OHOS_COMPOSITION_PREFIX);
const processSource = resolve(process.env.OHOS_PROCESS_SOURCE || join(prefix, 'runtime/ohos/process'));
const require = createRequire(join(prefix, 'package.json'));
const { Sha256 } = require('@smithy/core/checksum');
const hash = value => createHash('sha256').update(value).digest('hex');
const hmac = (key, value) => createHmac('sha256', key).update(value).digest();

test('the existing locked Smithy checksum preserves async SHA256/HMAC/reset semantics', async () => {
  for (const secret of [undefined, 'fixture-HMAC-secret']) {
    const value = new Sha256(secret);
    value.update('中文'); value.update(Buffer.from([0, 255, 195, 169]));
    const input = Buffer.concat([Buffer.from('中文'), Buffer.from([0, 255, 195, 169])]);
    const pending = value.digest();
    assert.equal(typeof pending.then, 'function');
    const expected = secret ? hmac(secret, input).toString('hex') : hash(input);
    assert.equal(Buffer.from(await pending).toString('hex'), expected);
    value.reset(); value.update('reset');
    assert.equal(Buffer.from(await value.digest()).toString('hex'), secret ? hmac(secret, 'reset').toString('hex') : hash('reset'));
  }
});

for (const extension of ['mjs', 'js']) {
  test(`actual OpenAI Bedrock ${extension} provider signs a request using the locked checksum`, async () => {
    const file = join(prefix, 'node_modules/openai/providers/bedrock/aws.' + extension);
    const { bedrock } = extension === 'mjs' ? await import(pathToFileURL(file)) : require(file);
    const OpenAI = require('openai');
    let observed;
    const client = new OpenAI({ provider: bedrock({ region: 'us-east-1', endpoint: 'runtime',
      accessKeyId: 'FIXTURE_ACCESS', secretAccessKey: 'fixture-signing-secret' }), maxRetries: 0,
      fetch: async (url, init) => {
        observed = { url: new URL(String(url)), ...init, headers: new Headers(init.headers) };
        return new Response('{"ok":true}', { headers: { 'content-type': 'application/json' } });
      } });
    assert.deepEqual(await client.post('/model/fixture/invoke', { body: { prompt: '中文 payload' } }), { ok: true });
    assert(observed);
    const authorization = observed.headers.get('authorization');
    const match = /^AWS4-HMAC-SHA256 Credential=FIXTURE_ACCESS\/([^,]+), SignedHeaders=([^,]+), Signature=([a-f0-9]{64})$/.exec(authorization);
    assert(match, 'Actual public provider must complete asynchronous SigV4 preparation');
    const [scope, signedHeaders, signature] = match.slice(1);
    const date = observed.headers.get('x-amz-date');
    assert.equal(scope, `${date.slice(0, 8)}/us-east-1/bedrock/aws4_request`);
    const canonicalHeaders = signedHeaders.split(';').map(name => `${name}:${observed.headers.get(name).trim().replace(/\s+/g, ' ')}`).join('\n');
    const canonical = [observed.method, observed.url.pathname, '', canonicalHeaders + '\n', signedHeaders, hash(observed.body)].join('\n');
    const toSign = ['AWS4-HMAC-SHA256', date, scope, hash(canonical)].join('\n');
    const signingKey = hmac(hmac(hmac(hmac('AWS4fixture-signing-secret', date.slice(0, 8)), 'us-east-1'), 'bedrock'), 'aws4_request');
    assert.equal(signature, hmac(signingKey, toSign).toString('hex'), 'Independent node:crypto SigV4 oracle');
  });
}

test('reachable Negotiate auth refuses explicitly before attempting an unshipped native import', async () => {
  assert.equal(process.platform, 'openharmony');
  const { createNegotiateAuth } = await import(pathToFileURL(join(prefix, 'node_modules/proxy-agent-negotiate/dist/index.js')));
  await assert.rejects(createNegotiateAuth()({ scheme: 'Negotiate', response: { headers: {} } }),
    error => error.code === 'OHOS_PROXY_NEGOTIATE_UNAVAILABLE' && /电脑/.test(error.message) && !/npm install/.test(error.message));
});

test('real shell gzip remains usable while the already unavailable tar entry stays explicit', async () => {
  const { VirtualSubprocessRuntime } = await import(pathToFileURL(join(processSource, 'runtime.mjs')));
  const work = await mkdtemp(join(tmpdir(), 'ohos-tar-codecs-'));
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work] });
  try {
    await writeFile(join(work, 'input.txt'), '中文 archive\n');
    for (const command of ['gzip -c input.txt > file.gz; gunzip -c file.gz',
      'tar -czf gzip.tar.gz input.txt', 'tar -cJf xz.tar.xz input.txt', 'tar --zstd -cf zstd.tar.zst input.txt']) {
      const handle = runtime.spawn({ argv: ['bash', '-c', command], cwd: work, graceMs: 200,
        stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
      const result = await handle.done;
      const stderr = handle.collected.stderr.readFrom(0).text;
      if (command.startsWith('tar ')) {
        assert.equal(result.exitCode, 127);
        assert.match(stderr, /不可用.*电脑/);
        assert.doesNotMatch(stderr, /Cannot find|ERR_MODULE_NOT_FOUND|npm install|apt|brew/);
      } else {
        assert.equal(result.exitCode, 0, stderr);
        assert.equal(handle.collected.stdout.readFrom(0).text, '中文 archive\n');
        assert((await readFile(join(work, 'file.gz'))).length > 0);
      }
      assert.equal(await handle.waitForExit(), true);
    }
    assert.equal(runtime.live.size, 0);
  } finally { await runtime.dispose(); await rm(work, { recursive: true, force: true }); }
});
