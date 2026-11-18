import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import test from 'node:test';
import { createPhoneBridge } from './bridge.mjs';

const browserAction = (name, args) => ({ kind: `browser-${name}`, ...args });

async function fixture(t, options = {}) {
  const token = randomBytes(32).toString('hex');
  const runId = randomUUID();
  const bridge = await createPhoneBridge({ token, runId, timeoutMs: 2000, browserAction, ...options });
  t.after(() => bridge.close());
  const post = async (route, body = {}) => {
    const response = await fetch(bridge.endpoint.baseUrl + route, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ runId, ...body }),
    });
    return { status: response.status, body: await response.json() };
  };
  const execution = { signal: new AbortController().signal, callId: 'call-1', agent: { session: { id: 'session-1' } } };
  return { bridge, post, execution };
}

test('with the app away, ordinary system actions wait for the foreground', async t => {
  const { bridge, post, execution } = await fixture(t);
  const phone = bridge.call('notify', { title: 'a', text: 'b' }, execution);
  assert.equal((await post('/claim', { background: true })).body.request, null);
  const browser = bridge.call('browser:read', {}, execution);
  const claimed = (await post('/claim', { background: true })).body.request;
  assert.equal(claimed.action.kind, 'browser-read');
  await post('/begin', { id: claimed.id });
  await post('/result', { id: claimed.id, text: 'page', isError: false });
  assert.equal((await browser).content[0].text, 'page');
  const front = (await post('/claim')).body.request;
  assert.equal(front.action.kind, 'notify');
  await post('/result', { id: front.id, text: 'declined', isError: true });
  assert.equal((await phone).isError, true);
});

test('a task can claim successive runner observations in the background', async t => {
  const { bridge, post, execution } = await fixture(t);
  for (let index = 0; index < 2; index++) {
    const observation = bridge.call('screen', {}, {
      ...execution, callId: `screen-${index}`,
    });
    const claimed = (await post('/claim', { background: true })).body.request;
    assert.equal(claimed.action.kind, 'runner-call');
    assert.equal(claimed.action.method, 'screen');
    assert.equal(claimed.owner.sessionId, execution.agent.session.id);
    // Claiming still cannot grant permission or report a successful action.
    assert.equal((await post('/result', {
      id: claimed.id, text: 'screen', isError: false,
    })).status, 409);
    await post('/begin', { id: claimed.id });
    await post('/result', { id: claimed.id, text: `screen-${index}`, isError: false });
    assert.equal((await observation).content[0].text, `screen-${index}`);
  }
});

test('a page can be far longer than a phone answer, and a phone answer still can\'t', async t => {
  const { bridge, post, execution } = await fixture(t);
  const long = 'x'.repeat(100 * 1024);
  const browser = bridge.call('browser:read', {}, execution);
  const page = (await post('/claim')).body.request;
  await post('/begin', { id: page.id });
  assert.equal((await post('/result', { id: page.id, text: long, isError: false })).status, 200);
  assert.equal((await browser).content[0].text.length, long.length);
  const phone = bridge.call('notify', { title: 'a', text: 'b' }, execution);
  const action = (await post('/claim')).body.request;
  await post('/begin', { id: action.id });
  assert.equal((await post('/result', { id: action.id, text: long, isError: false })).status, 400);
  await post('/result', { id: action.id, text: 'done', isError: false });
  await phone;
});

test('a screenshot comes back as an image, and only from a browser action', async t => {
  const { bridge, post, execution } = await fixture(t);
  const browser = bridge.call('browser:screenshot', {}, execution);
  const shot = (await post('/claim')).body.request;
  await post('/begin', { id: shot.id });
  assert.equal((await post('/result', { id: shot.id, text: 'shot', isError: false, image: 'AAAA' })).status, 200);
  assert.deepEqual((await browser).content[1], { type: 'image', data: 'AAAA', mimeType: 'image/jpeg' });
  const phone = bridge.call('notify', { title: 'a', text: 'b' }, execution);
  const action = (await post('/claim')).body.request;
  await post('/begin', { id: action.id });
  assert.equal((await post('/result', { id: action.id, text: 'x', isError: false, image: 'AAAA' })).status, 400);
  await post('/result', { id: action.id, text: 'done', isError: false });
  await phone;
});

test('a handoff waits far longer than a prompt', async t => {
  const { bridge, post, execution } = await fixture(t);
  const handoff = bridge.call('browser:handoff', {}, execution);
  const request = (await post('/claim')).body.request;
  assert.ok(request.expiresAt - Date.now() > 500000);
  await post('/result', { id: request.id, text: 'left', isError: true });
  await handoff;
});
