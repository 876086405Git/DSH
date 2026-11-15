// iOS container relocation. Called once, under the main engine's ownership lock,
// before Cordis or session storage reads any on-disk state. Never edit log bodies.
// Path encodings and frame grammar follow @deepseek-ai/dsh-session-persistence-jsonl
// 0.2.1-rc.4. Portions derived from DeepSeek Harness, Copyright (c) 2026 DeepSeek,
// MIT; the existing THIRD_PARTY_NOTICES.md retains the full notice and terms.
import * as fs from 'node:fs/promises';
import { constants, createWriteStream } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { dirname, join, posix } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { constants as zstdConstants, zstdCompress, zstdDecompress } from 'node:zlib';
import { promisify } from 'node:util';

const MAX_METADATA = 1024 * 1024;
const MAX_MARKER = 64 * 1024;
const NOFOLLOW = constants.O_NOFOLLOW;
const generationPattern = /^session(?:\.v([1-9][0-9]*))?\.jsonl(\.zstd)?$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const shaPattern = /^[0-9a-f]{64}$/;
const compress = promisify(zstdCompress), decompress = promisify(zstdDecompress);

class InvalidSession extends Error {
  constructor(reason) { super(reason); this.code = 'ERR_IOS_RELOCATION_SESSION'; this.reason = reason; }
}
function refuse(reason) {
  throw Object.assign(new Error(`iOS container relocation refused: ${reason}`),
    { code: 'ERR_IOS_RELOCATION_STATE' });
}
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
export function validRoot(value) {
  return typeof value === 'string' && value !== '/' && value.startsWith('/') &&
    !value.includes('\0') && posix.normalize(value) === value && !value.endsWith('/');
}
function roots(value) {
  if (!Array.isArray(value) || value.some(root => !validRoot(root))) refuse('invalid root history');
  return [...new Set(value)];
}
function within(path, root) { return path === root || path.startsWith(root + '/'); }
export function relocatePath(path, oldRoots, currentRoot) {
  if (typeof path !== 'string') return path;
  // A previous container can be a lexical parent of a new one in a test/install.
  // An already-current path always wins over a broader historical prefix.
  if (within(path, currentRoot)) return path;
  const old = [...oldRoots].sort((a, b) => b.length - a.length).find(root => within(path, root));
  return old === undefined ? path : currentRoot + path.slice(old.length);
}
export function rootFromProfile(profile) {
  if (!Array.isArray(profile)) refuse('legacy profile is not a patch array');
  const rows = profile.flatMap(row => object(row) && Array.isArray(row.insert) ? [row, ...row.insert] : [row]);
  const select = id => {
    const found = rows.filter(row => object(row) && row.id === id);
    if (found.length !== 1 || !object(found[0].config)) refuse('ambiguous legacy profile anchors');
    return found[0].config;
  };
  const directory = select('working-directory').defaultDirectory;
  const policy = select('sandbox-policy').workspaceRoot;
  const workspaces = select('ohos-subprocess').workspaceRoots;
  if (!Array.isArray(workspaces) || workspaces.length !== 1 || directory !== policy ||
      directory !== workspaces[0] || !validRoot(directory) || !directory.endsWith('/root/workspace')) {
    refuse('inconsistent legacy profile anchors');
  }
  const root = directory.slice(0, -'/root/workspace'.length);
  if (!validRoot(root)) refuse('invalid legacy container root');
  return root;
}
// These two encodings are the pinned rc.4 JSONL layout contract. The project key
// is lossy; derive it from a validated header, never decode a directory as a cwd.
export function encodeSegment(raw) {
  if (typeof raw !== 'string' || !raw.length) throw new InvalidSession('invalid-session-id');
  if (raw === '.') return '~002E';
  if (raw === '..') return '~002E~002E';
  let out = '';
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    out += /^[A-Za-z0-9._-]$/.test(ch) ? ch : '~' + raw.charCodeAt(i).toString(16).toUpperCase().padStart(4, '0');
  }
  return out;
}
export function projectKey(cwd) {
  if (cwd === undefined) return '_no-cwd';
  if (typeof cwd !== 'string' || !cwd.length) throw new InvalidSession('invalid-session-cwd');
  let readable = '', separator = false;
  for (let i = 0; i < cwd.length; i++) {
    const ch = cwd[i];
    if (ch === '/' || ch === '\\' || ch === ':') {
      if (!separator) readable += '-';
      separator = true;
    } else {
      readable += /^[A-Za-z0-9._-]$/.test(ch) ? ch : '~' + cwd.charCodeAt(i).toString(16).toUpperCase().padStart(4, '0');
      separator = false;
    }
  }
  return `--${(readable.replace(/^-+/, '') || 'root').slice(0, 251)}--`;
}
function decodeSegment(segment) {
  const decoded = segment.replace(/~([0-9A-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
  try { return encodeSegment(decoded) === segment ? decoded : undefined; } catch { return undefined; }
}
function relativeSession(value) {
  return typeof value === 'string' && !value.includes('\0') && !value.includes('\\') &&
    value.split('/').length === 2 && value.split('/').every(part => part && part !== '.' && part !== '..') &&
    !value.startsWith('.dsh-go-lifecycle/');
}
async function maybeStat(path) {
  try { return await fs.lstat(path); } catch (error) { if (error.code === 'ENOENT') return; throw error; }
}
async function directory(path) {
  const stat = await fs.lstat(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) refuse('directory identity is not regular');
  return stat;
}
async function syncDirectory(path) {
  const handle = await fs.open(path, constants.O_RDONLY | NOFOLLOW);
  try { if (!(await handle.stat()).isDirectory()) refuse('invalid directory for sync'); await handle.sync(); }
  finally { await handle.close(); }
}
async function makeDirectory(path) {
  try { await fs.mkdir(path, { mode: 0o700 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  await directory(path);
  // A retry may observe mkdir from a previous attempt whose parent fsync failed.
  await syncDirectory(dirname(path));
}
async function readJson(path, limit = MAX_METADATA) {
  let handle;
  try { handle = await fs.open(path, constants.O_RDONLY | NOFOLLOW); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > limit) refuse('metadata is not a bounded regular file');
    const data = await handle.readFile();
    if (data.length > limit) refuse('metadata exceeded its bound');
    try { return JSON.parse(data); } catch { refuse('malformed relocation metadata'); }
  } finally { await handle.close(); }
}
async function atomicJson(path, value, limit = MAX_METADATA) {
  const data = Buffer.from(JSON.stringify(value) + '\n');
  if (data.length > limit) refuse('metadata exceeds its bound');
  const temp = join(dirname(path), `.ios-relocation-${randomUUID()}.tmp`);
  const handle = await fs.open(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW, 0o600);
  try { await handle.writeFile(data); await handle.sync(); }
  finally { await handle.close(); }
  await fs.rename(temp, path);
  await syncDirectory(dirname(path));
}
async function unlinkDurable(path) {
  try { await fs.unlink(path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await syncDirectory(dirname(path));
}
async function digestFile(path) {
  const handle = await fs.open(path, constants.O_RDONLY | NOFOLLOW);
  try {
    if (!(await handle.stat()).isFile()) refuse('generation is not a regular file');
    const hash = createHash('sha256');
    for await (const chunk of handle.createReadStream({ autoClose: false })) hash.update(chunk);
    return hash.digest('hex');
  } finally { await handle.close(); }
}
function identity(stat) { return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeNs ?? stat.mtimeMs}`; }
// The pinned JSONL backend uses one independent Zstandard frame for the header,
// followed by independent event-batch frames. Parse frame structure; a magic-byte
// search is invalid because compressed/raw block payloads can contain that magic.
export function firstZstdFrameEnd(bytes) {
  if (bytes.length < 4) return;
  if (bytes.readUInt32LE(0) !== 0xfd2fb528) throw new InvalidSession('invalid-zstd-header-frame');
  if (bytes.length < 5) return;
  const descriptor = bytes[4];
  if (descriptor & 24) throw new InvalidSession('invalid-zstd-header-frame');
  const single = Boolean(descriptor & 32), sizeFlag = descriptor >>> 6, dictionaryFlag = descriptor & 3;
  const dictionarySize = dictionaryFlag === 3 ? 4 : dictionaryFlag;
  const contentSize = sizeFlag === 0 ? (single ? 1 : 0) : 1 << sizeFlag;
  let offset = 5 + (single ? 0 : 1) + dictionarySize + contentSize;
  if (offset > bytes.length) return;
  for (;;) {
    if (bytes.length - offset < 3) return;
    const block = bytes.readUIntLE(offset, 3), type = (block >>> 1) & 3;
    if (type === 3) throw new InvalidSession('invalid-zstd-header-frame');
    offset += 3 + (type === 1 ? 1 : block >>> 3);
    if (offset > bytes.length) return;
    if (block & 1) break;
  }
  if (descriptor & 4) offset += 4;
  return offset <= bytes.length ? offset : undefined;
}
async function firstRecord(handle, zstd) {
  let bytes = Buffer.alloc(0), position = 0;
  for (;;) {
    const chunk = Buffer.alloc(8192);
    const { bytesRead } = await handle.read(chunk, 0, chunk.length, position);
    if (!bytesRead) throw new InvalidSession(zstd ? 'incomplete-zstd-header-frame' : 'missing-complete-header');
    position += bytesRead;
    bytes = Buffer.concat([bytes, chunk.subarray(0, bytesRead)]);
    const end = zstd ? firstZstdFrameEnd(bytes) : (bytes.indexOf(10) < 0 ? undefined : bytes.indexOf(10) + 1);
    if (end === undefined) {
      if (bytes.length > MAX_METADATA + 65536) throw new InvalidSession('header-too-large');
      continue;
    }
    const encoded = bytes.subarray(0, end);
    let record = encoded;
    if (zstd) {
      try { record = await decompress(encoded, { maxOutputLength: MAX_METADATA }); }
      catch (error) {
        if (error.code === 'ERR_BUFFER_TOO_LARGE') throw new InvalidSession('header-too-large');
        if (typeof error.code === 'string' && error.code.startsWith('ZSTD_error_')) throw new InvalidSession('invalid-zstd-header-frame');
        throw error;
      }
    }
    if (record.length > MAX_METADATA) throw new InvalidSession('header-too-large');
    if (!record.length || record.at(-1) !== 10 || record.indexOf(10) !== record.length - 1) {
      throw new InvalidSession(zstd ? 'invalid-zstd-header-frame' : 'missing-complete-header');
    }
    return { encoded, record, end };
  }
}
async function rewriteGeneration(source, output, expected, oldRoots, currentRoot, readHeader) {
  if (!(await fs.lstat(source)).isFile()) throw new InvalidSession('generation-not-regular');
  const handle = await fs.open(source, constants.O_RDONLY | NOFOLLOW);
  const before = await handle.stat({ bigint: true });
  if (!before.isFile()) { await handle.close(); throw new InvalidSession('generation-not-regular'); }
  const inputHash = createHash('sha256'), bodyHash = createHash('sha256');
  let header, changed = false;
  try {
    const first = await firstRecord(handle, expected.zstd);
    let raw;
    try { raw = JSON.parse(first.record.subarray(0, -1).toString('utf8')); }
    catch { throw new InvalidSession('malformed-header-json'); }
    const parsed = readHeader(raw);
    if (parsed.status !== 'current' && parsed.status !== 'migration-required') {
      throw new InvalidSession(parsed.status === 'unsupported' ? 'unsupported-session-format' : 'malformed-header');
    }
    if (parsed.storedVersion !== expected.version || parsed.header.id !== expected.id ||
        projectKey(parsed.header.cwd) !== expected.project || raw.cwd !== parsed.header.cwd) {
      throw new InvalidSession('header-layout-identity-mismatch');
    }
    if (raw.cwd !== undefined && (!raw.cwd.startsWith('/') || raw.cwd.includes('\0') || posix.normalize(raw.cwd) !== raw.cwd)) {
      throw new InvalidSession('noncanonical-session-cwd');
    }
    header = { id: parsed.header.id, cwd: raw.cwd };
    const cwd = relocatePath(raw.cwd, oldRoots, currentRoot);
    changed = cwd !== raw.cwd;
    let encoded = first.encoded;
    if (changed) {
      const record = Buffer.from(JSON.stringify({ ...raw, cwd }) + '\n');
      encoded = expected.zstd ? await compress(record, { params: { [zstdConstants.ZSTD_c_checksumFlag]: 1 } }) : record;
    }
    inputHash.update(first.encoded);
    async function* relocatedBytes() {
      yield encoded;
      // Copy every compressed event frame and any recoverable torn tail exactly.
      // The persistence backend retains sole ownership of event recovery rules.
      for await (const chunk of handle.createReadStream({ start: first.end, autoClose: false })) {
        inputHash.update(chunk); bodyHash.update(chunk); yield chunk;
      }
    }
    await pipeline(relocatedBytes, createWriteStream(output,
      { flags: constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NOFOLLOW, mode: 0o600 }));
    const after = await handle.stat({ bigint: true });
    if (identity(before) !== identity(after)) refuse('source changed during relocation');
  } finally { await handle.close(); }
  const out = await fs.open(output, constants.O_RDONLY | NOFOLLOW);
  try { await out.sync(); } finally { await out.close(); }
  return { header, changed, before: inputHash.digest('hex'), after: await digestFile(output), body: bodyHash.digest('hex') };
}

function validateMarker(value) {
  if (!object(value) || value.version !== 1 || !validRoot(value.currentRoot)) refuse('invalid container marker');
  roots(value.previousRoots);
  if (value.workspaceAliases !== undefined && (!object(value.workspaceAliases) ||
      Object.entries(value.workspaceAliases).some(([key, target]) => !key || typeof target !== 'string' || !target))) {
    refuse('invalid workspace aliases');
  }
  return value;
}
function validatedAliases(value) {
  if (!object(value) || Object.entries(value).some(([key, target]) => !key || key.includes('\0') ||
      typeof target !== 'string' || !target || target.includes('\0') || key === target)) {
    refuse('invalid workspace alias journal');
  }
  for (const id of Object.keys(value)) {
    const seen = new Set([id]); let target = value[id];
    while (Object.hasOwn(value, target)) {
      if (seen.has(target)) refuse('workspace alias cycle');
      seen.add(target); target = value[target];
    }
  }
  return value;
}
async function quarantineCounts(work) {
  const index = await readJson(join(work, 'quarantine', 'index.json'));
  const counts = Object.create(null);
  if (index === undefined) return counts;
  if (index.version !== 1 || !Array.isArray(index.entries)) refuse('invalid quarantine index');
  for (const entry of index.entries) {
    if (!object(entry) || typeof entry.reason !== 'string' || !/^[a-z-]+$/.test(entry.reason)) refuse('invalid quarantine reason');
    counts[entry.reason] = (counts[entry.reason] ?? 0) + 1;
  }
  return counts;
}
async function sessionPath(sessions, relative) {
  if (!relativeSession(relative)) refuse('invalid relative session path');
  const path = join(sessions, relative);
  const parent = dirname(path);
  if (await maybeStat(parent)) await directory(parent);
  const stat = await maybeStat(path);
  if (stat && (!stat.isDirectory() || stat.isSymbolicLink())) refuse('session directory identity changed');
  return { path, stat };
}
async function finishPending(context) {
  const { work, sessions, checkpoint } = context;
  const pendingPath = join(work, 'pending.json');
  const pending = await readJson(pendingPath);
  if (pending === undefined) { await syncDirectory(work); return; }
  if (!object(pending) || pending.version !== 1 || !uuidPattern.test(pending.transaction) ||
      !relativeSession(pending.source) || !['relocate', 'quarantine'].includes(pending.kind) ||
      !/^[0-9]+:[0-9]+$/.test(pending.directoryIdentity)) refuse('invalid pending transaction');
  const stage = join(work, `stage-${pending.transaction}`);
  await directory(stage);
  const source = await sessionPath(sessions, pending.source);
  let target;
  if (pending.kind === 'relocate') {
    if (!relativeSession(pending.target) || !Array.isArray(pending.files) || !pending.files.length) refuse('invalid pending generations');
    await makeDirectory(join(sessions, pending.target.split('/')[0]));
    target = await sessionPath(sessions, pending.target);
  } else {
    if (!object(pending.record) || pending.record.transaction !== pending.transaction) refuse('invalid quarantine record');
    const parent = join(work, 'quarantine', pending.transaction);
    await makeDirectory(parent);
    target = { path: join(parent, 'session'), stat: await maybeStat(join(parent, 'session')) };
    if (target.stat) await directory(target.path);
  }
  if (source.path !== target.path) {
    if (source.stat && target.stat) refuse('both transaction directories exist');
    if (!source.stat && !target.stat) refuse('both transaction directories are missing');
    const owned = source.stat ?? target.stat;
    if (`${owned.dev}:${owned.ino}` !== pending.directoryIdentity) refuse('transaction directory identity changed');
    if (source.stat) {
      await fs.rename(source.path, target.path);
    }
    // Also sync an already-renamed directory on recovery: the previous attempt
    // may have failed after rename but before either parent fsync completed.
    await syncDirectory(dirname(source.path)); await syncDirectory(dirname(target.path));
    await checkpoint('session-directory-renamed', pending);
  } else if (!source.stat || `${source.stat.dev}:${source.stat.ino}` !== pending.directoryIdentity) refuse('transaction directory identity changed');
  if (pending.kind === 'relocate') {
    for (const file of pending.files) {
      if (!object(file) || !generationPattern.test(file.name) || !shaPattern.test(file.before) || !shaPattern.test(file.after)) refuse('invalid generation journal');
      const path = join(target.path, file.name), staged = join(stage, file.name), backup = join(stage, file.name + '.original');
      const current = await digestFile(path);
      if (current === file.after) {
        // Content equality does not prove the last namespace update was synced.
        await syncDirectory(target.path); await syncDirectory(stage); continue;
      }
      if (current !== file.before || await digestFile(staged) !== file.after) refuse('generation bytes changed during recovery');
      if (!(await maybeStat(backup))) { await fs.link(path, backup); await syncDirectory(stage); }
      if (await digestFile(backup) !== file.before) refuse('original generation backup changed');
      await fs.rename(staged, path);
      await syncDirectory(target.path); await syncDirectory(stage);
      await checkpoint('generation-replaced', { ...pending, file: file.name });
    }
  } else {
    const indexPath = join(work, 'quarantine', 'index.json');
    const index = await readJson(indexPath) ?? { version: 1, entries: [] };
    if (index.version !== 1 || !Array.isArray(index.entries)) refuse('invalid quarantine index');
    if (!index.entries.some(entry => entry.transaction === pending.transaction)) {
      index.entries.push(pending.record); await atomicJson(indexPath, index);
    }
  }
  await checkpoint('session-committed', pending);
  await unlinkDurable(pendingPath);
  await fs.rm(stage, { recursive: true }); await syncDirectory(work);
}
async function deletionDirectories(sessions) {
  const lifecycle = join(sessions, '.dsh-go-lifecycle');
  if (!(await maybeStat(lifecycle))) return new Set();
  await directory(lifecycle);
  const deleted = new Set();
  for (const name of await fs.readdir(lifecycle)) {
    if (!/^[0-9a-f]{64}$/.test(name)) continue;
    const folder = join(lifecycle, name); await directory(folder);
    const marker = await readJson(join(folder, 'deleted.json'));
    if (marker === undefined) continue;
    if (marker.version !== 1 || !relativeSession(marker.directory)) refuse('invalid deletion marker');
    // Keep the tombstone and its directory at the original relative path. Its
    // permanent locks and retry target must never be recreated or reinterpreted.
    deleted.add(marker.directory);
  }
  return deleted;
}
async function migrateSessions(context, oldRoots, currentRoot, readHeader) {
  const { sessions, work, checkpoint } = context;
  const deleted = await deletionDirectories(sessions);
  const validIds = new Set();
  let migrated = 0, isolated = 0;
  const candidates = [];
  const idCounts = new Map();
  const quarantine = await readJson(join(work, 'quarantine', 'index.json'));
  if (quarantine !== undefined && (!object(quarantine) || quarantine.version !== 1 || !Array.isArray(quarantine.entries))) refuse('invalid quarantine index');
  // If the process stopped after isolating the first conflicting copy, the next
  // scan must not promote the remaining copy to an arbitrary authoritative one.
  const conflictingIds = new Set((quarantine?.entries ?? [])
    .filter(entry => entry.reason === 'duplicate-session-id').map(entry => entry.sessionId));
  for (const project of (await fs.readdir(sessions)).sort()) {
    if (project === '.dsh-go-lifecycle') continue;
    const projectPath = join(sessions, project), stat = await fs.lstat(projectPath);
    if (!stat.isDirectory() || stat.isSymbolicLink()) continue;
    for (const segment of (await fs.readdir(projectPath)).sort()) {
      const relative = `${project}/${segment}`;
      if (deleted.has(relative)) continue;
      const stat = await fs.lstat(join(sessions, relative));
      if (stat.isDirectory() && !stat.isSymbolicLink()) {
        const names = (await fs.readdir(join(sessions, relative))).filter(name => generationPattern.test(name)).sort();
        if (!names.length) continue; // Empty deletion residue retains permanent locks.
        const id = decodeSegment(segment);
        if (id !== undefined) idCounts.set(id, (idCounts.get(id) ?? 0) + 1);
        candidates.push({ relative, project, segment, names, id });
      }
    }
  }
  for (const item of candidates) {
    const original = join(sessions, item.relative);
    const originalStat = await maybeStat(original);
    if (!originalStat) continue; // Earlier identical target is never overwritten.
    const directoryIdentity = `${originalStat.dev}:${originalStat.ino}`;
    const { names, id } = item;
    const transaction = randomUUID(), stage = join(work, `stage-${transaction}`);
    await makeDirectory(stage);
    let records = [], header;
    try {
      if (id === undefined) throw new InvalidSession('noncanonical-session-directory');
      if (idCounts.get(id) > 1 || conflictingIds.has(id)) throw new InvalidSession('duplicate-session-id');
      for (const name of names) {
        const match = generationPattern.exec(name), version = match[1] === undefined ? 0 : Number(match[1]);
        if (!Number.isSafeInteger(version)) throw new InvalidSession('unsupported-session-format');
        const result = await rewriteGeneration(join(original, name), join(stage, name),
          { version, id, project: item.project, zstd: Boolean(match[2]) }, oldRoots, currentRoot, readHeader);
        if (header && (header.id !== result.header.id || header.cwd !== result.header.cwd)) throw new InvalidSession('conflicting-generation-identities');
        header = result.header; records.push({ name, ...result });
      }
      const cwd = relocatePath(header.cwd, oldRoots, currentRoot);
      const target = `${projectKey(cwd)}/${encodeSegment(header.id)}`;
      if (target !== item.relative && await maybeStat(join(sessions, target))) throw new InvalidSession('target-session-conflict');
      if (!records.some(record => record.changed) && target === item.relative) {
        validIds.add(id); await fs.rm(stage, { recursive: true }); await syncDirectory(work); continue;
      }
      await syncDirectory(stage);
      await atomicJson(join(work, 'pending.json'), { version: 1, kind: 'relocate', transaction,
        directoryIdentity, source: item.relative, target, files: records.map(({ name, before, after }) => ({ name, before, after })) });
      await checkpoint('session-prepared', { transaction, source: item.relative, target });
      await finishPending(context);
      validIds.add(id); migrated++;
    } catch (error) {
      // Only intrinsic session-data failures are isolated. Permission, ENOSPC,
      // fsync, EIO and interruptions stop startup with the pending journal intact.
      if (!(error instanceof InvalidSession)) throw error;
      if (await readJson(join(work, 'pending.json'))) throw error;
      const record = { transaction, source: item.relative, ...(id === undefined ? {} : { sessionId: id }), reason: error.reason };
      await atomicJson(join(work, 'pending.json'), { version: 1, kind: 'quarantine', transaction, directoryIdentity, source: item.relative, record });
      await checkpoint('quarantine-prepared', record);
      await finishPending(context); isolated++;
    }
  }
  return { migrated, isolated, validIds };
}
async function migrateRegistry(home, work, oldRoots, currentRoot, validIds, priorAliases) {
  const path = join(home, 'storages', 'workspace.json');
  const registry = await readJson(path, 32 * MAX_METADATA);
  const aliasPath = join(work, 'workspace-aliases.json');
  const savedAliases = await readJson(aliasPath, MAX_MARKER);
  const aliases = Object.assign(Object.create(null), validatedAliases(priorAliases),
    savedAliases === undefined ? {} : validatedAliases(savedAliases));
  if (registry === undefined) return aliases;
  if (!object(registry) || registry.unit?.name !== 'workspace' || registry.unit.version !== 2 ||
      !object(registry.global) || !Array.isArray(registry.global.workspaceIds) || !object(registry.tables?.workspaces)) refuse('unsupported workspace registry');
  const table = registry.tables.workspaces, order = registry.global.workspaceIds;
  if (new Set(order).size !== order.length || order.some(id => typeof id !== 'string' || !object(table[id]))) refuse('invalid workspace order');
  const pending = registry.global.pendingMutation;
  if (pending !== undefined && (!object(pending) || !['create', 'delete'].includes(pending.operation) ||
      typeof pending.workspaceId !== 'string' || order.includes(pending.workspaceId))) refuse('invalid pending workspace mutation');
  // The original registry will discard this explicitly pending, unordered row.
  // Leave that transaction and row intact; never choose it as a merge winner.
  const pendingId = pending?.workspaceId;
  if (Object.keys(table).some(id => !order.includes(id) && id !== pendingId)) refuse('unexplained workspace order divergence');
  const quarantine = await readJson(join(work, 'quarantine', 'index.json'));
  const removed = new Set((quarantine?.entries ?? []).map(entry => entry.sessionId).filter(id => typeof id === 'string' && !validIds.has(id)));
  const originals = new Map();
  for (const [id, row] of Object.entries(table)) {
    if (id === pendingId) continue;
    if (!object(row) || typeof row.path !== 'string' || !Array.isArray(row.sessionIds)) refuse('invalid workspace record');
    originals.set(id, row.path);
    row.path = relocatePath(row.path, oldRoots, currentRoot);
    row.sessionIds = row.sessionIds.filter(id => !removed.has(id));
  }
  // Prefer the original historical workspace id if a failed previous update
  // already registered the new path. Preserve every surviving session id.
  const winnerByPath = new Map();
  const allIds = [...order];
  const prioritized = [...allIds].sort((a, b) => Number(originals.get(b) !== table[b].path) - Number(originals.get(a) !== table[a].path));
  for (const id of prioritized) {
    const row = table[id], winner = winnerByPath.get(row.path);
    if (winner === undefined) { winnerByPath.set(row.path, id); continue; }
    const keep = table[winner];
    keep.sessionIds = [...new Set([...keep.sessionIds, ...row.sessionIds])];
    if (typeof keep.updatedAt === typeof row.updatedAt &&
        (typeof keep.updatedAt === 'number' || typeof keep.updatedAt === 'string') && row.updatedAt > keep.updatedAt) keep.updatedAt = row.updatedAt;
    aliases[id] = winner; delete table[id];
  }
  for (const [id, target] of Object.entries(aliases)) {
    const seen = new Set([id]); let final = target;
    while (aliases[final] !== undefined) { if (seen.has(final)) refuse('workspace alias cycle'); seen.add(final); final = aliases[final]; }
    aliases[id] = final;
  }
  registry.global.workspaceIds = [...new Set(order.map(id => aliases[id] ?? id))];
  if (typeof registry.global.defaultWorkspaceId === 'string') {
    registry.global.defaultWorkspaceId = aliases[registry.global.defaultWorkspaceId] ?? registry.global.defaultWorkspaceId;
  }
  for (const field of ['archivedSessionIds', 'pinnedSessionIds']) {
    if (registry.global[field] !== undefined) {
      if (!Array.isArray(registry.global[field])) refuse('invalid workspace session index');
      registry.global[field] = registry.global[field].filter(id => !removed.has(id));
    }
  }
  // A durable original copy makes registry edits inspectable; never overwrite
  // it on recovery. It is private app state, not a diagnostic console dump.
  const backup = join(work, 'workspace-before.json');
  if (!(await maybeStat(backup))) { await fs.link(path, backup); await syncDirectory(work); }
  // Persist id aliases before deleting duplicate registry rows. A restart after
  // registry commit but before the final marker must still restore preferences.
  await atomicJson(aliasPath, aliases, MAX_MARKER);
  await atomicJson(path, registry, 32 * MAX_METADATA);
  return aliases;
}

export async function migrateContainerPaths({ home = process.env.DSH_HOME, userHome = process.env.HOME,
  checkpoint = async () => {}, readHeader } = {}) {
  if (!validRoot(home) || !validRoot(userHome) || home !== join(userHome, '.dsh') ||
      !userHome.endsWith('/root') || await fs.realpath(home) !== home || await fs.realpath(userHome) !== userHome) refuse('untrusted native home layout');
  const currentRoot = userHome.slice(0, -'/root'.length);
  if (!validRoot(currentRoot) || await fs.realpath(currentRoot) !== currentRoot) refuse('invalid native container root');
  const markerPath = join(home, 'ios-container-paths.json');
  const originPath = join(home, 'ios-relocation-origin.json');
  const markerValue = await readJson(markerPath, MAX_MARKER);
  const marker = markerValue === undefined ? undefined : validateMarker(markerValue);
  const work = join(home, 'ios-relocation'), planPath = join(work, 'plan.json');
  if (await maybeStat(work)) await directory(work);
  const previousPlan = await readJson(planPath);
  if (previousPlan !== undefined && (!object(previousPlan) || previousPlan.version !== 1 || !validRoot(previousPlan.targetRoot))) refuse('invalid migration plan');
  const prior = marker ? [marker.currentRoot, ...marker.previousRoots] : [];
  let origin;
  if (!marker) {
    origin = await readJson(originPath, MAX_MARKER);
    // The native host preserves this before overwriting its generated profile.
    // No path is inferred from a lossy project key or an arbitrary UUID.
    if (origin !== undefined) prior.push(rootFromProfile(origin));
  }
  if (previousPlan) prior.push(...roots(previousPlan.roots), previousPlan.targetRoot);
  const oldRoots = roots(prior).filter(root => root !== currentRoot);
  if (!marker && !previousPlan && oldRoots.length === 0) {
    const sessionRoot = join(home, 'sessions');
    const existingSessions = await maybeStat(sessionRoot);
    if (existingSessions) await directory(sessionRoot);
    if (await maybeStat(join(home, 'storages', 'workspace.json')) ||
        (existingSessions && (await fs.readdir(sessionRoot)).length > 0)) {
      // Also covers a prior unpatched restart that has already overwritten the
      // legacy profile with the current root. That profile cannot establish the
      // historical origin of existing logs. Keep their state and marker absent;
      // never infer a container identity from a lossy project key or a UUID.
      return { status: 'unanchored', migrated: 0, isolated: 0, quarantineCounts: await quarantineCounts(work) };
    }
  }
  if (!previousPlan && (!marker || marker.currentRoot === currentRoot) && oldRoots.length === 0) {
    if (!marker) await atomicJson(markerPath, { version: 1, currentRoot, previousRoots: [] }, MAX_MARKER);
    await unlinkDurable(originPath);
    return { status: marker ? 'unchanged' : 'initialized', migrated: 0, isolated: 0, quarantineCounts: await quarantineCounts(work) };
  }
  if (!previousPlan && marker?.currentRoot === currentRoot) {
    await unlinkDurable(originPath);
    return { status: 'unchanged', migrated: 0, isolated: 0, quarantineCounts: await quarantineCounts(work) };
  }
  await makeDirectory(work); await makeDirectory(join(work, 'quarantine'));
  const sessions = join(home, 'sessions'); await makeDirectory(sessions);
  const context = { home, work, sessions, checkpoint };
  // Recover the last transaction before interpreting any session header. The
  // old plan also remembers an intermediate target if the app moved twice.
  await finishPending(context);
  // A crash before publishing pending.json leaves only disposable staged copies;
  // a crash after removing it leaves already-committed original backups here.
  for (const name of await fs.readdir(work)) {
    if (!name.startsWith('stage-') || !uuidPattern.test(name.slice(6))) continue;
    await directory(join(work, name));
    await fs.rm(join(work, name), { recursive: true }); await syncDirectory(work);
  }
  await atomicJson(planPath, { version: 1, targetRoot: currentRoot, roots: oldRoots });
  await checkpoint('plan-prepared', { oldRoots, currentRoot });
  if (!readHeader) ({ sessionFormatCatalog: { readHeader } } = await import('@deepseek-ai/dsh-session-format-catalog'));
  const result = await migrateSessions(context, oldRoots, currentRoot, readHeader);
  const workspaceAliases = await migrateRegistry(home, work, oldRoots, currentRoot, result.validIds, marker?.workspaceAliases ?? {});
  await checkpoint('registry-committed', { currentRoot });
  await atomicJson(markerPath, { version: 1, currentRoot, previousRoots: oldRoots, workspaceAliases }, MAX_MARKER);
  await checkpoint('marker-committed', { currentRoot });
  await unlinkDurable(planPath); await unlinkDurable(originPath);
  return { status: 'relocated', migrated: result.migrated, isolated: result.isolated, quarantineCounts: await quarantineCounts(work) };
}
