// Actual production routes and numeric loopback HTTP. Owner admission is the
// only replaced HTTP boundary; the pinned engine fixture captures provider POSTs.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { createServer, request as httpRequest } from 'node:http';
import { createCompanionRoutes } from '../../bridge/dsh-go-bridge/lib/companion/routes.js';

export const golden = JSON.parse(await readFile(
  new URL('../../../tooling/companion/fixtures/phone-context.json', import.meta.url), 'utf8'));

export async function phoneHttp(f) {
  const ctx = { get(name) {
    return name === 'connection'
      ? { admit: () => ({ peer: { principal: { kind: 'owner' } } }) }
      : f.ctx.get(name);
  } };
  const routes = createCompanionRoutes({ ctx, store: f.store, recall: f.coordinator, promptContext: f.promptContext,
    send(res, status, data) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(data)); },
  });
  const server = createServer((req, res) => {
    void routes.handle(req, res, new URL(req.url, 'http://fixture').pathname);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const port = server.address().port;
  return {
    url: 'http://127.0.0.1:' + port + '/dsh-go/v1/companion/prompt-context',
    request(value) {
      const get = typeof value === 'string', data = get ? '' : JSON.stringify(value);
      return new Promise((resolve, reject) => {
        const req = httpRequest({ host: '127.0.0.1', port,
          path: '/dsh-go/v1/companion/prompt-context' + (get ? '?sessionId=' + encodeURIComponent(value) : ''),
          method: get ? 'GET' : 'POST',
          headers: get ? {} : { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) },
        }, res => {
          const chunks = []; res.on('data', chunk => chunks.push(chunk));
          res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
        });
        req.on('error', reject); req.end(data);
      });
    },
    async close() {
      routes.dispose(); server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    },
  };
}

export function phoneEnvelope(capability, requestId, empty = false) {
  return { v: 1, instanceId: capability.instanceId, sessionId: capability.sessionId, requestId, events: [],
    phoneMemory: { archiveId: 'R07_SHARED_PHONE_ARCHIVE', controlRevision: 0, historyAfterSeq: 0,
      block: empty ? golden.empty_block : golden.block } };
}

export async function sendPhone(f, agent, requestId, text = golden.query) {
  agent.followup(f.engine.llm.createUserMessage({ source: { kind: 'user', rpcId: requestId },
    content: [{ type: 'text', text }] }));
  await agent.whenIdle();
}

export function assertPhoneWire(body, selected, originalText) {
  const blocks = body.messages.flatMap(message => message.content).filter(content => {
    if (content.type !== 'text') return false;
    try { return JSON.parse(content.text)?.type === 'companion_memory'; } catch { return false; }
  });
  assert.equal(blocks.length, selected ? 1 : 0);
  if (selected) {
    assert.deepEqual(Buffer.from(blocks[0].text, 'utf8'), Buffer.from(golden.block, 'utf8'));
    assert.deepEqual(JSON.parse(blocks[0].text).items.map(item => item.id), golden.selected_ids);
  }
  const system = JSON.stringify(body.system), full = JSON.stringify(body);
  for (const card of golden.cards) {
    assert(!system.includes(card.text), 'The stable system prompt must not contain selected card text');
    if (!selected) {
      assert(!full.includes(card.text));
      assert(!full.includes(card.id));
    }
  }
  assert(!full.includes('R07_LEGACY_NOT_SELECTED'));
  assert.equal(body.messages.at(-1).content[0].text, originalText);
}
