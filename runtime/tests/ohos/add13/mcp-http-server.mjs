// Private ADD13 fixture. Importing this file does not open a listener.
// Wire fields follow the bound @modelcontextprotocol/client 2.2.0 source.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';

const VERSION = '2026-07-28';
const VERSION_KEY = 'io.modelcontextprotocol/protocolVersion';
const CLIENT_CAPABILITIES_KEY = 'io.modelcontextprotocol/clientCapabilities';
const SERVER_INFO_KEY = 'io.modelcontextprotocol/serverInfo';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const errorRecord = error => ({ name: error?.name, code: error?.code, message: String(error?.message ?? error) });

export async function startOwnedMcpFixture({ output, host = '127.0.0.1' }) {
  if (!isAbsolute(output)) throw new TypeError('The fixture output must be an explicit absolute path');
  await mkdir(output, { recursive: false });
  const events = [];
  const waiters = new Set();
  const sockets = new Set();
  const holds = new Map();
  const operations = new Set();
  let closing = false;
  let nextRequest = 0;
  let nextSocket = 0;
  const socketIds = new WeakMap();
  const note = (type, detail = {}) => {
    const row = { sequence: events.length + 1, utc: new Date().toISOString(), monotonicNs: process.hrtime.bigint().toString(), type, ...detail };
    events.push(row);
    for (const waiter of [...waiters]) if (waiter.predicate(row)) {
      clearTimeout(waiter.timer);
      waiters.delete(waiter);
      waiter.resolve(row);
    }
    return row;
  };
  const raw = async (stem, suffix, bytes) => {
    const name = `${stem}.${suffix}`;
    await writeFile(join(output, name), bytes, { flag: 'wx' });
    return { name, bytes: bytes.length, sha256: digest(bytes) };
  };
  const jsonReply = async (response, stem, status, body) => {
    const bytes = Buffer.from(JSON.stringify(body));
    const saved = await raw(stem, 'response.bin', bytes);
    note('response', { request: stem, status, body, raw: saved });
    response.writeHead(status, { 'content-type': 'application/json', 'content-length': bytes.length });
    response.end(bytes);
  };
  const complete = result => ({ resultType: 'complete', ...result });
  const toolSchema = name => ({
    name,
    description: `Owned ADD13 ${name} fixture`,
    inputSchema: { type: 'object', properties: { message: { type: 'string' } }, required: ['message'], additionalProperties: false },
  });
  const handle = async (request, response) => {
    const stem = String(++nextRequest).padStart(3, '0');
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const bytes = Buffer.concat(chunks);
    const saved = await raw(stem, 'request.bin', bytes);
    note('request', { request: stem, method: request.method, url: request.url, socket: socketIds.get(request.socket), headers: request.headers, raw: saved });
    if (request.url !== '/mcp' || request.method !== 'POST') {
      response.writeHead(request.url === '/mcp' ? 405 : 404, { allow: 'POST' });
      response.end();
      note('non-post-response', { request: stem, status: request.url === '/mcp' ? 405 : 404 });
      return;
    }
    const message = JSON.parse(bytes.toString('utf8'));
    if (message.jsonrpc !== '2.0' || message.id === undefined || Array.isArray(message)) throw new Error('Expected one JSON-RPC request with an id');
    const meta = message.params?._meta;
    if (meta?.[VERSION_KEY] !== VERSION || !Object.hasOwn(meta, CLIENT_CAPABILITIES_KEY)) throw new Error('Expected the bound modern per-request MCP envelope');
    note('rpc', { request: stem, id: message.id, method: message.method, params: message.params });
    if (message.method === 'server/discover') {
      await jsonReply(response, stem, 200, { jsonrpc: '2.0', id: message.id, result: complete({
        ttlMs: 0, cacheScope: 'private', supportedVersions: [VERSION], capabilities: { tools: {} },
        _meta: { [SERVER_INFO_KEY]: { name: 'add13-owned-http', version: '1.0.0' } },
      }) });
      return;
    }
    if (message.method === 'tools/list') {
      await jsonReply(response, stem, 200, { jsonrpc: '2.0', id: message.id, result: complete({
        ttlMs: 0, cacheScope: 'private', tools: [toolSchema('echo'), toolSchema('hold')],
      }) });
      return;
    }
    if (message.method === 'tools/call' && message.params?.name === 'echo') {
      const value = { fixture: 'add13-owned-http', received: message.params.arguments?.message };
      await jsonReply(response, stem, 200, { jsonrpc: '2.0', id: message.id, result: complete({
        content: [{ type: 'text', text: JSON.stringify(value) }], structuredContent: value,
      }) });
      return;
    }
    if (message.method === 'tools/call' && message.params?.name === 'hold') {
      const bytes = Buffer.from(': add13-owned-hold-open\n\n');
      const saved = await raw(stem, 'sse-open.bin', bytes);
      holds.set(stem, response);
      response.on('close', () => {
        holds.delete(stem);
        note('hold-closed', { request: stem, id: message.id, fixtureClosing: closing, writableFinished: response.writableFinished });
      });
      response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      response.write(bytes);
      note('hold-open', { request: stem, id: message.id, raw: saved });
      return;
    }
    await jsonReply(response, stem, 200, { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'The owned fixture has no such method or tool' } });
  };
  const server = createServer((request, response) => {
    const operation = handle(request, response).catch(error => {
      note('fixture-error', { error: errorRecord(error) });
      if (!response.headersSent) response.writeHead(500, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: errorRecord(error) }));
    });
    operations.add(operation);
    operation.finally(() => operations.delete(operation));
  });
  server.on('connection', socket => {
    sockets.add(socket);
    socketIds.set(socket, ++nextSocket);
    note('socket-open', { socket: socketIds.get(socket) });
    socket.once('close', hadError => {
      sockets.delete(socket);
      note('socket-close', { socket: socketIds.get(socket), hadError, fixtureClosing: closing });
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen({ host, port: 0 }, resolve);
  });
  const address = server.address();
  const url = `http://${address.family === 'IPv6' ? `[${address.address}]` : address.address}:${address.port}/mcp`;
  note('listening', { url, address });
  let finalization;
  return Object.freeze({
    url,
    events,
    activeHolds: () => holds.size,
    waitFor(predicate, timeoutMs = 5000) {
      const observed = events.find(predicate);
      if (observed) return Promise.resolve(observed);
      return new Promise((resolve, reject) => {
        const waiter = { predicate, resolve, timer: undefined };
        waiter.timer = setTimeout(() => { waiters.delete(waiter); reject(new Error('Owned MCP fixture observation deadline exceeded')); }, timeoutMs);
        waiters.add(waiter);
      });
    },
    close() {
      if (finalization) return finalization;
      closing = true;
      note('fixture-cleanup-start', { activeHolds: holds.size, sockets: sockets.size });
      finalization = (async () => {
        const stopped = new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
        // Cleanup is recorded separately; it must not satisfy the cancellation assertion.
        for (const socket of sockets) socket.destroy();
        await stopped;
        await Promise.allSettled([...operations]);
        note('fixture-cleanup-end', { activeHolds: holds.size, sockets: sockets.size });
        await writeFile(join(output, 'events.json'), JSON.stringify(events, null, 2) + '\n', { flag: 'wx' });
        return { activeHolds: holds.size, sockets: sockets.size };
      })();
      return finalization;
    },
  });
}
