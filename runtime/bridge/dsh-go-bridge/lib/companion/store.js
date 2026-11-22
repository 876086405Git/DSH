import * as fs from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { applyEvent, EVENT_TYPES, initialState, publicState } from "./state.js";
import { selectRecallContext } from "./recall-selector.js";
import { CompanionError, MAX_FILE_BYTES, MAX_MEMORIES, MAX_TIME, codePoints, corrupt,
  invalid, ioError, uuid, validDocument, validMemory, validateContext, validateWrite } from "./schema.js";

// Includes separate bridge instances in this process. This is not an inter-process lock.
const queues = new Map();
function serialized(key, operation) {
  const result = (queues.get(key) ?? Promise.resolve()).then(operation);
  const tail = result.then(() => {}, () => {});
  queues.set(key, tail);
  void tail.then(() => { if (queues.get(key) === tail) queues.delete(key); });
  return result;
}

const envelope = (doc) => ({ v: 1, storeId: doc.storeId, revision: doc.revision, memoryRevision: doc.memoryRevision });
const capabilities = Object.freeze({ persistence: "host", memories: true, context: true, export: true,
  automaticRecall: false, automaticExtraction: false });
const snapshot = (doc, now) => ({ ...envelope(doc), companionId: doc.companionId,
  capabilities: { ...capabilities }, asOf: Math.max(now, doc.state.anchorAt), state: publicState(doc.state, now) });
const normalize = (text) => text.normalize("NFKC").toLowerCase();
const copy = (value) => structuredClone(value);

function selectContext(doc, query, limit, now) {
  const search = normalize(query).trim();
  const candidates = doc.memories.filter((m) => m.expiresAt === null || m.expiresAt > now).map((memory) => {
    const text = normalize(memory.text);
    const keywordMatches = search === "" ? 0 : memory.keywords.filter((keyword) => search.includes(normalize(keyword))).length;
    const textMatch = search !== "" && text.includes(search);
    return { memory, score: keywordMatches * 2 + Number(textMatch) };
  });
  const order = (a, b) => b.score - a.score || b.memory.updatedAt - a.memory.updatedAt || a.memory.id.localeCompare(b.memory.id);
  const matches = candidates.filter((item) => item.score > 0).sort(order);
  const background = candidates.filter((item) => item.score === 0 && item.memory.pinned).sort(order).slice(0, 2);
  const eligible = [...matches, ...background];
  const memories = [];
  let textCodePoints = 0;
  let truncated = false;
  for (const { memory } of eligible) {
    const length = codePoints(memory.text);
    if (memories.length >= limit || textCodePoints + length > 2048) { truncated = true; continue; }
    memories.push(memory);
    textCodePoints += length;
  }
  // Expiry changes retrieval without a write/revision. Clients should fetch each turn;
  // this boundary also prevents a revision-only cache from serving expired records.
  const expiries = candidates.map(({ memory }) => memory.expiresAt).filter((at) => at !== null);
  return { ...envelope(doc), memories, truncated, textCodePoints,
    nextExpiryAt: expiries.length === 0 ? null : Math.min(...expiries) };
}

export function createCompanionStore({ filePath, now = Date.now, io = fs } = {}) {
  const home = process.env.DSH_HOME?.trim() || join(homedir(), ".dsh");
  // Keep private memories outside dsh-go/: reset's existing "UI and skills" option
  // retains that whole directory and must not silently retain personal memories too.
  const path = resolve(filePath ?? join(home, "companion", "state.json"));
  function clock() {
    const at = now();
    if (!Number.isSafeInteger(at) || at < 0 || at > MAX_TIME) throw new CompanionError(503, "unavailable", "Companion clock is unavailable");
    return at;
  }

  async function write(doc) {
    if (!validDocument(doc)) throw corrupt();
    const data = JSON.stringify(doc);
    if (Buffer.byteLength(data) > MAX_FILE_BYTES) throw new CompanionError(413, "too-large", "Companion store size limit reached");
    const directory = dirname(path);
    let temporary = join(directory, `.state-${randomUUID()}.tmp`);
    let handle;
    try {
      await io.mkdir(directory, { recursive: true, mode: 0o700 });
      handle = await io.open(temporary, "wx", 0o600);
      await handle.writeFile(data, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      await io.rename(temporary, path);
      temporary = undefined;
    } catch {
      throw ioError();
    } finally {
      if (handle !== undefined) await handle.close().catch(() => {});
      if (temporary !== undefined) await io.unlink(temporary).catch(() => {});
    }
  }

  async function read(at) {
    let handle;
    try {
      handle = await io.open(path, "r");
      const stat = await handle.stat();
      if (!stat.isFile() || stat.size > MAX_FILE_BYTES) throw corrupt();
      // Bounded even if an external editor grows the file after stat().
      let buffer = Buffer.alloc(stat.size + 1);
      let size = 0;
      while (size < buffer.length) {
        const { bytesRead } = await handle.read(buffer, size, buffer.length - size, size);
        if (bytesRead === 0) break;
        size += bytesRead;
        if (size === buffer.length && size <= MAX_FILE_BYTES) {
          const expanded = Buffer.alloc(MAX_FILE_BYTES + 1);
          buffer.copy(expanded);
          buffer = expanded;
        }
      }
      if (size > MAX_FILE_BYTES) throw corrupt();
      let doc;
      try { doc = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, size))); }
      catch { throw corrupt(); }
      if (!validDocument(doc)) throw corrupt();
      return doc;
    } catch (error) {
      if (error?.code === "ENOENT") {
        const doc = { v: 1, storeId: randomUUID(), companionId: "whale-girl", revision: 0,
          memoryRevision: 0, state: initialState(at), memories: [] };
        await write(doc);
        return doc;
      }
      if (error instanceof CompanionError) throw error;
      throw ioError();
    } finally {
      if (handle !== undefined) await handle.close().catch(() => {});
    }
  }

  function transaction(operation) {
    return serialized(path, async () => {
      const at = clock();
      const doc = await read(at);
      return operation(doc, at);
    });
  }
  function checkVersion(doc, input) {
    if (doc.storeId.toLowerCase() !== input.storeId.toLowerCase()) throw new CompanionError(409, "store-changed", "Companion store changed; reload before writing");
    if (doc.revision !== input.expectedRevision) throw new CompanionError(409, "conflict", "Companion revision changed; reload before writing");
  }
  async function commit(doc, memoryChanged = false) {
    if (doc.revision === Number.MAX_SAFE_INTEGER || (memoryChanged && doc.memoryRevision === Number.MAX_SAFE_INTEGER)) {
      throw new CompanionError(503, "unavailable", "Companion revision limit reached");
    }
    doc.revision++;
    if (memoryChanged) doc.memoryRevision++;
    await write(doc);
  }

  return {
    // Internal recall seam: same transaction, schema and authoritative clock
    // as CRUD. Keep the legacy /context selector and wire response unchanged.
    now: clock,
    getRecallContext() {
      return transaction((doc, at) => ({ ...envelope(doc), storeId: doc.storeId.toLowerCase(),
        asOf: at, ...selectRecallContext(doc.memories, at) }));
    },
    getSnapshot() { return transaction((doc, at) => snapshot(doc, at)); },
    getMemories() { return transaction((doc) => ({ ...envelope(doc), memories: doc.memories })); },
    getContext(input) {
      const { query, limit } = validateContext(input);
      return transaction((doc, at) => selectContext(doc, query, limit, at));
    },
    exportData() {
      return transaction((doc, at) => ({ schema: "dsh-go/companion-export", ...snapshot(doc, at),
        exportedAt: at, memories: doc.memories }));
    },
    event(input) {
      validateWrite(input, ["type"]);
      if (!EVENT_TYPES.includes(input.type)) throw invalid();
      input = { ...input };
      return transaction(async (doc, at) => {
        checkVersion(doc, input);
        const state = applyEvent(doc.state, input.type, at);
        if (state !== null) { doc.state = state; await commit(doc); }
        return { ...snapshot(doc, at), eventApplied: state !== null };
      });
    },
    upsertMemory(input) {
      validateWrite(input, ["memory"]);
      if (!validMemory(input.memory)) throw invalid();
      // Detach before queuing: callers cannot mutate a pending request after validation.
      const memory = copy(input.memory);
      memory.id = memory.id.toLowerCase();
      const version = { storeId: input.storeId, expectedRevision: input.expectedRevision };
      return transaction(async (doc, at) => {
        checkVersion(doc, version);
        const index = doc.memories.findIndex((m) => m.id.toLowerCase() === memory.id);
        if (index < 0 && doc.memories.length >= MAX_MEMORIES) throw new CompanionError(409, "limit-reached", "Companion memory limit reached");
        const previous = index < 0 ? undefined : doc.memories[index];
        const record = { ...memory, createdAt: previous?.createdAt ?? at,
          updatedAt: Math.max(at, previous?.updatedAt ?? 0) };
        // A full replacement with identical content is a no-op, including timestamps.
        const unchanged = previous && ["kind", "text", "pinned", "expiresAt"].every((key) => previous[key] === memory[key])
          && JSON.stringify(previous.keywords) === JSON.stringify(memory.keywords)
          && ["kind", "sessionId", "messageId"].every((key) => previous.source[key] === memory.source[key]);
        if (unchanged) {
          return { ...envelope(doc), memory: copy(previous) };
        }
        if (index < 0) doc.memories.push(record);
        else doc.memories[index] = record;
        await commit(doc, true);
        return { ...envelope(doc), memory: copy(record) };
      });
    },
    deleteMemory(input) {
      validateWrite(input, ["id"]);
      if (!uuid(input.id)) throw invalid();
      input = { ...input };
      return transaction(async (doc) => {
        checkVersion(doc, input);
        const index = doc.memories.findIndex((m) => m.id.toLowerCase() === input.id.toLowerCase());
        if (index < 0) return { ...envelope(doc), deleted: false };
        doc.memories.splice(index, 1);
        await commit(doc, true);
        return { ...envelope(doc), deleted: true };
      });
    },
    clearMemories(input) {
      validateWrite(input, []);
      input = { ...input };
      return transaction(async (doc) => {
        checkVersion(doc, input);
        const deletedCount = doc.memories.length;
        if (deletedCount > 0) { doc.memories = []; await commit(doc, true); }
        return { ...envelope(doc), deletedCount };
      });
    },
  };
}
