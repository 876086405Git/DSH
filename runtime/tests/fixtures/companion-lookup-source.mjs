// Integrity-bound production plugin source; only Cordis/schema/credential
// services are supplied here. The provider, auth, serialization, dispatch and
// result decoders execute unchanged against a real loopback HTTP peer.
// This is SOURCE_HTTP evidence, not a full Cordis/engine boot or paid API test.
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';

export function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

export async function lookupPeer(t, respond = (_request, response) => {
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify({ results: [{ url: 'https://museum.invalid/notice', title: '馆方公告',
    snippet: '短摘录', summary: '按测试日期临时闭馆', date: null }] }));
}) {
  const requests = [], received = deferred();
  const server = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const captured = { url: request.url, headers: request.headers,
      body: JSON.parse(Buffer.concat(chunks).toString('utf8')) };
    requests.push(captured); received.resolve();
    respond(captured, response);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  });
  return { requests, received, baseURL: `http://127.0.0.1:${server.address().port}/v1/tools` };
}

async function load(path, fetch) {
  const [source, pins] = await Promise.all([
    readFile(path, 'utf8'),
    readFile(new URL('../../patches/pins.json', import.meta.url), 'utf8').then(JSON.parse),
  ]);
  assert.equal(createHash('sha256').update(source).digest('hex'),
    pins.patches['companion-public-lookup-observer.diff']['0.2.2-rc.1']['node_modules/@deepseek-ai/dsh-web-deepseek-api/lib/index.js'].after);
  const schema = { role() { return this; }, volatile() { return this; }, default() { return this; },
    step() { return this; }, min() { return this; }, max() { return this; } };
  const globals = {
    z: { object: () => schema, string: () => schema, number: () => schema, boolean: () => schema },
    credentialRef: value => value, launchEnvironmentOf: () => ({ get: () => undefined }),
    WebError: class extends Error { constructor(message, code, options) { super(message, options); this.code = code; } },
    fetch,
  };
  const imports = source.match(/^import .+;$/gm);
  assert.equal(imports.length, 4, 'only the four framework imports are replaced');
  const key = `companion-lookup-source-${randomUUID()}`;
  globalThis[Symbol.for(key)] = globals;
  try {
    const code = `const { ${Object.keys(globals).join(',')} } = globalThis[Symbol.for(${JSON.stringify(key)})];\n`
      + source.replace(/^import .+;\n/gm, '');
    return await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
  } finally { delete globalThis[Symbol.for(key)]; }
}

export async function lookupSource(path, baseURL, options = {}) {
  const network = [];
  const plugin = await load(path, (url, init) => {
    const address = new URL(url);
    assert.equal(address.hostname, '127.0.0.1', 'source tests never contact a public endpoint');
    assert.equal(init.redirect, 'error');
    network.push({ url, init });
    return options.fetch ? options.fetch(url, init) : globalThis.fetch(url, init);
  });
  const values = { apiKey: undefined, apiKeyEnv: 'LOOKUP_TEST_KEY', baseURL, count: 9, sendOriginalQuestion: true };
  const config = Object.fromEntries(Object.keys(values).map(key => [key, { get: () => values[key] }]));
  const search = new Map(), fetch = new Map(), effects = [], credentialReads = [], accountReads = [];
  const web = { registerSearchProvider(provider) { search.set(provider.id, provider); },
    registerFetchProvider(provider) { fetch.set(provider.id, provider); } };
  const credentials = {
    async describe(reference) { return { configured: options.missingKey !== true }; },
    async resolve(reference) {
      credentialReads.push(reference); options.authEntered?.resolve();
      await options.authGate;
      return options.missingKey ? undefined : { value: 'synthetic-lookup-key' };
    },
  };
  const ctx = { web, effect(fn) { effects.push(fn()); },
    get(name) {
      if (name === 'credentials') return credentials;
      if (name === 'agents') return { currentInitiator: () => ({ session: {
        requestContext: () => ({ provider: 'deepseek-account' }),
        deriveMessages: () => [{ role: 'user', source: { kind: 'user' },
          content: [{ type: 'text', text: 'UNRELATED_PRIVATE_PROMPT' }] }],
      } }) };
      if (name === 'deepseekAccount') return { async resolveToken(endpoint) {
        accountReads.push(endpoint); return options.accountToken;
      } };
    },
  };
  plugin.apply(ctx, config);
  const events = [], abort = new AbortController();
  const observer = { guard() { return options.guard?.(); }, observe(event) { events.push(event); options.observe?.(event); } };
  const prepare = request => web.prepareCompanionLookupCall({ llmProvider: 'chosen-other-model-provider', ...request }, abort.signal, observer);
  return { plugin, web, values, search, fetch, events, network, credentialReads, accountReads, abort, prepare,
    dispose() { for (const effect of effects.splice(0)) effect(); } };
}
