import { constants } from 'node:fs';
import * as nodeFs from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { isMainThread } from 'node:worker_threads';
import { dirname, isAbsolute, join, resolve } from 'node:path';

const kinds = new Set(['header', 'untracked', 'prepared', 'dispatch', 'returned', 'outcome', 'committed', 'reconciled', 'pause', 'resume', 'cancel']);
const maximumRecordBytes = 1024 * 1024;
const maximumResultBytes = 16 * 1024 * 1024;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = (code, message, cause) => Object.assign(new Error(message, { cause }), { code });
const corrupt = (message, cause) => fail('ERR_OHOS_LIFECYCLE_CORRUPT', message, cause);
const same = (a, b) => a.dev === b.dev && a.ino === b.ino;

/** Copy only lossless JSON data; never invoke a getter while recording a result. */
export function snapshot(value) {
  const ancestors = new Set();
  function copy(input) {
    if (input === null || typeof input === 'string' || typeof input === 'boolean') return input;
    if (typeof input === 'number' && Number.isFinite(input) && !Object.is(input, -0)) return input;
    if (!input || typeof input !== 'object' || ancestors.has(input)) throw new TypeError('Lifecycle data must be lossless JSON');
    const array = Array.isArray(input);
    if (!array && ![Object.prototype, null].includes(Object.getPrototypeOf(input))) throw new TypeError('Lifecycle data must be plain JSON');
    const keys = Reflect.ownKeys(input).filter(key => !(array && key === 'length'));
    if (keys.some(key => typeof key !== 'string') || (array && (keys.length !== input.length
        || keys.some((key, index) => key !== String(index))))) throw new TypeError('Lifecycle arrays must be dense');
    const output = array ? [] : {};
    ancestors.add(input);
    for (const key of keys) {
      const descriptor = Object.getOwnPropertyDescriptor(input, key);
      if (!descriptor.enumerable || !Object.hasOwn(descriptor, 'value')) throw new TypeError('Lifecycle data must not contain getters');
      Object.defineProperty(output, key, { value: copy(descriptor.value), enumerable: true, writable: true, configurable: true });
    }
    ancestors.delete(input);
    return output;
  }
  return copy(value);
}

function validateBody(body) {
  if (!body || Array.isArray(body) || !kinds.has(body.kind)
      || typeof body.bootId !== 'string' || !body.bootId || body.bootId.includes('\0')) throw corrupt('Invalid boundary record identity');
  return body;
}

function decode(bytes) {
  const records = [];
  let offset = 0, previous = '0'.repeat(64);
  while (offset < bytes.length) {
    const end = bytes.indexOf(10, offset);
    if (end < 0) return { records, corruption: { offset, reason: 'incomplete-tail' } };
    if (end - offset > maximumRecordBytes) return { records, corruption: { offset, reason: 'record-too-large' } };
    try {
      const record = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(offset, end)));
      validateBody(record.body);
      if (record.v !== 1 || record.seq !== records.length || record.prev !== previous
          || (record.seq === 0) !== (record.body.kind === 'header')
          || record.hash !== digest(JSON.stringify({ v: record.v, seq: record.seq, prev: record.prev, body: record.body }))) {
        throw new Error('sequence or checksum mismatch');
      }
      records.push(record); previous = record.hash;
    } catch (error) {
      return { records, corruption: { offset, reason: 'invalid-record', detail: error.message } };
    }
    offset = end + 1;
  }
  return { records, corruption: records.length ? null : { offset: 0, reason: 'missing-header' } };
}

/**
 * One main-engine append journal, protected by a real flock on a fixed inode.
 * No truncation, implicit repair, compaction or filename-prefix cleanup occurs.
 * fs/onStage are explicit fault-test seams, never supplied by a tool or HTTP.
 */
export async function openBoundaryJournal({ directory, lockExclusive, fs = nodeFs, onStage = () => {} }) {
  if (!isMainThread) throw fail('ERR_OHOS_LIFECYCLE_MAIN_THREAD', 'Boundary journal belongs to the main engine');
  if (typeof directory !== 'string' || !isAbsolute(directory) || resolve(directory) !== directory
      || directory === '/' || directory.includes('\0') || typeof lockExclusive !== 'function') {
    throw new TypeError('A canonical private directory and native lock are required');
  }
  const handles = [];
  const open = async (...args) => { const value = await fs.open(...args); handles.push(value); return value; };
  const privateDirectory = async path => {
    await fs.mkdir(path, { recursive: true, mode: 0o700 });
    const info = await fs.lstat(path);
    if (!info.isDirectory() || (info.mode & 0o077) || await fs.realpath(path) !== path) throw corrupt('Boundary storage requires a private canonical directory');
    return open(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  };
  let file, lock, directoryHandle, resultsHandle, records, corruption;
  const logPath = join(directory, 'boundary.jsonl');
  try {
    directoryHandle = await privateDirectory(directory);
    const lockPath = join(directory, '.lock');
    lock = await open(lockPath, constants.O_RDWR | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
    const info = await lock.stat();
    if (!info.isFile() || (info.mode & 0o077)) throw corrupt('Boundary lock must be a private regular file');
    if (lockExclusive(lock.fd) !== undefined) throw new TypeError('lockExclusive must synchronously return undefined');
    if (!same(info, await fs.lstat(lockPath))) throw corrupt('Boundary lock path changed');
    resultsHandle = await privateDirectory(join(directory, 'results'));
    let created = false;
    try {
      file = await open(logPath, constants.O_RDWR | constants.O_CREAT | constants.O_EXCL | constants.O_APPEND | constants.O_NOFOLLOW, 0o600);
      created = true;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      file = await open(logPath, constants.O_RDWR | constants.O_APPEND | constants.O_NOFOLLOW);
    }
    const fileInfo = await file.stat();
    if (!fileInfo.isFile() || (fileInfo.mode & 0o077) || fileInfo.size > 64 * 1024 * 1024) throw corrupt('Boundary log must be a bounded private regular file');
    if (created) {
      const header = { v: 1, seq: 0, prev: '0'.repeat(64), body: { kind: 'header', bootId: 'journal', journalId: randomUUID() } };
      await file.writeFile(JSON.stringify({ ...header, hash: digest(JSON.stringify(header)) }) + '\n');
      await file.sync();
    }
    const reader = await fs.open(logPath, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      if (!same(await reader.stat(), await file.stat())) throw corrupt('Boundary log changed while opening');
      ({ records, corruption } = decode(await reader.readFile()));
    } finally { await reader.close(); }
    await directoryHandle.sync();
    const parent = await fs.open(dirname(directory), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    try { await parent.sync(); } finally { await parent.close(); }
  } catch (error) {
    await Promise.allSettled(handles.map(handle => handle.close()));
    throw error;
  }
  let tail = Promise.resolve(), accepting = true, closed = false, poison, closing;
  const check = () => {
    if (closed) throw fail('ERR_OHOS_LIFECYCLE_CLOSED', 'Boundary journal is closed');
    if (corruption) throw corrupt('Boundary journal has an invalid or incomplete tail');
    if (poison) throw fail('ERR_OHOS_LIFECYCLE_POISONED', 'Boundary journal persistence failed', poison);
  };
  const enqueue = operation => {
    if (!accepting) return Promise.reject(fail('ERR_OHOS_LIFECYCLE_CLOSED', 'Boundary journal is closing'));
    const result = tail.then(() => { check(); return operation(); });
    tail = result.catch(error => { poison ??= error; });
    return result;
  };
  async function writeAll(handle, bytes) {
    for (let offset = 0; offset < bytes.length;) {
      const { bytesWritten } = await handle.write(bytes, offset, bytes.length - offset, null);
      if (!Number.isInteger(bytesWritten) || bytesWritten <= 0 || bytesWritten > bytes.length - offset) throw new Error('Boundary write made invalid progress');
      offset += bytesWritten;
    }
  }
  async function append(body) {
    if (!same(await file.stat(), await fs.lstat(logPath))) throw corrupt('Boundary log path changed');
    const base = { v: 1, seq: records.length, prev: records.at(-1)?.hash ?? '0'.repeat(64), body };
    const record = { ...base, hash: digest(JSON.stringify(base)) };
    const bytes = Buffer.from(JSON.stringify(record) + '\n');
    if (bytes.length > maximumRecordBytes) throw new RangeError('Boundary record exceeds 1 MiB');
    if ((await file.stat()).size + bytes.length > 64 * 1024 * 1024) throw new RangeError('Boundary journal exceeds 64 MiB; explicit maintenance is required');
    await onStage('before-record', record);
    await writeAll(file, bytes);
    await file.sync();
    if (!same(await file.stat(), await fs.lstat(logPath))) throw corrupt('Boundary log path changed during persistence');
    records.push(record);
    await onStage('record-durable', record);
    return snapshot(record);
  }
  async function resultFile(bytes) {
    if (bytes.length > maximumResultBytes) throw new RangeError('Lifecycle result exceeds 16 MiB');
    const hash = digest(bytes), relative = `results/${hash}.json`, path = join(directory, relative);
    let handle, created = false;
    try {
      try {
        handle = await fs.open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        created = true;
        await writeAll(handle, bytes);
        await handle.sync();
      } catch (error) {
        if (created || error.code !== 'EEXIST') throw error;
        handle = await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
        const info = await handle.stat();
        if (!info.isFile() || (info.mode & 0o077) || info.size !== bytes.length
            || digest(await handle.readFile()) !== hash) throw corrupt('Existing result file is incomplete or changed');
      }
    } finally { await handle?.close(); }
    await resultsHandle.sync();
    const reference = { path: relative, sha256: hash, bytes: bytes.length };
    await onStage('result-durable', reference);
    return reference;
  }
  return Object.freeze({
    get records() { return snapshot(records); },
    get corruption() { return corruption && snapshot(corruption); },
    get failed() { return poison !== undefined; },
    append(body) {
      const copied = validateBody(snapshot(body));
      return enqueue(() => append(copied));
    },
    appendResult(body, result) {
      const copied = validateBody(snapshot(body));
      const bytes = Buffer.from(JSON.stringify(snapshot(result)));
      return enqueue(async () => append({ ...copied, result: await resultFile(bytes) }));
    },
    async readResult(reference) {
      if (!reference || !/^[a-f0-9]{64}$/.test(reference.sha256)
          || reference.path !== `results/${reference.sha256}.json`
          || !Number.isSafeInteger(reference.bytes) || reference.bytes < 0 || reference.bytes > maximumResultBytes) throw corrupt('Invalid result reference');
      let handle;
      try {
        handle = await fs.open(join(directory, reference.path), constants.O_RDONLY | constants.O_NOFOLLOW);
        const info = await handle.stat();
        if (!info.isFile() || (info.mode & 0o077) || info.size !== reference.bytes) throw corrupt('Result file identity or size changed');
        const bytes = await handle.readFile();
        if (digest(bytes) !== reference.sha256) throw corrupt('Result checksum mismatch');
        return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      } catch (cause) { throw corrupt('Reliable lifecycle result is unavailable', cause); }
      finally { await handle?.close(); }
    },
    async flush() { await tail; check(); await file.sync(); },
    close() {
      if (closing) return closing;
      accepting = false;
      closing = (async () => {
        await tail; closed = true;
        const results = await Promise.allSettled(handles.map(handle => handle.close()));
        const failures = results.filter(row => row.status === 'rejected').map(row => row.reason);
        if (failures.length) throw new AggregateError(failures, 'Boundary journal close failed');
      })();
      return closing;
    },
  });
}
