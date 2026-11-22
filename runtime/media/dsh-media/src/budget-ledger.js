// Host-private M1 foundation. Not wired to any tool or setting in M0.
// All callers are trusted host code. This module coordinates budget/intent;
// it does not grant permission to send a request or publish a workspace file.
import { constants } from 'node:fs';
import { mkdir, lstat, realpath, open, rename, unlink } from 'node:fs/promises';
import { isAbsolute, join, dirname } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { withFileLock } from '@deepseek-ai/dsh-atomic-write';

const MAX_BYTES = 8 * 1024 * 1024;
const DEFAULT_LIMIT = 20_000_000;
const STATES = new Set(['reserved', 'submission_unknown', 'submitted', 'settled', 'released']);
const RID = /^m_[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const HASH = /^[a-f0-9]{64}$/;
const INSTANCE = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const dayFormat = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
});

export class BudgetError extends Error {
  constructor(code) { super(`media budget: ${code}`); this.name = 'BudgetError'; this.code = code; }
}
function fail(code) { throw new BudgetError(code); }
function amount(value, positive = false) {
  if (!Number.isSafeInteger(value) || value < (positive ? 1 : 0)) fail('invalid_amount');
  return value;
}
function exactKeys(value, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || Object.keys(value).some(key => !keys.includes(key))) fail('invalid_record');
}
function text(value, max = 256) {
  if (typeof value !== 'string' || !value || Buffer.byteLength(value) > max
    || /[\u0000-\u001f]/.test(value)) fail('invalid_record');
  return value;
}
function validDay(value) {
  if (typeof value !== 'string' || !DAY.test(value)) return false;
  const date = new Date(value + 'T00:00:00Z');
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}
function requestIdentity(request, estimateMicros) {
  return createHash('sha256').update(JSON.stringify({ request, estimateMicros })).digest('hex');
}

/** Decimal CNY to integer micro-CNY, rounding any fractional micro upward. */
export function cnyMicros(decimal) {
  if (typeof decimal !== 'string' || !/^(0|[1-9]\d*)(\.\d+)?$/.test(decimal)
    || decimal.length > 64) fail('invalid_amount');
  const [whole, fraction = ''] = decimal.split('.');
  const tail = fraction.slice(6);
  const value = BigInt(whole) * 1_000_000n
    + BigInt((fraction.slice(0, 6) + '000000').slice(0, 6))
    + (/[1-9]/.test(tail) ? 1n : 0n);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) fail('invalid_amount');
  return Number(value);
}

function normalizeRequest(input) {
  const fields = ['sessionId', 'serviceId', 'modelId', 'profile', 'region',
    'baseUrl', 'keyRef', 'cwd', 'workspaceRoot', 'paramsHash'];
  exactKeys(input, fields);
  const request = Object.fromEntries(fields.map(key => [key, text(input[key],
    ['baseUrl', 'cwd', 'workspaceRoot'].includes(key) ? 2048 : 256)]));
  if (!HASH.test(request.paramsHash) || !isAbsolute(request.cwd)
    || !isAbsolute(request.workspaceRoot)
    || !/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(request.keyRef)) fail('invalid_record');
  let endpoint;
  try { endpoint = new URL(request.baseUrl); } catch { fail('invalid_record'); }
  if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password
    || endpoint.search || endpoint.hash) fail('invalid_record');
  // Normalized descriptor order gives repeat calls the same identity.
  return request;
}

function validateState(value) {
  exactKeys(value, ['v', 'instanceId', 'revision', 'currency', 'timeZone', 'dailyLimitMicros', 'requests']);
  if (value.v !== 1 || !INSTANCE.test(value.instanceId ?? '') || value.currency !== 'CNY'
    || value.timeZone !== 'Asia/Shanghai' || !Array.isArray(value.requests)) fail('corrupt');
  amount(value.revision); amount(value.dailyLimitMicros);
  const ids = new Set();
  for (const record of value.requests) {
    exactKeys(record, ['rid', 'identity', 'day', 'estimateMicros', 'request', 'state',
      'providerTaskId', 'chargeMicros', 'basis', 'payload', 'outputDate']);
    if (!RID.test(record.rid ?? '') || ids.has(record.rid) || !HASH.test(record.identity ?? '')
      || !validDay(record.day) || !STATES.has(record.state)) fail('corrupt');
    ids.add(record.rid); amount(record.estimateMicros, true);
    if (record.outputDate !== undefined && !validDay(record.outputDate)) fail('corrupt');
    const normalized = normalizeRequest(record.request);
    if (record.payload !== undefined) {
      const payload = JSON.stringify(record.payload);
      if (Buffer.byteLength(payload) > 32768
        || createHash('sha256').update(payload).digest('hex') !== normalized.paramsHash) fail('corrupt');
    }
    if (requestIdentity(normalized, record.estimateMicros) !== record.identity) fail('corrupt');
    if (record.providerTaskId !== undefined
      && !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/.test(record.providerTaskId)) fail('corrupt');
    if (record.state === 'submitted' && !record.providerTaskId) fail('corrupt');
    if (['reserved', 'released'].includes(record.state) && record.providerTaskId !== undefined) fail('corrupt');
    if (record.state === 'settled') {
      amount(record.chargeMicros);
      if (!['estimate', 'provider-usage'].includes(record.basis)) fail('corrupt');
    } else if (record.chargeMicros !== undefined || record.basis !== undefined) fail('corrupt');
  }
  return value;
}

function dayAt(milliseconds) {
  if (!Number.isFinite(milliseconds)) fail('invalid_clock');
  const parts = Object.fromEntries(dayFormat.formatToParts(new Date(milliseconds))
    .map(part => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
function usedFor(state, day) {
  let used = 0n;
  for (const record of state.requests) {
    if (record.day !== day || record.state === 'released') continue;
    used += BigInt(record.state === 'settled' ? record.chargeMicros : record.estimateMicros);
  }
  return used;
}

/**
 * Same-host/PID-namespace coordination using rc4's public writer lock.
 * trustedDirectory must be a canonical private path selected by host code.
 * clock/checkpoint are in-process test seams, never config/tool arguments.
 */
export function createBudgetLedger(trustedDirectory, { clock = Date.now, checkpoint = async () => {} } = {}) {
  if (typeof trustedDirectory !== 'string' || !isAbsolute(trustedDirectory)) fail('invalid_directory');
  const filename = join(trustedDirectory, 'ledger-v1.json');
  const marker = join(trustedDirectory, 'initialized-v1.json');
  let directoryIdentity;

  async function guardDirectory() {
    const info = await lstat(trustedDirectory, { bigint: true });
    if (!info.isDirectory() || info.isSymbolicLink() || await realpath(trustedDirectory) !== trustedDirectory
      || (process.platform !== 'win32' && (info.mode & 0o077n) !== 0n)) fail('unsafe_directory');
    if (directoryIdentity && (info.ino !== directoryIdentity.ino || info.dev !== directoryIdentity.dev)) {
      fail('directory_changed');
    }
    directoryIdentity ??= info;
  }
  async function syncDirectory(path) {
    let handle;
    try {
      handle = await open(path, constants.O_RDONLY | (constants.O_DIRECTORY ?? 0));
      await handle.sync();
    } catch { fail('durability_unavailable'); }
    finally { await handle?.close(); }
  }
  async function readJson(path, absent = false) {
    let handle;
    try {
      handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
      const info = await handle.stat();
      if (!info.isFile() || info.size > MAX_BYTES
        || (process.platform !== 'win32' && (info.mode & 0o077) !== 0)) fail('corrupt');
      return JSON.parse(await handle.readFile('utf8'));
    } catch (error) {
      if (absent && error?.code === 'ENOENT') return undefined;
      if (error instanceof BudgetError) throw error;
      fail('corrupt');
    } finally { await handle?.close(); }
  }
  async function durableReplace(path, value, label) {
    await guardDirectory();
    const bytes = Buffer.from(JSON.stringify(value) + '\n');
    if (bytes.length > MAX_BYTES) fail('capacity');
    const temporary = join(trustedDirectory, `.${randomUUID()}.tmp`);
    let handle;
    let renamed = false;
    try {
      handle = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL
        | (constants.O_NOFOLLOW ?? 0), 0o600);
      await handle.writeFile(bytes);
      await handle.sync();
      await handle.close(); handle = undefined;
      await checkpoint(`${label}:file-synced`);
      await guardDirectory();
      await rename(temporary, path); renamed = true;
      await checkpoint(`${label}:renamed`);
      await syncDirectory(trustedDirectory);
      await guardDirectory();
      await checkpoint(`${label}:durable`);
    } catch (error) {
      if (error instanceof BudgetError) throw error;
      fail(renamed ? 'commit_uncertain' : 'storage');
    } finally {
      await handle?.close();
      if (!renamed) await unlink(temporary).catch(() => {});
    }
  }
  async function prepare() {
    await mkdir(trustedDirectory, { recursive: true, mode: 0o700 });
    await guardDirectory();
    // Repair ancestors even when a previous creator died after mkdir. The
    // Direct runtime synced its installed rootfs before startup; otherwise
    // only the filesystem root is an established durability boundary.
    const directRoot = globalThis[Symbol.for('dsh.go.direct')]?.root;
    for (let path = trustedDirectory; ; path = dirname(path)) {
      await syncDirectory(path);
      if (path === directRoot || dirname(path) === path) break;
    }
    await guardDirectory();
  }
  async function transaction(change, { signal } = {}) {
    try {
      await prepare();
      return await withFileLock(filename, async () => {
        signal?.throwIfAborted();
        await guardDirectory();
        let state = await readJson(filename, true);
        const initialized = await readJson(marker, true);
        if (initialized !== undefined) {
          exactKeys(initialized, ['v', 'instanceId']);
          if (initialized.v !== 1 || !INSTANCE.test(initialized.instanceId ?? '')
            || state === undefined || state.instanceId !== initialized.instanceId) fail('corrupt');
        }
        if (state === undefined) {
          state = { v: 1, instanceId: randomUUID(), revision: 0, currency: 'CNY',
            timeZone: 'Asia/Shanghai', dailyLimitMicros: DEFAULT_LIMIT, requests: [] };
          await durableReplace(filename, state, 'initialize-ledger');
        }
        validateState(state);
        if (initialized === undefined) {
          await durableReplace(marker, { v: 1, instanceId: state.instanceId }, 'initialize-marker');
        }
        signal?.throwIfAborted();
        const outcome = change(state);
        if (outcome.changed) {
          if (state.revision === Number.MAX_SAFE_INTEGER) fail('capacity');
          state.revision++;
          validateState(state);
          await durableReplace(filename, state, outcome.label);
        }
        return outcome.result(state); // state was parsed for this transaction alone
      }, { signal });
    } catch (error) {
      if (error instanceof BudgetError) throw error;
      if (signal?.aborted) fail('cancelled');
      fail('storage');
    }
  }
  function find(state, rid, identity) {
    const record = state.requests.find(item => item.rid === rid);
    if (!record || record.identity !== identity) fail('identity_mismatch');
    return record;
  }
  function result(changed, label, value) { return { changed, label, result: () => value }; }

  return {
    async snapshot(options) {
      return transaction(state => result(false, 'read', state), options);
    },
    async releaseReserved(options) {
      return transaction(state => {
        let released = 0;
        for (const record of state.requests) {
          if (record.state !== 'reserved') continue;
          record.state = 'released';
          released++;
        }
        return result(released > 0, 'release-reserved', released);
      }, options);
    },
    async setDailyLimit(limitMicros, expectedRevision, options) {
      amount(limitMicros); amount(expectedRevision);
      return transaction(state => {
        if (state.revision !== expectedRevision) fail('conflict');
        const changed = state.dailyLimitMicros !== limitMicros;
        state.dailyLimitMicros = limitMicros;
        return { changed, label: 'policy', result: value => value };
      }, options);
    },
    async reserve({ rid, request, estimateMicros, payload }, options) {
      if (!RID.test(rid ?? '')) fail('invalid_record');
      amount(estimateMicros, true);
      const normalized = normalizeRequest(request);
      const identity = requestIdentity(normalized, estimateMicros);
      return transaction(state => {
        const existing = state.requests.find(item => item.rid === rid);
        if (existing) {
          if (existing.identity !== identity) fail('identity_mismatch');
          return result(false, 'reserve', { created: false, record: existing });
        }
        const day = dayAt(clock());
        if (usedFor(state, day) + BigInt(estimateMicros) > BigInt(state.dailyLimitMicros)) fail('budget_exceeded');
        const record = { rid, identity, day, estimateMicros, request: normalized, state: 'reserved', ...(payload === undefined ? {} : { payload, outputDate: new Date(clock()).toISOString().slice(0, 10) }) };
        state.requests.push(record);
        return result(true, 'reserve', { created: true, record });
      }, options);
    },
    async beginSubmission(rid, identity, options) {
      return transaction(state => {
        const record = find(state, rid, identity);
        if (record.state !== 'reserved') return result(false, 'intent', { started: false, record });
        // Sample the Shanghai admission day inside the writer transaction,
        // after any lock wait. An old unsent hold is never today's admission.
        // Keep it reserved: only the caller may explicitly release/requote it.
        // This is a local gate timestamp, not the future provider billing day.
        if (record.day !== dayAt(clock())) fail('reservation_day_mismatch');
        record.state = 'submission_unknown';
        return result(true, 'intent', { started: true, record });
      }, options);
    },
    async markSubmitted(rid, identity, providerTaskId, options) {
      if (typeof providerTaskId !== 'string'
        || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/.test(providerTaskId)) fail('invalid_record');
      return transaction(state => {
        const record = find(state, rid, identity);
        if (record.providerTaskId === providerTaskId) return result(false, 'submitted', record);
        if (record.state !== 'submission_unknown' || record.providerTaskId !== undefined) fail('invalid_transition');
        record.providerTaskId = providerTaskId; record.state = 'submitted';
        return result(true, 'submitted', record);
      }, options);
    },
    async releaseUnsent(rid, identity, options) {
      return transaction(state => {
        const record = find(state, rid, identity);
        if (record.state === 'released') return result(false, 'release', record);
        if (record.state !== 'reserved') fail('submission_may_have_happened');
        record.state = 'released';
        return result(true, 'release', record);
      }, options);
    },
    async settle(rid, identity, { chargeMicros, basis }, options) {
      amount(chargeMicros);
      if (!['estimate', 'provider-usage'].includes(basis)) fail('invalid_record');
      return transaction(state => {
        const record = find(state, rid, identity);
        if (record.state === 'settled') {
          if (record.chargeMicros !== chargeMicros || record.basis !== basis) fail('settlement_conflict');
          return result(false, 'settle', record);
        }
        if (!['submission_unknown', 'submitted'].includes(record.state)) fail('invalid_transition');
        if (basis === 'estimate' && chargeMicros !== record.estimateMicros) fail('invalid_amount');
        record.chargeMicros = chargeMicros; record.basis = basis; record.state = 'settled';
        return result(true, 'settle', record);
      }, options);
    },
  };
}
