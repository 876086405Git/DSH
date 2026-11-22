import { EVENT_TYPES } from "./state.js";

export const MAX_MEMORIES = 256;
export const MAX_FILE_BYTES = 1024 * 1024;
export const MAX_BODY_BYTES = 16 * 1024;
export const MAX_TIME = Number.MAX_SAFE_INTEGER - 24 * 60 * 60 * 1000;
export const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
export const integer = (value) => Number.isSafeInteger(value) && value >= 0;
const time = integer;
const nullableTime = (value) => value === null || time(value);
export const uuid = (value) => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
export const codePoints = (text) => [...text].length;

export class CompanionError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = `companion/${code}`;
  }
}
export const invalid = () => new CompanionError(400, "invalid-request", "Invalid companion request");
export const corrupt = () => new CompanionError(503, "corrupt-store", "Companion store requires recovery");
export const ioError = () => new CompanionError(500, "io-error", "Companion storage operation failed");

export function fields(value, required, optional = []) {
  return isObject(value) && required.every((key) => Object.hasOwn(value, key))
    && Object.keys(value).every((key) => required.includes(key) || optional.includes(key));
}

function boundedText(value, max, { empty = false, multiline = false } = {}) {
  if (typeof value !== "string" || codePoints(value) > max || (!empty && value.trim() === "")) return false;
  if ((multiline ? /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/ : /[\u0000-\u001f\u007f]/).test(value)) return false;
  // JSON permits isolated UTF-16 surrogates; they are not Unicode scalar values.
  return [...value].every((part) => { const cp = part.codePointAt(0); return cp < 0xd800 || cp > 0xdfff; });
}

export function validMemory(value, stored = false) {
  const keys = ["id", "kind", "text", "keywords", "pinned", "source", "expiresAt"];
  if (stored) keys.push("createdAt", "updatedAt");
  if (!fields(value, keys) || !uuid(value.id) || !["fact", "preference", "episode"].includes(value.kind)
    || !boundedText(value.text, 512, { multiline: true }) || typeof value.pinned !== "boolean"
    || !Array.isArray(value.keywords) || value.keywords.length > 8
    || !value.keywords.every((keyword) => boundedText(keyword, 24))
    || !nullableTime(value.expiresAt)) return false;
  if (!fields(value.source, ["kind"], ["sessionId", "messageId"])
    || !["manual", "user-confirmed"].includes(value.source.kind)) return false;
  for (const key of ["sessionId", "messageId"]) {
    if (Object.hasOwn(value.source, key) && (typeof value.source[key] !== "string"
      || value.source[key].length > 128 || !boundedText(value.source[key], 128))) return false;
  }
  return !stored || (time(value.createdAt) && time(value.updatedAt) && value.createdAt <= value.updatedAt);
}

export function validDocument(value) {
  if (!fields(value, ["v", "storeId", "companionId", "revision", "memoryRevision", "state", "memories"])
    || value.v !== 1 || value.companionId !== "whale-girl" || !uuid(value.storeId)
    || !integer(value.revision) || !integer(value.memoryRevision) || value.memoryRevision > value.revision
    || !Array.isArray(value.memories) || value.memories.length > MAX_MEMORIES
    || !value.memories.every((memory) => validMemory(memory, true))
    || new Set(value.memories.map((memory) => memory.id.toLowerCase())).size !== value.memories.length) return false;
  const s = value.state;
  return fields(s, ["valence", "energy", "closeness", "activity", "activityUntil", "lastVisitAt", "lastInteractionAt", "anchorAt", "lastGainAt", "lastEvents"])
    && [s.valence, s.energy, s.closeness].every((n) => Number.isFinite(n) && n >= 0 && n <= 1)
    && ["idle", "snack", "play", "rest"].includes(s.activity)
    && nullableTime(s.activityUntil) && ((s.activity === "idle") === (s.activityUntil === null))
    && time(s.anchorAt) && s.anchorAt <= MAX_TIME && [s.lastVisitAt, s.lastInteractionAt, s.lastGainAt].every((at) => nullableTime(at) && (at === null || at <= s.anchorAt))
    && fields(s.lastEvents, EVENT_TYPES) && Object.values(s.lastEvents).every((at) => nullableTime(at) && (at === null || at <= s.anchorAt));
}

export function validateWrite(input, required) {
  if (!fields(input, ["storeId", "expectedRevision", ...required]) || !uuid(input.storeId) || !integer(input.expectedRevision)) throw invalid();
}

export function validateContext(input) {
  if (!fields(input, [], ["query", "limit"]) || (input.query !== undefined && !boundedText(input.query, 256, { empty: true, multiline: true }))
    || (input.limit !== undefined && (!integer(input.limit) || input.limit < 1 || input.limit > 12))) throw invalid();
  return { query: input.query ?? "", limit: input.limit ?? 6 };
}
