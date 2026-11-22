// Exercise producer cleanup through the real bridge and WebSocket protocol. Each
// case has its own Node process, without a handler for unhandled rejections. The
// loader/context and authorization are fixtures; this does not boot a DSH Host.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { apply } from '../bridge/dsh-go-bridge/lib/index.js';

function gate() {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
}

async function probe(kind, timing, outcome, directory) {
  const pkg = 'cancel-probe';
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ name: pkg, version: '1.0.0', dshGo: {
    v: 1, capabilities: ['micro'], contributes: {
      panels: [{ id: 'panel', title: 'Panel' }], micro: [{ id: 'caption' }],
    },
  } }));
  writeFileSync(join(directory, 'index.js'), '');
  const entry = { options: { name: pathToFileURL(join(directory, 'index.js')).href },
    parent: { tree: { ctx: { baseUrl: pathToFileURL(directory + '/').href } } }, fiber: { uid: 1 } };
  const disposers = [], routes = [], upgrades = [], warnings = [], services = {};
  const connection = { requestRejection() {} };
  const ctx = {
    get: name => name === 'loader' ? { entries: () => [entry] } : name === 'connection' ? connection : services[name],
    logger: { warn: error => warnings.push(String(error)) },
    provide(name, value) { services[name] = value; },
    effect(fn) { const dispose = fn(); if (typeof dispose === 'function') disposers.push(dispose); return dispose; },
    on() {}, inject(names, fn) {
      if (names.every(name => ctx.get(name) ?? ctx[name])) fn(ctx);
    },
    webServer: {
      tapIndex() { return () => {}; },
      register(route) { routes.push(route); return () => {}; },
      registerUpgrade(route) { upgrades.push(route); return () => {}; },
    },
  };
  apply(ctx, { persist: false, guardRoutes: false });
  const service = Object.assign(Object.create(services.dshGo), { ctx: { fiber: { entry }, effect: ctx.effect } });
  const returned = gate(), entered = gate(), finish = gate(), finished = gate();
  let calls = 0, complete = false;
  const cancel = () => {
    calls++;
    entered.resolve();
    if (outcome === 'sync-throw') {
      complete = true;
      finished.resolve();
      throw new Error(`cleanup ${kind} ${timing} sync-throw`);
    }
    return finish.promise.then(() => {
      complete = true;
      finished.resolve();
      if (outcome === 'reject') throw new Error(`cleanup ${kind} ${timing} reject`);
    });
  };
  const data = (_scope, emit) => {
    emit({ text: 'ready' });
    return timing === 'late' ? returned.promise : cancel;
  };
  const remove = kind === 'panel'
    ? service.panel('panel', { view: { type: 'text', text: 'Panel' }, data })
    : service.micro('caption', { data });
  const sockets = new Set();
  const server = createServer((req, res) => {
    const route = routes.find(r => r.kind === 'prefix' && req.url.startsWith(r.path));
    if (route) route.handler(req, res);
    else { res.writeHead(404); res.end(); }
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  server.on('upgrade', (req, socket, head) => upgrades[0].handler(req, socket, head));
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  const socket = new WebSocket(`ws://127.0.0.1:${port}/dsh-go/v1/stream`);
  const messages = [], waiters = [];
  socket.addEventListener('message', event => {
    const value = JSON.parse(event.data);
    const index = waiters.findIndex(w => w.predicate(value));
    if (index < 0) messages.push(value);
    else waiters.splice(index, 1)[0].resolve(value);
  });
  const next = predicate => {
    const index = messages.findIndex(predicate);
    return index < 0 ? new Promise(resolve => waiters.push({ predicate, resolve }))
      : Promise.resolve(messages.splice(index, 1)[0]);
  };
  const send = message => socket.send(JSON.stringify(message));
  try {
    await once(socket, 'open');
    send({ t: 'hello', v: [1], features: ['micro'] });
    assert.equal((await next(m => m.t === 'welcome')).v, 1);
    send({ t: kind === 'panel' ? 'sub' : 'micro.sub', sub: 'source', pkg, id: kind === 'panel' ? 'panel' : 'caption' });
    const first = await next(m => m.t === (kind === 'panel' ? 'data' : 'micro.data'));
    assert.equal(first.data.text, 'ready');
    // This is the service's real disposer. For micro, wait for the actual end
    // sent by its deferred sweep before handing over a late cancel function.
    remove();
    const end = await next(m => m.t === (kind === 'panel' ? 'end' : 'micro.end'));
    assert.equal(end.reason, 'not-found');
    if (timing === 'late') returned.resolve(cancel);
    await entered.promise;
    assert.equal(calls, 1);
    if (outcome !== 'sync-throw') assert.equal(complete, false);
    // Cleanup is allowed to finish asynchronously; retirement must not await it.
    send({ t: 'ping', at: 1 });
    await next(m => m.t === 'pong' && m.at === 1);
    finish.resolve();
    await finished.promise;
    // Real HTTP/WS round trips run after the source cleanup has settled. They
    // also let Node apply its ordinary unhandled-rejection policy in a red run.
    const response = await fetch(`http://127.0.0.1:${port}/dsh-go/v1/contributions?v=1`);
    assert.equal(response.status, 200);
    assert.ok((await response.json()).plugins.some(p => p.pkg === pkg));
    send({ t: 'ping', at: 2 });
    await next(m => m.t === 'pong' && m.at === 2);
    assert.equal(calls, 1);
    return { kind, timing, outcome, calls, complete, warnings: warnings.length };
  } finally {
    socket.close();
    while (disposers.length) disposers.pop()();
    for (const active of sockets) active.destroy();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}

if (process.argv[2] === '--probe') {
  const result = await probe(...process.argv.slice(3));
  process.stdout.write(`${JSON.stringify(result)}\n`);
} else {
  for (const kind of ['panel', 'micro']) for (const timing of ['installed', 'late']) {
    for (const outcome of ['reject', 'resolve', 'sync-throw']) {
      test(`W15 465 cleanup ${kind} ${timing} ${outcome}`, { timeout: 10000 }, async t => {
        const directory = mkdtempSync(join(tmpdir(), 'native-cancel-'));
        const env = { ...process.env, NODE_OPTIONS: '' };
        delete env.NODE_TEST_CONTEXT;
        const child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--probe', kind, timing, outcome, directory], {
          env, stdio: ['ignore', 'pipe', 'pipe'],
        });
        t.after(() => { child.kill(); rmSync(directory, { recursive: true, force: true }); });
        let stdout = '', stderr = '';
        child.stdout.setEncoding('utf8').on('data', text => { stdout += text; });
        child.stderr.setEncoding('utf8').on('data', text => { stderr += text; });
        const [code, signal] = await once(child, 'close');
        assert.equal(signal, null, stderr);
        assert.equal(code, 0, `bridge must keep serving after its producer cleanup: ${stderr}`);
        assert.deepEqual(JSON.parse(stdout), {
          kind, timing, outcome, calls: 1, complete: true,
          warnings: kind === 'panel' && timing === 'installed' && outcome !== 'resolve' ? 1 : 0,
        });
      });
    }
  }
}
