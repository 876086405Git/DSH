// Only fixed categories, allowlisted codes and bounded numbers cross this boundary.
// Never forward Error.message/stack, protocol payloads, command text or credentials.
import { StringDecoder } from 'node:string_decoder';

export const diagnosticLimits = Object.freeze({
  stderrLineBytes: 4096, stderrLines: 64, stderrBytes: 32 * 1024,
  hostTailLines: 64, hostTailBytes: 16 * 1024, logBytes: 256 * 1024,
  // A host drain can contain 512 escaped 16 KiB log lines. This is a transport
  // decoding bound, not a permission to retain or report those raw lines.
  hostJsonLineBytes: 64 * 1024 * 1024, rounds: 16,
});
const scenarios = new Set(['deny','identity','osrelease','apkpath','pipeline','full',
  'rootreadonly','rootdeny','rootallow','rootafter','exit','cancel','after']);
const phases = new Set(['startup','login','opening_mux','host_ready','session_create',
  'session_snapshot','prompt','prompt_accepted','waiting_approval','approval_result',
  'root_approval','cancel_wait','cancel_request','waiting_turn_end','verify_result','audit','complete']);
const failureKinds = new Set(['setup-error','round-error','assertion-failed','mux-error',
  'mux-transport','mux-close','mux-invalid-frame','mux-timeout','round-closed',
  'rpc-http','rpc-envelope','rpc-error','launch-http','launch-cookie','http-timeout',
  'engine-error','engine-exit','engine-event','readiness-timeout','guest-readiness-timeout',
  'cleanup-error','round-limit']);
const codes = new Set(['gateway/internal','gateway/service-unavailable','gateway/arguments-invalid',
  'session/not-found','session/agent-busy',
  'STREAM_CLOSED','MALFORMED_RESPONSE','NO_ADAPTER','INVALID_CONFIG','UNKNOWN_MODEL','UNKNOWN',
  'ERR_ASSERTION','ERR_INVALID_ARG_TYPE','ABORT_ERR','EACCES','ENOENT','EIO','ENOSPC',
  'ECONNRESET','ECONNREFUSED','EPIPE','ETIMEDOUT','ECANCELED',
  'ERR_IOS_HOST_ALREADY_STARTED','ERR_IOS_HOST_START','ERR_OHOS_HOST_START']);
const names = new Set(['Error','TypeError','SyntaxError','AssertionError','AbortError','TimeoutError','GuestDiagnosticError']);
const signals = new Set(['SIGTERM','SIGKILL','SIGABRT','SIGSEGV','SIGILL','SIGTRAP','SIGBUS','SIGFPE','SIGHUP','SIGINT','SIGQUIT']);
const endpoints = new Set(['launch','session/create','session/prompt','session/cancel','$events/result']);
const eventTypes = new Set(['turn/start','turn/end','tool/call','tool/result','approval/asked','approval/decided']);
const closeReasons = new Map([
  ['peer left','peer-left'], ['text messages required','text-required'],
  ['invalid Remote stream request','invalid-request'],
  ['Remote stream failure could not be delivered','failure-undeliverable'],
]);
const pick = (set, value) => set.has(value) ? value : 'withheld';
const integer = (value, min = 0, max = Number.MAX_SAFE_INTEGER) =>
  Number.isSafeInteger(value) && value >= min && value <= max ? value : null;
const clone = value => structuredClone(value);
export const safeScenario = value => pick(scenarios, value);
export const safeTool = value => value === 'bash' || value === null ? value : 'withheld';
export function safeError(error) {
  return { name: pick(names, error?.name), code: pick(codes, error?.code), textWithheld: true };
}
export function diagnosticError(kind) {
  const error = new Error(pick(failureKinds, kind));
  error.name = 'GuestDiagnosticError';
  error.diagnosticKind = pick(failureKinds, kind);
  return error;
}

// Bound bytes before decoding; an oversized line is discarded in its entirety.
// A partial line is private until newline/EOF. Snapshots expose only its size.
export class BoundedLineDecoder {
  #decoder = new StringDecoder('utf8');
  #text = ''; #bytes = 0; #oversized = false; #ended = false;
  constructor(limit, line, discarded) {
    if (!Number.isSafeInteger(limit) || limit < 1) throw diagnosticError('setup-error');
    this.limit = limit; this.line = line; this.discarded = discarded;
  }
  write(chunk) {
    if (this.#ended) return;
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    let start = 0;
    while (start < bytes.length) {
      const newline = bytes.indexOf(10, start);
      const end = newline === -1 ? bytes.length : newline;
      this.#bytes += end - start;
      if (this.#bytes > this.limit) {
        this.#oversized = true; this.#text = ''; this.#decoder = new StringDecoder('utf8');
      } else if (!this.#oversized) this.#text += this.#decoder.write(bytes.subarray(start, end));
      if (newline === -1) break;
      this.#flush(); start = newline + 1;
    }
  }
  #flush() {
    if (this.#oversized) this.discarded(this.#bytes);
    else this.line((this.#text + this.#decoder.end()).replace(/\r$/u, ''), this.#bytes);
    this.#text = ''; this.#bytes = 0; this.#oversized = false; this.#decoder = new StringDecoder('utf8');
  }
  end() {
    if (this.#ended) return;
    if (this.#bytes !== 0) this.#flush();
    this.#ended = true;
  }
  snapshot() {
    return { ended: this.#ended, pendingBytes: this.#bytes, pendingOversized: this.#oversized,
      pendingTextWithheld: this.#bytes !== 0 };
  }
}

function boundedRecords(maxLines, maxBytes) {
  const entries = []; let bytes = 0, dropped = 0;
  return {
    push(record) {
      const size = Buffer.byteLength(JSON.stringify(record)) + 1;
      if (size > maxBytes) { dropped++; return; }
      entries.push({ record, size }); bytes += size;
      while (entries.length > maxLines || bytes > maxBytes) {
        bytes -= entries.shift().size; dropped++;
      }
    },
    snapshot: () => ({ entries: entries.map(item => item.record), bytes, dropped, maxLines, maxBytes }),
  };
}

function stderrClass(line) {
  if (line === '[OHOS host: oversized log line discarded]' ||
      line === '[OHOS host: oversized redacted log line discarded]')
    return { category: 'upstream-line-discarded', textWithheld: true };
  for (const [prefix, category] of [
    ['[api-gateway] Remote stream connection failed:', 'gateway-connection-failed'],
    ['[api-gateway] Remote stream scope cleanup failed:', 'gateway-cleanup-failed'],
    ['[api-gateway] Remote stream upgrade failed:', 'gateway-upgrade-failed'],
  ]) if (line.startsWith(prefix)) return { category, textWithheld: true };
  const fatal = /^fatal signal ([0-9]{1,2}) at /u.exec(line);
  if (fatal && Number(fatal[1]) > 0 && Number(fatal[1]) <= 64)
    return { category: 'native-fatal-signal', signalNumber: Number(fatal[1]), textWithheld: true };
  const error = /^(Error|TypeError|SyntaxError|AssertionError|AbortError|TimeoutError):/u.exec(line);
  if (error) return { category: 'stderr-error', name: error[1], textWithheld: true };
  return { category: 'unclassified-stderr', textWithheld: true };
}

export function createGuestDiagnostics({ writeLog = () => {} } = {}) {
  let sequence = 0, active = null, firstFailure = null, firstServerError = null, lastServerError = null;
  let beforeCleanup = null, logBytes = 0, logFull = false, logWriteFailed = false;
  let hostNonStderrLinesWithheld = 0, hostInvalidRecords = 0;
  const rounds = [], observedEvents = new Set();
  const cleanup = { quit: null, kill: null, stdioClosed: false };
  const engine = { hostDroppedLines: 0, firstHostError: null, lastHostError: null, hostExit: null, childExit: null, childError: null };
  const tail = boundedRecords(diagnosticLimits.hostTailLines, diagnosticLimits.hostTailBytes);
  const stderr = Object.fromEntries(['child','host'].map(source => [source, {
    ring: boundedRecords(diagnosticLimits.stderrLines, diagnosticLimits.stderrBytes),
    lines: 0, oversized: 0, eof: false,
  }]));
  const logLimitLine = '{"kind":"diagnostic-log-limit","textWithheld":true}\n';
  function write(line) {
    if (logWriteFailed || logFull) return;
    if (logBytes + Buffer.byteLength(line) + Buffer.byteLength(logLimitLine) > diagnosticLimits.logBytes) {
      line = logLimitLine; logFull = true;
    }
    try { writeLog(line); logBytes += Buffer.byteLength(line); }
    catch { logWriteFailed = true; }
  }
  function emit(kind, fields = {}, context = active) {
    const record = Object.freeze({ seq: ++sequence, scenario: context?.scenario ?? 'startup',
      phase: context?.phase ?? 'startup', kind, ...fields });
    tail.push(record); write(JSON.stringify(record) + '\n'); return record;
  }
  function failure(kind, error, context = active) {
    const failureKind = error?.code === 'ERR_ASSERTION' ? 'assertion-failed'
      : failureKinds.has(error?.diagnosticKind) ? error.diagnosticKind : pick(failureKinds, kind);
    const record = emit('failure', { failure: failureKind, ...safeError(error) }, context);
    firstFailure ??= record; return record;
  }
  function stderrLine(source, line, bytes, oversized = false) {
    if (!bytes && !line) return;
    const store = stderr[source]; store.lines++;
    if (oversized) store.oversized++;
    const record = emit('stderr', { source, inputBytes: bytes,
      ...(oversized ? { category: 'oversized-stderr', textWithheld: true } : stderrClass(line)) });
    store.ring.push(record);
  }
  const childLines = new BoundedLineDecoder(diagnosticLimits.stderrLineBytes,
    (line, bytes) => stderrLine('child', line, bytes), bytes => stderrLine('child', '', bytes, true));
  function stderrSnapshot() {
    return Object.fromEntries(Object.entries(stderr).map(([source, store]) => [source, {
      ...store.ring.snapshot(), inputLines: store.lines, oversizedLines: store.oversized,
      eof: store.eof, maxInputLineBytes: diagnosticLimits.stderrLineBytes,
      ...(source === 'child' ? childLines.snapshot() : {}),
    }]));
  }
  function freezeBeforeCleanup() {
    if (cleanup.quit !== null || cleanup.kill !== null) return;
    if (firstFailure && beforeCleanup === null) beforeCleanup = clone({ seq: sequence,
      firstFailure, firstServerError, lastServerError, engine, stderr: stderrSnapshot() });
  }
  function startRound(mode) {
    if (rounds.length >= diagnosticLimits.rounds) throw diagnosticError('round-limit');
    const state = { scenario: safeScenario(mode), phase: 'login', firstFailure: null,
      firstServerError: null, lastServerError: null, close: null, localTerminateRequested: null };
    let error = null;
    active = state; rounds.push(state);
    function fail(kind, cause) {
      if (state.localTerminateRequested !== null) return error;
      if (error === null) {
        state.firstFailure = failure(kind, cause, state);
        error = diagnosticError(state.firstFailure.failure);
      }
      return error;
    }
    function serverError(source, cause, location, status) {
      const record = emit('server-error', {
        source: pick(new Set(['mux','rpc','rpc-http','turn-end','api-session']), source),
        location: endpoints.has(location) ? location
          : location === 'host' || location === 'session' || location === 'audit' ? location : 'withheld',
        ...safeError(cause), httpStatus: integer(status, 100, 599),
        afterLocalTerminate: state.localTerminateRequested !== null,
      }, state);
      state.firstServerError ??= record; state.lastServerError = record;
      firstServerError ??= record; lastServerError = record; return record;
    }
    return Object.freeze({
      get error() { return error; },
      setPhase(phase) { state.phase = pick(phases, phase); },
      fail,
      serverError,
      transportError(cause) {
        emit('mux-transport-error', { ...safeError(cause),
          afterLocalTerminate: state.localTerminateRequested !== null }, state);
        return fail('mux-transport', cause);
      },
      close(code, reason) {
        const bytes = Buffer.isBuffer(reason) ? reason : typeof reason === 'string' ? Buffer.from(reason) : null;
        // No arbitrary reason text is retained, even when it resembles a token/code.
        const category = bytes?.length === 0 ? 'empty' : bytes && bytes.length <= 80
          ? closeReasons.get(bytes.toString('utf8')) ?? 'withheld' : 'withheld';
        const record = emit('mux-close', { code: integer(code, 0, 65535), reason: category,
          reasonBytes: bytes?.length ?? null, textWithheld: category === 'withheld',
          afterLocalTerminate: state.localTerminateRequested !== null }, state);
        state.close ??= record; return fail('mux-close');
      },
      frame(frame) {
        if (!frame || typeof frame !== 'object') return fail('mux-invalid-frame');
        const location = frame.streamId === 'host' || frame.streamId === 'session' ? frame.streamId
          : typeof frame.streamId === 'string' && frame.streamId === 'audit-' + state.scenario ? 'audit' : 'withheld';
        if (frame.type === 'error') {
          serverError('mux', frame.error, location); return fail('mux-error', frame.error);
        }
        if (frame.type === 'end') emit('stream-end', { location }, state);
        const value = frame.value;
        if (value?.type === 'event') {
          const event = value.event;
          observedEvents.add(pick(eventTypes, event?.type));
          if (event?.type === 'turn/end' && event.data?.reason?.kind === 'error')
            serverError('turn-end', event.data.reason.error, location);
        }
        if (value?.type === 'emit' && value.event === 'api-session/error')
          serverError('api-session', undefined, location);
        return null;
      },
      beginCleanup() {
        freezeBeforeCleanup();
        state.localTerminateRequested ??= emit('local-terminate-requested', {}, state).seq;
      },
    });
  }
  return Object.freeze({
    startRound,
    failure(kind, error) { return failure(kind, error); },
    freezeBeforeCleanup,
    childStderr(chunk) { childLines.write(chunk); },
    childStderrEnd() { childLines.end(); stderr.child.eof = true; },
    hostStdoutEnd() { stderr.host.eof = true; },
    hostInvalid(oversized = false) {
      hostInvalidRecords++; emit('host-record-withheld', { oversized: oversized === true, textWithheld: true });
    },
    hostRecord(row, expectedExit = false) {
      if (!row || typeof row !== 'object') { hostInvalidRecords++; return; }
      if (row.kind === 'log') {
        if (row.stream === 'stderr' && typeof row.line === 'string') {
          const bytes = Buffer.byteLength(row.line);
          stderrLine('host', bytes > diagnosticLimits.stderrLineBytes ? '' : row.line,
            bytes, bytes > diagnosticLimits.stderrLineBytes);
        } else {
          const dropped = row.stream === 'system' && typeof row.line === 'string'
            ? /^\[OHOS host: ([0-9]{1,10}) old log lines dropped\]$/u.exec(row.line) : null;
          if (dropped) {
            const count = Number(dropped[1]); engine.hostDroppedLines += count;
            emit('host-lines-dropped', { count });
          } else hostNonStderrLinesWithheld++;
        }
      } else if (row.kind === 'ready') emit('engine-ready');
      else if (row.kind === 'exit') {
        engine.hostExit = emit('host-exit', { exitCode: integer(row.exitCode, -255, 255),
          afterQuit: cleanup.quit !== null, expectedExit: expectedExit === true });
      } else if (row.kind === 'error' || row.kind === 'fatal') {
        const record = emit('host-error', { category: row.kind, code: pick(codes, row.errorCode), textWithheld: true });
        engine.firstHostError ??= record; engine.lastHostError = record;
        if (cleanup.quit === null) failure('engine-event', { code: row.errorCode });
      } else hostInvalidRecords++;
    },
    childError(error) {
      engine.childError = emit('child-error', safeError(error));
      if (cleanup.quit === null) failure('engine-error', error);
    },
    childExit(code, signal) {
      engine.childExit = emit('child-exit', { exitCode: integer(code, -255, 255),
        signal: signal === null ? null : pick(signals, signal), afterQuit: cleanup.quit !== null });
    },
    markCleanup(action) {
      if (action !== 'quit' && action !== 'kill') return;
      freezeBeforeCleanup();
      cleanup[action] ??= emit(action === 'quit' ? 'local-quit-requested' : 'local-kill-requested').seq;
    },
    stdioClosed() { cleanup.stdioClosed = true; },
    snapshot() {
      return clone({ schema: 1, firstFailure, firstServerError, lastServerError, beforeCleanup,
        rounds, engine, cleanup, stderr: stderrSnapshot(), eventTypes: [...observedEvents],
        nativeHost: tail.snapshot().entries.map(record => JSON.stringify(record)),
        engineLog: { bytes: logBytes, maxBytes: diagnosticLimits.logBytes, limitReached: logFull,
          writeFailed: logWriteFailed, tailDropped: tail.snapshot().dropped },
        hostNonStderrLinesWithheld, hostInvalidRecords });
    },
  });
}

// This same binding is exercised with an EventEmitter in the offline tests.
// It owns neither a connection nor cleanup; callers mark intentional termination.
export function observeMux(socket, round, { onFrame, onFailure }) {
  const reject = error => { if (error) onFailure(error); };
  socket.on('error', error => reject(round.transportError(error)));
  socket.on('close', (code, reason) => reject(round.close(code, reason)));
  socket.on('message', bytes => {
    try {
      const frame = JSON.parse(String(bytes));
      const error = round.frame(frame);
      if (error) reject(error);
      else onFrame(frame);
    } catch (error) { reject(round.fail('mux-invalid-frame', error)); }
  });
}
