import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
test('the shared gateway stops its heartbeat after the last client closes', {
  skip: !prefix && 'Set DSH_PREFIX to the patched engine prefix',
}, t => {
  const source = readFileSync(join(prefix, 'node_modules/@deepseek-ai/dsh-api-gateway/lib/index.js'), 'utf8');
  const start = source.indexOf('const MAX_MISSED_HEARTBEATS =');
  const end = source.indexOf('var RemoteStreamMuxConnection =', start);
  assert(start >= 0 && end > start);
  t.mock.timers.enable({ apis: ['setInterval'] });
  let callbacks = 0;
  const Server = runInNewContext(source.slice(start, end) + '\nRemoteStreamMuxServer', {
    WebSocket: { OPEN: 1 },
    WebSocketServer: class {
      clients = new Set();
      handleUpgrade(_req, client, _head, accept) {
        this.clients.add(client);
        client.once('close', () => this.clients.delete(client));
        accept(client);
      }
    },
    bindPeer: () => () => {},
    RemoteStreamMuxConnection: class {
      constructor(socket) { this.socket = socket; }
      run() { return once(this.socket, 'close'); }
    },
    clearInterval,
    setInterval(fn, ms) { return setInterval(() => { callbacks++; fn(); }, ms); },
  });
  const server = new Server(undefined, undefined, { heartbeatIntervalMs: 2000 });
  const client = Object.assign(new EventEmitter(), { readyState: 1, ping() {} });
  server.handleUpgrade({}, client, undefined, {});
  t.mock.timers.tick(2000);
  assert.equal(callbacks, 1);
  client.emit('close');
  t.mock.timers.tick(60000);
  assert.equal(callbacks, 1);
});
