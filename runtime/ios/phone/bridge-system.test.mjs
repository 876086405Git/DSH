import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createPhoneBridge } from './bridge.mjs';
import { actionFor, names } from '../system/actions.mjs';
import { resultFor } from '../system/results.mjs';

// plugin.mjs imports the engine's own MCP package, which isn't here outside the engine.
const systemAction = (name, args) => ({ kind: `system-${name}`, params: JSON.stringify(actionFor(name, args).args) });
const id = 'abcdefghijklmnop';
const version = 'a'.repeat(64);

async function fixture(t) {
  const token = randomBytes(32).toString('hex');
  const runId = randomUUID();
  const bridge = await createPhoneBridge({ token, runId, timeoutMs: 2000, systemAction });
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

test('every tool in the catalog is one the checks know, and the other way round', () => {
  const catalog = JSON.parse(readFileSync(new URL('../system/catalog.json', import.meta.url)));
  assert.deepEqual(catalog.map(tool => tool.name).sort(), [...names].sort());
  for (const tool of catalog) {
    assert.equal(typeof tool.description, 'string');
    assert.equal(tool.inputSchema.type, 'object');
  }
});

test('a system tool waits for the app to be in front', async t => {
  const { bridge, post, execution } = await fixture(t);
  const call = bridge.call('system:location_current', {}, execution);
  assert.equal((await post('/claim', { background: true })).body.request, null);
  const claimed = (await post('/claim')).body.request;
  assert.equal(claimed.action.kind, 'system-location_current');
  assert.equal(claimed.action.params, '{}');
  await post('/result', { id: claimed.id, text: 'declined', isError: true });
  assert.equal((await call).isError, true);
});

test('arguments are checked before anything reaches the app', async t => {
  const { bridge, post, execution } = await fixture(t);
  const refused = await bridge.call('system:reminders_create', { title: ' ', extra: 1 }, execution);
  assert.equal(refused.isError, true);
  assert.match(refused.content[0].text, /ERR_IOS_SYSTEM_INPUT/);
  assert.equal((await post('/claim')).body.request, null);
});

test('only what was asked for goes across, and success still needs /begin', async t => {
  const { bridge, post, execution } = await fixture(t);
  const call = bridge.call('system:contacts_search', { query: 'Ann', fields: ['phone'] }, execution);
  const claimed = (await post('/claim')).body.request;
  assert.deepEqual(JSON.parse(claimed.action.params), { query: 'Ann', limit: 10, fields: ['phone'] });
  const answer = JSON.stringify({ scope: 'full', items: [], truncated: false });
  assert.equal((await post('/result', { id: claimed.id, text: answer, isError: false })).status, 409);
  await post('/begin', { id: claimed.id });
  assert.equal((await post('/result', { id: claimed.id, text: answer, isError: false })).status, 200);
  assert.equal((await call).isError, false);
});

test('a system answer has its own size limit', async t => {
  const { bridge, post, execution } = await fixture(t);
  const call = bridge.call('system:reminders_list', {}, execution);
  const claimed = (await post('/claim')).body.request;
  await post('/begin', { id: claimed.id });
  assert.equal((await post('/result', { id: claimed.id, text: 'x'.repeat(32769), isError: false })).status, 400);
  assert.equal((await post('/result', { id: claimed.id, text: 'x'.repeat(32768), isError: false })).status, 200);
  await call;
});

test('what the app has to send back matches what the checks accept', () => {
  const reminder = { id, version, title: '买牛奶', completed: false, due: '2026-11-04T08:00:00.000Z' };
  const samples = {
    reminders_list: [{}, { scope: 'full', items: [reminder], truncated: false }],
    reminders_create: [{ title: '买牛奶' }, { committed: true, item: reminder }],
    reminders_complete: [{ id, version, completed: true }, { committed: true, item: { ...reminder, completed: true } }],
    contacts_search: [{ query: 'A', fields: ['email', 'phone'] }, {
      scope: 'limited', truncated: false, items: [{ id, display_name: 'Ann', phone: ['+1 555'], email: ['a@example.com'] }],
    }],
    contacts_create: [{ given_name: 'Ann' }, { committed: true, id }],
    photos_select: [{}, { items: [{ handle: id, width: 10, height: 10, bytes: 100, expires_at: '2026-11-04T08:00:00.000Z' }] }],
    location_current: [{}, {
      latitude: 1, longitude: 2, horizontal_accuracy_m: 5, accuracy_authorization: 'reduced', timestamp: '2026-11-04T08:00:00.000Z',
    }],
    vision_ocr: [{ image_handle: id }, { text: '', truncated: false }],
  };
  assert.deepEqual(Object.keys(samples).sort(), [...names].sort());
  for (const [name, [args, value]] of Object.entries(samples)) {
    assert.deepEqual(resultFor(actionFor(name, args), value), value, name);
  }
});

test('an answer that doesn\'t match is refused', () => {
  const complete = actionFor('reminders_complete', { id, version, completed: true });
  const other = { id: 'zzzzzzzzzzzzzzzz', version, title: 'a', completed: true };
  assert.throws(() => resultFor(complete, { committed: true, item: other }));
  assert.throws(() => resultFor(complete, { committed: false, item: { id, version, title: 'a', completed: true } }));
  const search = actionFor('contacts_search', { query: 'A' });
  // A field nobody asked for doesn't get through.
  assert.throws(() => resultFor(search, { scope: 'full', truncated: false, items: [{ id, display_name: 'Ann', phone: ['1'] }] }));
  assert.throws(() => resultFor(actionFor('reminders_list', {}), { scope: 'full', truncated: false, items: [{ id, version, title: ' ', completed: false }] }));
  assert.throws(() => resultFor(actionFor('location_current', {}), {
    latitude: 91, longitude: 0, horizontal_accuracy_m: 1, accuracy_authorization: 'full', timestamp: '2026-11-04T08:00:00.000Z',
  }));
});
