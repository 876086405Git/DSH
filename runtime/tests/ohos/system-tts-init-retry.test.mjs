import test from 'node:test';
import assert from 'node:assert/strict';
import { systemTtsFixture, deferred, until } from './system-tts-fixture.mjs';

const call = (f, method, args = {}) => f.call(f.methods, method, args).done;
const ready = f => call(f, 'ready', { language: 'zh-CN' });
const speak = (f, id) => call(f, 'speak', { id, text: '首次初始化后的重试。', rate: 1, pitch: 1.12 });

for (const shutdownFails of [false, true]) {
  test(`initial create settles during stop; shutdownFails=${shutdownFails}; readiness does not falsely authorize a line`, async () => {
    const creation = deferred();
    const f = systemTtsFixture({ create: () => creation.promise, shutdownError: shutdownFails });
    const firstReady = ready(f);
    await until(() => f.trace.includes('tts.create'));
    const stopped = call(f, 'stop');
    // The SDK allocation really completes now. No precomputed ready reply is
    // reordered and no SDK success is fabricated after a cancelled generation.
    creation.resolve();
    assert.deepEqual(await firstReady, { value: false });
    const stopReply = await stopped;
    if (shutdownFails) assert.equal(stopReply.error, 'speech-output');
    else assert.deepEqual(stopReply, { value: null });
    assert.equal(f.engines[0].calls.length, 0);

    // The finite failure is gone. A bare readiness retry may either decline
    // pending retirement or recover. It must not report true then reject a
    // valid first line merely because the same engine was never prepared.
    f.change({ create: undefined, shutdownError: false });
    const retryReady = await ready(f);
    const retrySpeak = await speak(f, 'retry');
    const beforeExplicitStop = {
      ready: retryReady, speak: retrySpeak,
      engines: f.engines.map(e => ({ shutdowns: e.shutdowns, closed: e.closed === true, speaks: e.calls.length })),
      trace: [...f.trace],
    };

    // Explicit stop is the existing recovery contract; finish it even when
    // the earlier assertion is going to be red. No handle is left pending.
    assert.deepEqual(await call(f, 'stop'), { value: null });
    assert.deepEqual(await ready(f), { value: true });
    assert.deepEqual(await speak(f, 'after-explicit-stop'), { value: true });
    assert.deepEqual(await call(f, 'stop'), { value: null });
    assert(f.engines.every(e => e.closed === true));
    console.log('TTS_RETRY_WITNESS ' + JSON.stringify({ shutdownFails, beforeExplicitStop, allClosed: true }));

    if (!shutdownFails) {
      assert.deepEqual(retryReady, { value: true });
      assert.deepEqual(retrySpeak, { value: true });
    }
    assert.equal(retryReady.value === true && retrySpeak.value !== true, false,
      'READY_TRUE_THEN_UNPREPARED_SPEAK_FALSE_WITH_NO_INTERVENING_OWNER_CHANGE');
  });
}
