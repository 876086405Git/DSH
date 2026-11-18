// Session deletion route: capability probing and the guarded mutation contract.
// Pure unit test with an in-memory ctx; no engine, no user sessions.
//   node --test runtime/tests/session-deletion-route.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const { createSessionDeletion } = await import(
  pathToFileURL(resolve(process.env.DSH_SESSION_DELETION_ROUTE ?? 'runtime/bridge/dsh-go-bridge/lib/session-deletion.js'))
);

const CAP = '/dsh-go/v1/sessions/deletion';
const DEL = '/dsh-go/v1/sessions/delete';

function harness({ active = [], tasks = [], fail, scheduleOk = true, tree = false, seamVersion = 2, deletionSupported = true } = {}) {
  const calls = [];
  const logs = [];
  const related = () => Object.assign(new Error('tasks'), { code: 'session-related' });
  const services = {
    sessionPersistence: {
      dshGoDeletion: {
        version: seamVersion, supported: deletionSupported,
        async delete(id, hooks) {
          calls.push(['delete', id]);
          if (fail) throw fail;
          // Mirror the seam: target first plus its subagent descendants, then validate
          // the whole tree, dispose leaves first, and delete leaves first.
          const nodes = tree ? [id, 'child-1'] : [id];
          for (const node of nodes) if (await hooks.inspectTasks(node)) throw related();
          for (const node of nodes) await hooks.validate(node);
          for (const node of nodes.slice(1).reverse()) await hooks.dispose(node, { cascade: true });
          await hooks.dispose(id, { cascade: false });
          for (const node of nodes.slice(1).reverse()) {
            if (await hooks.inspectTasks(node)) throw related();
            await hooks.cleanup(node);
          }
          if (await hooks.inspectTasks(id)) throw related();
          await hooks.cleanup(id);
        },
      },
    },
    agentLoop: {
      dshGoDeletionVersion: 2,
      async dshGoDisposeForDeletion(id, options) {
        calls.push(['dispose', id, options?.cascade === true]);
      },
    },
    sessionProjectionCache: { dshGoDeletionVersion: 1, async dshGoForget(id) { calls.push(['cache', id]); } },
    sessionQuery: { dshGoDeletionVersion: 1, async dshGoForget(id) { calls.push(['query', id]); } },
    schedule: {
      dshGoDeletionVersion: 1,
      async dshGoCanDelete() { return scheduleOk; },
      async dshGoInspectDeletion(id) { calls.push(['tasks', id]); return tasks.includes(id); },
    },
    workspaceRegistry: { dshGoDeletionVersion: 1, async dshGoForget(id) { calls.push(['workspace', id]); } },
  };
  const ctx = {
    get: (name) => services[name],
    waterfall: async (name, args, initial) => {
      calls.push(['activity', args.sessionId]);
      return active.includes(args.sessionId) ? ['turn'] : await initial();
    },
    logger: { warn: () => {} },
  };
  const routes = createSessionDeletion(ctx, {
    readBody: async (req) => Buffer.from(await read(req)),
    send: (res, status, body) => logs.push([status, body]),
  });
  const read = async (req) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    return Buffer.concat(chunks).toString('utf8');
  };
  const request = (method, path, { body, contentType = 'application/json' } = {}) => {
    const req = {
      method,
      headers: { 'content-type': contentType },
      resume() {},
      async *[Symbol.asyncIterator]() {
        if (body !== undefined) yield Buffer.from(body);
      },
    };
    return routes.handle(req, {}, path).then((handled) => ({ handled, last: logs.at(-1) }));
  };
  return { request, calls, logs, services };
}

test('unknown paths are not handled', async () => {
  const h = harness();
  assert.equal((await h.request('GET', '/dsh-go/v1/other')).handled, false);
  assert.deepEqual(h.logs, []);
});

test('capability is false when the pinned seam is absent, and only GET is allowed', async () => {
  const plain = createSessionDeletion({ get: () => undefined, logger: { warn() {} } }, {
    readBody: async () => Buffer.from(''),
    send: (res, status, body) => plainLogs.push([status, body]),
  });
  const plainLogs = [];
  const req = { method: 'GET', headers: {}, resume() {} };
  assert.equal(await plain.handle(req, {}, CAP), true);
  assert.deepEqual(plainLogs, [[200, { supported: false, version: 1 }]]);

  const logs = [];
  const routes = createSessionDeletion({ get: () => undefined }, {
    readBody: async () => Buffer.from(''),
    send: (res, status, body) => logs.push([status, body]),
  });
  await routes.handle({ method: 'POST', headers: {}, resume() {} }, {}, CAP);
  assert.equal(logs[0][0], 405);
  assert.equal(logs[0][1].error.code, 'unavailable');
});

test('capability is true only when every patched seam and the schedule backend are usable', async () => {
  assert.deepEqual((await harness().request('GET', CAP)).last, [200, { supported: true, version: 1 }]);
  assert.deepEqual((await harness({ scheduleOk: false }).request('GET', CAP)).last, [200, { supported: false, version: 1 }]);
  // An engine seam from a previous protocol version is not mistaken for a usable one.
  assert.deepEqual((await harness({ seamVersion: 1 }).request('GET', CAP)).last, [200, { supported: false, version: 1 }]);
});

test('the mutation refuses non-JSON, malformed, oversized and extra-field bodies without deleting', async () => {
  const h = harness();
  assert.equal((await h.request('POST', DEL, { contentType: 'text/plain', body: '{}' })).last[0], 415);
  for (const body of ['', 'not json', '{}', '{"sessionId":""}', '{"sessionId":"a\\u0000b"}', '{"sessionId":"s","extra":1}', '[]', 'null']) {
    const { last } = await h.request('POST', DEL, { body });
    assert.equal(last[0], 400, body);
    assert.equal(last[1].error.code, 'failed');
  }
  const long = await h.request('POST', DEL, { body: JSON.stringify({ sessionId: 'x'.repeat(300) }) });
  assert.equal(long.last[0], 400);
  assert.deepEqual(h.calls.filter(([kind]) => kind === 'delete'), []);
});

test('an unavailable host answers 503 and never runs the destructive path', async () => {
  const ctx = { get: () => undefined };
  const logs = [];
  const routes = createSessionDeletion(ctx, {
    readBody: async () => Buffer.from('{"sessionId":"s"}'),
    send: (res, status, body) => logs.push([status, body]),
  });
  await routes.handle({ method: 'POST', headers: { 'content-type': 'application/json' }, resume() {} }, {}, DEL);
  assert.equal(logs[0][0], 503);
  assert.equal(logs[0][1].error.code, 'unavailable');
});

test('a confirmed deletion validates, disposes, cleans up, and reports the exact id', async () => {
  const h = harness();
  const { last } = await h.request('POST', DEL, { body: JSON.stringify({ sessionId: 's1' }) });
  assert.deepEqual(last, [200, { deleted: true, sessionId: 's1' }]);
  assert.deepEqual(h.calls, [
    ['delete', 's1'],
    ['tasks', 's1'],
    ['activity', 's1'],
    ['dispose', 's1', false],
    ['tasks', 's1'],
    ['cache', 's1'],
    ['query', 's1'],
    ['workspace', 's1'],
  ]);
});

test('a cascading deletion forwards per-session hooks with the cascade flag', async () => {
  const h = harness({ tree: true });
  const { last } = await h.request('POST', DEL, { body: JSON.stringify({ sessionId: 's1' }) });
  assert.deepEqual(last, [200, { deleted: true, sessionId: 's1' }]);
  assert.deepEqual(h.calls, [
    ['delete', 's1'],
    ['tasks', 's1'],
    ['tasks', 'child-1'],
    ['activity', 's1'],
    ['activity', 'child-1'],
    ['dispose', 'child-1', true],
    ['dispose', 's1', false],
    ['tasks', 'child-1'],
    ['cache', 'child-1'],
    ['query', 'child-1'],
    ['workspace', 'child-1'],
    ['tasks', 's1'],
    ['cache', 's1'],
    ['query', 's1'],
    ['workspace', 's1'],
  ]);
});

test('active work anywhere in the tree is refused before any disposal or cleanup', async () => {
  for (const sessionId of ['s1', 'child-1']) {
    const active = harness({ tree: true, active: [sessionId] });
    const { last } = await active.request('POST', DEL, { body: JSON.stringify({ sessionId: 's1' }) });
    assert.equal(last[0], 409);
    assert.equal(last[1].error.code, 'session-active');
    assert.deepEqual(active.calls.filter(([kind]) => kind === 'dispose' || kind === 'cache'), []);
  }
});

test('a reminder on any member refuses the tree without disposal or cleanup', async () => {
  const h = harness({ tree: true, tasks: ['child-1'] });
  const { last } = await h.request('POST', DEL, { body: JSON.stringify({ sessionId: 's1' }) });
  assert.equal(last[0], 409);
  assert.equal(last[1].error.code, 'session-related');
  assert.deepEqual(h.calls.filter(([kind]) => kind === 'dispose' || kind === 'cache'), []);
});

test('engine refusals map to stable codes without leaking host details', async () => {
  for (const [error, status, code] of [
    [Object.assign(new Error('busy'), { code: 'session-active' }), 409, 'session-active'],
    [Object.assign(new Error('x'), { code: 'session-related' }), 409, 'session-related'],
    [Object.assign(new Error('x'), { code: 'writer-held' }), 409, 'writer-held'],
    [Object.assign(new Error('x'), { code: 'not-found' }), 404, 'not-found'],
    [Object.assign(new Error('/private/path leaked'), { code: 'unavailable' }), 503, 'unavailable'],
    [Object.assign(new Error('/private/path leaked'), { name: 'SessionAlreadyOwnedError' }), 409, 'writer-held'],
    [new Error('/private/path leaked'), 500, 'failed'],
  ]) {
    const h = harness({ fail: error });
    const { last } = await h.request('POST', DEL, { body: '{"sessionId":"s1"}' });
    assert.equal(last[0], status);
    assert.equal(last[1].error.code, code);
    assert.equal(JSON.stringify(last[1]).includes('/private/path'), false);
    assert.equal(JSON.stringify(last[1]).includes('stack'), false);
  }
});

test('the capability probe awaits the seam instead of reporting a pending promise', async () => {
  const h = harness();
  // A missing await would answer supported: true even for a missing seam, or
  // throw for a present one; both show up as a non-object body or a rejection.
  const { last } = await h.request('GET', CAP);
  assert.deepEqual(last, [200, { supported: true, version: 1 }]);
});

// An unavailable new commit must not block cleanup of an already valid marker.
test('known OH publication capability is read-only and does not preempt the seam retry path', async () => {
  const h = harness({ deletionSupported: false });
  assert.deepEqual((await h.request('GET', CAP)).last,
    [200, { supported: process.platform !== 'openharmony', version: 1 }]);
  assert.deepEqual(h.calls, []);
  assert.deepEqual((await h.request('POST', DEL, { body: '{"sessionId":"s1"}' })).last,
    [200, { deleted: true, sessionId: 's1' }]);
});

test('an OH seam without a support getter is not advertised as usable', async () => {
  const h = harness();
  delete h.services.sessionPersistence.dshGoDeletion.supported;
  assert.deepEqual((await h.request('GET', CAP)).last,
    [200, { supported: process.platform !== 'openharmony', version: 1 }]);
  assert.deepEqual(h.calls, []);
  // POST still delegates to the seam, so valid-marker cleanup is not preempted.
  assert.deepEqual((await h.request('POST', DEL, { body: '{"sessionId":"s1"}' })).last,
    [200, { deleted: true, sessionId: 's1' }]);
});
