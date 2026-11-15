// One real DiagnosticsPlugin: fault journal I/O and own-window geometry coexist.
// Real Linux persistence; only HiAppEvent, Window and Flutter are SDK boundaries.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { diagnosticsFixture, deferred, until } from './diagnostics-fixture.mjs';

const repo = process.env.OHOS_DIAGNOSTIC_SOURCE_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url));

test('fault drain and voice persistence do not block bound keyboard collection or background clearing', async t => {
  const fixture = await diagnosticsFixture(t);
  const Keyboard = fixture.load(resolve(repo, 'app/ohos/entry/src/main/ets/plugins/OhosKeyboardLog.ets')).OhosKeyboardLog;
  const keyboard = new Keyboard();
  const gate = deferred();
  let waiting = false;
  fixture.change({ write: async () => { if (!waiting) { waiting = true; await gate.promise; } } });
  fixture.faults.queue.push({ domain: 'OS', name: 'APP_FREEZE', eventType: 1, params: { time: 1234 } });
  const instance = fixture.attach(new fixture.Plugin(keyboard));
  let info;
  let record;
  try {
    await until(() => waiting, 'real fault journal write reached the controlled I/O boundary');
    info = fixture.call(instance, 'info');
    await until(() => fixture.operations.some(row => row.op === 'raw-close'), 'real manifest FD closed before info waits for fault drain');
    assert.equal(info.replies.length, 0);
    assert.equal((await fixture.call(instance, 'engineLog').done).error, 'busy');
    assert.equal((await fixture.call(instance, 'recordVoiceStage', { stage: 'not-a-stage' }).done).error, 'invalid_evidence');
    record = fixture.call(instance, 'recordVoiceStage', { stage: 'capture_started', backend: 'system' });
    assert.equal(record.replies.length, 0, 'valid evidence waits for disk, rather than borrowing the info busy slot');

    const first = fixture.call(instance, 'collectSystemIme');
    assert.equal(first.replies.length, 1, 'manual geometry collection replies without awaiting disk');
    assert.equal((await first.done).value?.source, 'ohosWindowGeometry', 'collectSystemIme must be implemented by this real DiagnosticsPlugin');

    const callbacks = new Map();
    const window = {
      on(name, callback) { callbacks.set(name, callback); },
      off(name, callback) { if (callbacks.get(name) === callback) callbacks.delete(name); },
    };
    keyboard.attach({ getMainWindowSync: () => window });
    keyboard.setForeground(true);
    callbacks.get('keyboardHeightChange')(620);
    const before = fixture.operations.length;
    const collect = fixture.call(instance, 'collectSystemIme');
    assert.equal(collect.replies.length, 1);
    const captured = (await collect.done).value;
    assert.equal(captured.code, 'ok');
    assert.deepEqual(captured.events.map(row => [row.event, row.geometry.height]), [['height', 620]]);
    assert.equal(fixture.operations.length, before, 'geometry collection performs no filesystem read');
    assert.equal(info.replies.length, 0);
    assert.equal(record.replies.length, 0);
    assert.deepEqual(await fixture.call(instance, 'cancelSystemIme').done, { value: null });
    assert.equal((await fixture.call(instance, 'info').done).error, 'busy', 'geometry cancellation cannot release the unrelated info slot');

    keyboard.setForeground(false);
    callbacks.get('keyboardHeightChange')(900);
    const hidden = (await fixture.call(instance, 'collectSystemIme').done).value;
    assert.equal(hidden.code, 'cancelled');
    assert.deepEqual(hidden.events, []);
    keyboard.setForeground(true);
    const reentered = (await fixture.call(instance, 'collectSystemIme').done).value;
    assert.equal(reentered.code, 'noEvents', 'background clears rows and late hidden callbacks cannot restore them');
    assert.deepEqual(reentered.events, []);

    gate.resolve();
    assert.deepEqual(await record.done, { value: null });
    const result = (await info.done).value.evidence;
    assert.deepEqual(result.processExits.map(row => [row.source, row.event, row.at]), [['hiAppEvent', 'APP_FREEZE', 1234]]);
    assert.deepEqual(result.voiceStages.map(row => [row.stage, row.backend]), [['capture_started', 'system']]);
    assert.equal(result.availability.processExits, 'available');
    const directory = join(fixture.app.filesDir, 'diagnostic-evidence');
    assert.equal(JSON.parse(await fs.readFile(join(directory, 'processExits.json'), 'utf8'))[0].at, 1234);
    assert.equal(JSON.parse(await fs.readFile(join(directory, 'voiceStages.json'), 'utf8'))[0].stage, 'capture_started');
    assert.equal(fixture.fds.size, 0);
    assert.equal(fixture.native.loads, 0);
  } finally {
    gate.resolve();
    await record?.done;
    await info?.done;
    instance.detach();
    keyboard.detach();
  }
});
