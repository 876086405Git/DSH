// Offline diagnostics only: synthetic EventEmitters/chunks, no engine or sockets.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { BoundedLineDecoder, createGuestDiagnostics, diagnosticLimits,
  observeMux, safeError, safeScenario, safeTool } from './guest-diagnostics.mjs';

const marker = 'SYNTHETIC_COMMAND_CREDENTIAL_9f52';
function fixture(mode = 'deny') {
  const log = [], failures = [], frames = [];
  const diagnostic = createGuestDiagnostics({ writeLog: line => log.push(line) });
  const round = diagnostic.startRound(mode), socket = new EventEmitter();
  observeMux(socket, round, { onFailure: error => failures.push(error), onFrame: frame => frames.push(frame) });
  const send = value => socket.emit('message', Buffer.from(JSON.stringify(value)));
  const errorFrame = code => ({ type: 'error', streamId: 'session',
    error: { code, message: marker, details: { command: marker, token: marker } } });
  return { diagnostic, round, socket, log, failures, frames, send, errorFrame };
}
function noMarker(diagnostic, log, markers = [marker]) {
  for (const output of [JSON.stringify(diagnostic.snapshot()), log.join('')])
    for (const value of markers) assert.equal(output.includes(value), false, 'free text escaped the diagnostic boundary');
}

test('guest diagnostics keeps the first mux failure and both server errors through close', async () => {
  const f = fixture(); f.round.setPhase('waiting_approval');
  let reject;
  const pending = new Promise((_, fail) => { reject = fail; }).catch(error => error);
  f.socket.on('message', () => { if (f.round.error) reject(f.round.error); });
  f.send(f.errorFrame('gateway/service-unavailable'));
  const first = f.round.error;
  f.socket.emit('close', 1006, Buffer.alloc(0));
  f.send(f.errorFrame('gateway/internal'));
  assert.equal(await pending, first, 'an already rejected Promise keeps its first reason');
  assert.equal(f.round.error, first);
  assert.ok(f.failures.length >= 3);
  assert.ok(f.failures.every(error => error === first));
  const s = f.diagnostic.snapshot();
  assert.equal(s.firstFailure.failure, 'mux-error');
  assert.equal(s.firstFailure.code, 'gateway/service-unavailable');
  assert.equal(s.firstFailure.phase, 'waiting_approval');
  assert.equal(s.firstServerError.code, 'gateway/service-unavailable');
  assert.equal(s.lastServerError.code, 'gateway/internal');
  assert.equal(s.rounds[0].close.code, 1006);
  assert.equal(s.rounds[0].close.reason, 'empty');
  assert.ok(s.firstServerError.seq < s.rounds[0].close.seq);
  noMarker(f.diagnostic, f.log);
});

test('guest diagnostics keeps an error across a pending RPC with no frame waiter', async () => {
  const f = fixture(); f.round.setPhase('prompt');
  // No Promise/waiter exists when these transport events arrive.
  f.send(f.errorFrame('gateway/internal'));
  const first = f.round.error;
  f.socket.emit('close', 1011, Buffer.from('Remote stream failure could not be delivered'));
  f.round.setPhase('waiting_approval');
  assert.equal(await Promise.reject(f.round.error).catch(error => error), first);
  const s = f.diagnostic.snapshot();
  assert.equal(s.firstFailure.failure, 'mux-error');
  assert.equal(s.firstFailure.phase, 'prompt');
  assert.equal(s.rounds[0].close.reason, 'failure-undeliverable');
});

test('guest diagnostics separates transport errors from unobserved server errors', () => {
  const f = fixture(); f.round.setPhase('opening_mux');
  f.socket.emit('error', Object.assign(new Error(marker), { code: 'ECONNRESET' }));
  const first = f.round.error;
  f.socket.emit('close', 1006, Buffer.from(marker));
  const s = f.diagnostic.snapshot();
  assert.equal(f.round.error, first);
  assert.equal(s.firstFailure.failure, 'mux-transport');
  assert.equal(s.firstFailure.code, 'ECONNRESET');
  assert.equal(s.firstServerError, null);
  assert.equal(s.lastServerError, null);
  assert.equal(s.rounds[0].close.reason, 'withheld');
  assert.equal(s.rounds[0].close.reasonBytes, Buffer.byteLength(marker));
  noMarker(f.diagnostic, f.log);
});

test('guest diagnostics preserves close metadata without inventing a heartbeat cause', () => {
  for (const [code, reason, expected] of [
    [1001,'peer left','peer-left'], [1003,'text messages required','text-required'],
    [1008,'invalid Remote stream request','invalid-request'],
    [1011,'Remote stream failure could not be delivered','failure-undeliverable'],
    [1006,'','empty'], [1000,marker,'withheld'],
  ]) {
    const f = fixture(); f.socket.emit('close', code, Buffer.from(reason));
    const s = f.diagnostic.snapshot();
    assert.equal(s.rounds[0].close.code, code);
    assert.equal(s.rounds[0].close.reason, expected);
    assert.equal(s.firstFailure.failure, 'mux-close');
    assert.equal(s.firstServerError, null);
    assert.equal(JSON.stringify(s).includes('heartbeat'), false);
    noMarker(f.diagnostic, f.log);
  }
  const f = fixture(); f.socket.emit('close', NaN, { reason: marker });
  assert.equal(f.diagnostic.snapshot().rounds[0].close.code, null);
  noMarker(f.diagnostic, f.log);
});

test('guest diagnostics normal local termination cannot fail this or the next round', () => {
  const f = fixture(); f.round.setPhase('complete'); f.round.beginCleanup();
  const next = f.diagnostic.startRound('identity'); next.setPhase('waiting_approval');
  f.socket.emit('error', new Error(marker));
  f.socket.emit('close', 1006, Buffer.alloc(0));
  assert.equal(f.round.error, null); assert.equal(next.error, null);
  assert.deepEqual(f.failures, []);
  const s = f.diagnostic.snapshot();
  assert.equal(s.firstFailure, null); assert.equal(s.beforeCleanup, null);
  assert.equal(s.rounds[0].close.scenario, 'deny');
  assert.equal(s.rounds[0].close.phase, 'complete');
  assert.equal(s.rounds[0].close.afterLocalTerminate, true);
  assert.ok(s.rounds[0].localTerminateRequested < s.rounds[0].close.seq);
  assert.equal(s.rounds[1].close, null);
  noMarker(f.diagnostic, f.log);
});

test('guest diagnostics freezes the failure before terminate quit and exit zero', () => {
  const f = fixture();
  f.diagnostic.childStderr(Buffer.from('TypeError: ' + marker + '\n'));
  f.diagnostic.hostRecord({ kind: 'log', stream: 'stderr', line: '[api-gateway] Remote stream connection failed: ' + marker });
  f.send(f.errorFrame('gateway/internal')); f.round.beginCleanup();
  const frozen = f.diagnostic.snapshot().beforeCleanup;
  f.socket.emit('close', 1006, Buffer.alloc(0));
  f.diagnostic.markCleanup('quit');
  f.diagnostic.failure('cleanup-error', new Error(marker));
  f.diagnostic.hostRecord({ kind: 'exit', exitCode: 0, message: marker });
  f.diagnostic.childExit(0, null);
  for (let i = 0; i < 100; i++) f.diagnostic.childStderr(Buffer.from(marker + '\n'));
  f.diagnostic.childStderrEnd(); f.diagnostic.hostStdoutEnd(); f.diagnostic.stdioClosed();
  const s = f.diagnostic.snapshot();
  assert.deepEqual(s.beforeCleanup, frozen);
  assert.equal(s.beforeCleanup.stderr.child.entries.length, 1);
  assert.equal(s.beforeCleanup.stderr.host.entries.length, 1);
  assert.equal(s.beforeCleanup.engine.childExit, null);
  assert.equal(s.engine.childExit.exitCode, 0);
  assert.equal(s.engine.childExit.afterQuit, true);
  assert.ok(s.firstFailure.seq <= s.beforeCleanup.seq && s.beforeCleanup.seq < s.cleanup.quit);
  assert.equal(s.rounds[0].close.afterLocalTerminate, true);
  assert.equal(s.cleanup.stdioClosed, true);
  s.beforeCleanup.stderr.child.entries.push({ message: marker });
  assert.deepEqual(f.diagnostic.snapshot().beforeCleanup, frozen, 'snapshots cannot mutate retained evidence');
  noMarker(f.diagnostic, f.log);
});

test('guest diagnostics records logical and turn errors without changing approval waiting', () => {
  const f = fixture(); f.round.setPhase('waiting_approval');
  f.send({ type: 'item', streamId: 'session', value: { type: 'event', event: {
    type: 'turn/end', data: { reason: { kind: 'error', error: { code: 'STREAM_CLOSED', message: marker } } },
  } } });
  assert.equal(f.round.error, null); assert.deepEqual(f.failures, []);
  assert.equal(f.diagnostic.snapshot().firstServerError.source, 'turn-end');
  f.send({ type: 'end', streamId: 'session' });
  assert.equal(f.round.error, null);
  assert.equal(f.diagnostic.snapshot().rounds[0].close, null);
  f.send({ type: 'item', streamId: 'host', value: { type: 'emit', event: 'api-session/error', args: [marker, marker] } });
  assert.equal(f.diagnostic.snapshot().lastServerError.source, 'api-session');
  f.round.serverError('rpc', { code: 'session/agent-busy', message: marker, details: marker }, 'session/prompt');
  f.round.fail('rpc-error', { code: 'session/agent-busy', message: marker });
  const s = f.diagnostic.snapshot();
  assert.equal(s.firstServerError.code, 'STREAM_CLOSED');
  assert.equal(s.lastServerError.code, 'session/agent-busy');
  assert.equal(s.firstFailure.failure, 'rpc-error');
  assert.deepEqual(s.eventTypes, ['turn/end']);
  noMarker(f.diagnostic, f.log);
});

test('guest diagnostics line decoding preserves UTF8 CRLF and EOF across every split', () => {
  const text = '中文💫\r\n尾行', bytes = Buffer.from(text);
  for (let split = 0; split <= bytes.length; split++) {
    const lines = [], discarded = [];
    const decoder = new BoundedLineDecoder(100, (line, size) => lines.push([line, size]), size => discarded.push(size));
    decoder.write(bytes.subarray(0, split)); decoder.write(bytes.subarray(split));
    assert.equal(decoder.snapshot().pendingBytes, Buffer.byteLength('尾行'));
    decoder.end(); decoder.end(); decoder.write(Buffer.from(marker));
    assert.deepEqual(lines, [['中文💫', Buffer.byteLength('中文💫\r')], ['尾行', Buffer.byteLength('尾行')]]);
    assert.deepEqual(discarded, []);
    assert.deepEqual(decoder.snapshot(), { ended: true, pendingBytes: 0, pendingOversized: false, pendingTextWithheld: false });
  }
});

test('guest diagnostics separates both stderr channels and withholds split secrets at EOF', () => {
  const f = fixture();
  const child = Buffer.from('Error: ' + marker + ' ?token=跨块秘密\n尾部 ' + marker);
  for (const byte of child) f.diagnostic.childStderr(Buffer.from([byte]));
  const row = { kind: 'log', stream: 'stderr', line: 'TypeError: 中文 ' + marker };
  const hostWire = Buffer.from(JSON.stringify([row]));
  const host = new BoundedLineDecoder(diagnosticLimits.hostJsonLineBytes,
    line => JSON.parse(line).forEach(value => f.diagnostic.hostRecord(value)), () => assert.fail('unexpected transport truncation'));
  for (const byte of hostWire) host.write(Buffer.from([byte]));
  assert.equal(f.diagnostic.snapshot().stderr.host.entries.length, 0, 'host rows wait for complete JSON/EOF');
  host.end(); f.diagnostic.hostStdoutEnd();
  const beforeEOF = f.diagnostic.snapshot();
  assert.equal(beforeEOF.stderr.child.entries.length, 1);
  assert.ok(beforeEOF.stderr.child.pendingBytes > 0);
  assert.equal(beforeEOF.stderr.child.pendingTextWithheld, true);
  f.diagnostic.childStderrEnd();
  const s = f.diagnostic.snapshot();
  assert.equal(s.stderr.child.entries.length, 2);
  assert.equal(s.stderr.host.entries.length, 1);
  assert.equal(s.stderr.child.entries[0].source, 'child');
  assert.equal(s.stderr.host.entries[0].source, 'host');
  assert.equal(s.stderr.host.entries[0].name, 'TypeError');
  assert.equal(s.stderr.child.eof, true); assert.equal(s.stderr.host.eof, true);
  noMarker(f.diagnostic, f.log, [marker, '跨块秘密', '尾部']);
});

test('guest diagnostics discards whole oversized lines and resumes only at the next line', () => {
  const f = fixture(), limit = diagnosticLimits.stderrLineBytes;
  f.diagnostic.childStderr(Buffer.from('x'.repeat(limit) + '\n'));
  assert.equal(f.diagnostic.snapshot().stderr.child.oversizedLines, 0, 'exact fit remains one line');
  const oversized = Buffer.from('TypeError: ' + marker + 'x'.repeat(limit));
  f.diagnostic.childStderr(oversized.subarray(0, 20)); f.diagnostic.childStderr(oversized.subarray(20));
  let s = f.diagnostic.snapshot();
  assert.equal(s.stderr.child.entries.length, 1);
  assert.equal(s.stderr.child.pendingOversized, true);
  assert.equal(s.stderr.child.pendingBytes, oversized.length);
  f.diagnostic.childStderr(Buffer.from('\nError: ' + marker)); f.diagnostic.childStderrEnd();
  f.diagnostic.hostRecord({ kind: 'log', stream: 'stderr', line: 'x'.repeat(limit + 1) + marker });
  s = f.diagnostic.snapshot();
  assert.deepEqual(s.stderr.child.entries.map(row => row.category), ['unclassified-stderr','oversized-stderr','stderr-error']);
  assert.equal(s.stderr.child.oversizedLines, 1); assert.equal(s.stderr.host.oversizedLines, 1);
  assert.equal(s.stderr.child.entries[1].inputBytes, oversized.length);
  const eof = fixture(); eof.diagnostic.childStderr(oversized); eof.diagnostic.childStderrEnd();
  assert.equal(eof.diagnostic.snapshot().stderr.child.oversizedLines, 1);
  noMarker(f.diagnostic, f.log);
});

test('guest diagnostics bounds repeated unique lines and disk output while retaining the cause', () => {
  const f = fixture(); f.send(f.errorFrame('gateway/internal'));
  for (let i = 0; i < 4000; i++) {
    f.diagnostic.childStderr(Buffer.from(marker + (i < 2000 ? '' : i) + '\n'));
    f.diagnostic.hostRecord({ kind: 'log', stream: 'stderr', line: marker });
  }
  const s = f.diagnostic.snapshot();
  for (const source of ['child','host']) {
    assert.equal(s.stderr[source].inputLines, 4000);
    assert.equal(s.stderr[source].entries.length + s.stderr[source].dropped, 4000);
    assert.equal(s.stderr[source].entries.length, 64, 'the line-count bound evicts older small records');
    assert.ok(s.stderr[source].bytes <= 32 * 1024);
    assert.equal(s.stderr[source].bytes, s.stderr[source].entries.reduce((n, row) => n + Buffer.byteLength(JSON.stringify(row)) + 1, 0));
  }
  assert.ok(s.nativeHost.length <= 64);
  assert.ok(s.nativeHost.reduce((n, line) => n + Buffer.byteLength(line) + 1, 0) <= 16 * 1024);
  assert.equal(s.firstServerError.code, 'gateway/internal');
  assert.equal(s.engineLog.limitReached, true);
  assert.ok(Buffer.byteLength(f.log.join('')) <= 256 * 1024);
  assert.equal(s.engineLog.bytes, Buffer.byteLength(f.log.join('')));
  assert.equal(f.log.filter(line => line.includes('diagnostic-log-limit')).length, 1);
  f.diagnostic.hostRecord({ kind: 'error', errorCode: 'ERR_IOS_HOST_START', message: marker });
  assert.equal(f.diagnostic.snapshot().engine.firstHostError.code, 'ERR_IOS_HOST_START', 'critical fields survive a full disk log');
  noMarker(f.diagnostic, f.log);
  const dense = fixture('rootreadonly'); dense.round.setPhase('session_snapshot');
  for (let i = 0; i < 100; i++) dense.round.serverError('rpc-http',
    { name: 'GuestDiagnosticError', code: 'gateway/service-unavailable' }, 'session/prompt', 599);
  const tail = dense.diagnostic.snapshot().nativeHost;
  const bytes = tail.reduce((sum, line) => sum + Buffer.byteLength(line) + 1, 0);
  assert.ok(tail.length < 64, 'the byte bound must evict before the line bound for larger records');
  assert.ok(bytes <= 16 * 1024 && bytes + Buffer.byteLength(tail.at(-1)) + 1 > 16 * 1024);
});

test('guest diagnostics all output surfaces omit arbitrary frames messages IDs and credentials', () => {
  const f = fixture(marker); f.round.setPhase(marker);
  f.diagnostic.hostRecord({ kind: 'ready', baseUrl: marker, token: marker });
  f.diagnostic.hostRecord({ kind: 'log', stream: 'stdout', line: marker });
  f.diagnostic.hostRecord({ kind: marker, message: marker });
  f.send({ type: 'item', streamId: marker, value: { type: 'event', event: { type: marker, data: { command: marker, content: marker } } } });
  f.send({ type: 'error', streamId: marker, error: { name: marker, code: marker, message: marker, details: marker } });
  f.round.serverError(marker, { name: marker, code: marker, message: marker }, marker, marker);
  f.socket.emit('message', Buffer.from('{"payload":"' + marker));
  f.socket.emit('close', 1006, Buffer.from(marker));
  f.diagnostic.hostRecord({ kind: 'fatal', errorCode: marker, message: marker });
  f.diagnostic.childError(Object.assign(new Error(marker), { code: marker }));
  f.diagnostic.childExit(marker, marker);
  f.diagnostic.childStderr(Buffer.from('Cookie: ' + marker + '\nAuthorization: Bearer ' + marker + '\n-----BEGIN PRIVATE KEY-----\n' + marker));
  f.diagnostic.childStderrEnd();
  assert.equal(f.diagnostic.snapshot().hostNonStderrLinesWithheld, 1);
  assert.deepEqual(safeError({ name: marker, code: marker, message: marker, stack: marker }), { name: 'withheld', code: 'withheld', textWithheld: true });
  assert.equal(safeScenario(marker), 'withheld'); assert.equal(safeTool(marker), 'withheld');
  noMarker(f.diagnostic, f.log, [marker, 'Cookie:', 'Authorization:', 'BEGIN PRIVATE KEY']);
});

test('guest diagnostics classifies proven stderr templates without preserving suffix text', () => {
  const f = fixture();
  for (const line of ['[api-gateway] Remote stream connection failed: ',
    '[api-gateway] Remote stream scope cleanup failed: ', '[api-gateway] Remote stream upgrade failed: ',
    'fatal signal 11 at ', 'fatal signal 65 at ', 'Error: '])
    f.diagnostic.hostRecord({ kind: 'log', stream: 'stderr', line: line + marker });
  assert.deepEqual(f.diagnostic.snapshot().stderr.host.entries.map(row => row.category),
    ['gateway-connection-failed','gateway-cleanup-failed','gateway-upgrade-failed','native-fatal-signal','unclassified-stderr','stderr-error']);
  assert.equal(f.diagnostic.snapshot().stderr.host.entries[3].signalNumber, 11);
  noMarker(f.diagnostic, f.log);
});

test('guest diagnostics contains log-write failures without exposing exception text', () => {
  let writes = 0;
  const d = createGuestDiagnostics({ writeLog() { writes++; throw new Error(marker); } });
  d.hostRecord({ kind: 'ready' });
  d.hostRecord({ kind: 'error', errorCode: 'ERR_IOS_HOST_START', message: marker });
  const s = d.snapshot();
  assert.equal(writes, 1); assert.equal(s.engineLog.writeFailed, true);
  assert.equal(s.engineLog.bytes, 0); assert.equal(s.firstFailure.failure, 'engine-event');
  assert.equal(s.engine.firstHostError.code, 'ERR_IOS_HOST_START');
  noMarker(d, []);
});

test('guest diagnostics bounds round metadata and preserves cleanup ordering', () => {
  const d = createGuestDiagnostics();
  for (let i = 0; i < 16; i++) d.startRound('deny').beginCleanup();
  assert.throws(() => d.startRound(marker), { name: 'GuestDiagnosticError', message: 'round-limit' });
  d.markCleanup('quit'); d.markCleanup('quit'); d.markCleanup('kill');
  const s = d.snapshot();
  assert.equal(s.rounds.length, 16); assert.ok(s.cleanup.quit < s.cleanup.kill);
  assert.equal(s.firstFailure, null);
});


test('guest diagnostics keeps upstream log-loss counters without raw host text', () => {
  const f = fixture();
  f.diagnostic.hostRecord({ kind: 'log', stream: 'system', line: '[OHOS host: 19 old log lines dropped]' });
  f.diagnostic.hostRecord({ kind: 'log', stream: 'system', line: '[OHOS host: ' + marker + ' old log lines dropped]' });
  for (const line of ['[OHOS host: oversized log line discarded]', '[OHOS host: oversized redacted log line discarded]'])
    f.diagnostic.hostRecord({ kind: 'log', stream: 'stderr', line });
  const s = f.diagnostic.snapshot();
  assert.equal(s.engine.hostDroppedLines, 19);
  assert.equal(s.hostNonStderrLinesWithheld, 1);
  assert.deepEqual(s.stderr.host.entries.map(row => row.category), ['upstream-line-discarded','upstream-line-discarded']);
  noMarker(f.diagnostic, f.log);
});


test('guest diagnostics does not mislabel a cleanup-only failure as a pre-cleanup snapshot', () => {
  const d = createGuestDiagnostics(); d.startRound('deny').beginCleanup();
  d.markCleanup('quit'); d.failure('cleanup-error', new Error(marker));
  d.markCleanup('kill'); d.freezeBeforeCleanup();
  const s = d.snapshot();
  assert.equal(s.firstFailure.failure, 'cleanup-error');
  assert.ok(s.cleanup.quit < s.firstFailure.seq);
  assert.equal(s.beforeCleanup, null);
  noMarker(d, []);
});
