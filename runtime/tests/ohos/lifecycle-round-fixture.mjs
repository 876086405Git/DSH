// Test-only observer: the original O0 controller still drives all real tools.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
export const inject = ['ohosLifecycle', 'connection', 'webServer', 'agents', 'sessions', 'sessionPersistence'];

export function apply(ctx, config) {
  assert.equal(config.confirmTestRound, true);
  const output = resolve(config.output);
  ctx.on('agent/turn-stopping', async ({ agent, signal }) => {
    const record = { status: 'BLOCKED', sessionId: agent.session.id };
    try {
      const origin = ctx.webServer.getOrigin(), path = origin + '/dsh-go/v1/lifecycle';
      const login = await fetch(ctx.connection.authenticatedUrl(origin), { redirect: 'manual', signal });
      assert.equal(login.status, 303);
      const cookie = login.headers.getSetCookie().find(value => value.startsWith('dsh-auth-')).split(';')[0];
      const request = async (url, init = {}) => {
        const response = await fetch(url, { signal, ...init });
        const text = await response.text();
        return { status: response.status,
          body: text ? (response.headers.get('content-type')?.startsWith('application/json') ? JSON.parse(text) : text) : undefined,
          headers: Object.fromEntries(response.headers) };
      };
      const unauthorized = await request(path); assert.equal(unauthorized.status, 401);
      const badOrigin = await request(path, { headers: { cookie, origin: 'https://not-allowed.invalid' } }); assert.equal(badOrigin.status, 403);
      const query = '?sessionId=' + encodeURIComponent(agent.session.id);
      const before = await request(path + query, { headers: { cookie } });
      assert.equal(before.status, 200); assert.equal(before.body.blocked, false);
      assert.equal(before.body.calls.length, 5);
      assert(before.body.calls.every(call => call.phase === 'committed' && call.active === false));
      assert.deepEqual(before.body.calls.map(call => call.name), ['write', 'edit', 'read', 'grep', 'bash']);
      const capabilityPath = origin + '/dsh-go/v1/runtime-capabilities';
      const unauthorizedCapability = await request(capabilityPath); assert.equal(unauthorizedCapability.status, 401);
      const capabilities = await request(capabilityPath, { headers: { cookie } });
      assert.equal(capabilities.status, 200); assert.equal(capabilities.body.background.resume, 'reconcile');
      assert.equal(capabilities.body.background.computePermission, 'unknown');
      const post = body => request(path, { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: JSON.stringify(body) });
      const paused = await post({ operation: 'pause' });
      assert.equal(paused.status, 200); assert.equal(paused.body.confirmedPause, true);
      const resumed = await post({ operation: 'resume' });
      record.before = before; record.paused = paused; record.resumed = resumed;
      assert.equal(resumed.status, 200); assert.equal(resumed.body.confirmedPause, false);
      assert.equal(resumed.body.transport.generation, before.body.transport.generation + 1);
      const result = await request(path + '/result' + query + '&callSeq=' + before.body.calls[0].callSeq, { headers: { cookie } });
      assert.equal(result.status, 200); assert.equal(result.body.final, true);
      const handle = await ctx.sessionPersistence.open(agent.session.id, 'read');
      let events;
      try { events = (await handle.read(0)).events; } finally { await handle.close(); }
      const actual = events.find(event => event.type === 'tool/result' && event.sourceEventSeqs?.[0] === result.body.identity.callSeq);
      assert.deepEqual(result.body.sessionData, actual.data);
      const invalid = await post({ operation: 'runAgain', sessionId: agent.session.id }); assert.equal(invalid.status, 400);
      const method = await request(path, { method: 'DELETE', headers: { cookie } }); assert.equal(method.status, 405);
      const absent = await request(path + '/result' + query + '&callSeq=9007199254740991', { headers: { cookie } }); assert.equal(absent.status, 404);
      const oversized = await request(path, { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: ' '.repeat(8193) }); assert.equal(oversized.status, 413);
      record.http = { unauthenticated: unauthorized.status, untrustedOrigin: badOrigin.status, status: before.status,
        pause: paused.status, resume: resumed.status, result: result.status, invalid: invalid.status,
        unsupportedMethod: method.status, missingResult: absent.status, oversized: oversized.status };
      record.state = before.body; record.afterResume = resumed.body; record.exactStoredSessionData = true;
      // Last observer action: the real owner closes, and the same authenticated
      // read-only route must stop advertising reconciliation on its next GET.
      await ctx.ohosLifecycle.close();
      const closedCapabilities = await request(capabilityPath, { headers: { cookie } });
      assert.equal(closedCapabilities.status, 200); assert.equal(closedCapabilities.body.background.resume, 'none');
      record.capabilities = { unauthenticated: unauthorizedCapability.status, before: capabilities.body.background,
        afterClose: closedCapabilities.body.background, sameBoot: capabilities.body.bootId === closedCapabilities.body.bootId };
      assert.equal(record.capabilities.sameBoot, true);
      record.status = 'PASS_SCOPED';
    } catch (error) { record.error = { name: error.name, message: error.message }; throw error; }
    finally { await writeFile(output, JSON.stringify(record, null, 2) + '\n', { flag: 'wx', mode: 0o600 }); }
  });
}
