import { featuresOf } from "./capabilities.js";
import { CapabilityRuntime } from "./capability-runtime.js";
import { FilePickerRuntime } from "./file-picker-runtime.js";
// Native plugin routes (docs/design/native-plugins-protocol.md §4): contributions, views, invoke,
// assets and the stream. The caller (index.js) has already passed Connection's guard.
import { randomBytes } from "node:crypto";
import { readFile, realpath, stat } from "node:fs/promises";
import { extname, sep } from "node:path";
import { performance } from "node:perf_hooks";
import { normalize as normalizeEffects, splitPending } from "./effects.js";
import { ID, NEGOTIATED_PLACEMENTS, PKG, PROTOCOL, SEMVER } from "./limits.js";
import { insidePackage, panelTitle } from "./manifest.js";
import { acceptUpgrade } from "./ws.js";
import { LOCALE, call, errorText, isPlainObject, normalizeScope, toJson, utf8Bytes, viewStats, withTimeout } from "./util.js";

export const STREAM_PATH = "/dsh-go/v1/stream";
const BASE = "/dsh-go/v1/";
const SURFACE_KEYS = { "composer.actions": "composer.actions", "message.actions": "message.actions", "composer.strip": "composer.strip", panel: "panels", "composer.tools": "composer.tools", "session.actions": "session.actions" };
const CONTEXT_FOR = { "composer.actions": ["draft", "clipboard"], "composer.tools": ["draft", "clipboard"], "message.actions": ["message"] };
const IMAGE_TYPES = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".gif": "image/gif" };
const SUB_ID = /^.{1,32}$/su;

class HttpError extends Error {
  constructor(status, code, message, headers) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

function sendJson(res, status, body, headers = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "content-type": "application/json; charset=utf-8",
    ...headers,
  });
  res.end(text);
}

const fail = (status, code, message, headers) => { throw new HttpError(status, code, message, headers); };

function parseCaps(sp) {
  const versions = (sp.get("v") ?? "1").split(",").map((s) => Number(s.trim())).filter((n) => Number.isInteger(n) && n > 0);
  if (versions.length === 0) fail(400, "bad-request", "v must list protocol versions");
  if (!versions.includes(PROTOCOL)) fail(400, "unsupported-version", `bridge speaks v${PROTOCOL}`);
  const rawApp = sp.get("app") ?? "";
  const app = SEMVER.test(rawApp) ? rawApp : "0.0.0";
  const rawLocale = sp.get("locale") ?? "";
  const locale = rawLocale.length <= 35 && LOCALE.test(rawLocale) ? rawLocale : "";
  const list = (name) => (sp.get(name) ?? "").split(",").map((s) => s.trim()).filter((s) => s !== "" && s.length <= 64).slice(0, 64);
  const surfaces = list("surfaces");
  const components = list("components");
  const features = featuresOf(list("features"));
  const placements = surfaces.filter((s) => NEGOTIATED_PLACEMENTS.includes(s));
  return {
    versions,
    app,
    locale,
    surfaces,
    components,
    features,
    key: JSON.stringify([versions, app, locale.toLowerCase(), ...(features.length ? [features] : []), ...(placements.length ? [placements] : [])]),
    // Omitted lists preserve the SDK's v1 defaults; explicit empty lists stay empty.
    forPlugin: () => ({ protocol: PROTOCOL, app, locale,
      ...(sp.has("surfaces") ? { surfaces: [...surfaces] } : {}),
      ...(sp.has("components") ? { components: [...components] } : {}),
      ...(features.length ? { features: [...features] } : {}) }),
  };
}

/** `<pkg>/<rest...>` where a scoped package takes two segments. */
function splitPackagePath(rest) {
  let segs;
  try {
    segs = rest.split("/").map(decodeURIComponent);
  } catch {
    fail(400, "bad-request", "bad path encoding");
  }
  const n = segs[0]?.startsWith("@") ? 2 : 1;
  const pkg = segs.slice(0, n).join("/");
  if (segs.length <= n || !PKG.test(pkg)) fail(400, "bad-request", "path must be <pkg>/<...>");
  return { pkg, tail: segs.slice(n) };
}

function scopeFromQuery(sp) {
  const raw = {};
  for (const k of ["sessionId", "turnId", "messageId", "callId"]) if (sp.has(k)) raw[k] = sp.get(k);
  const scope = normalizeScope(raw);
  if (scope === undefined) fail(400, "bad-request", "invalid scope value");
  return scope;
}

function readJsonBody(req, limit) {
  return new Promise((resolve, reject) => {
    if (req.aborted || req.destroyed) return reject(new HttpError(400, "bad-request", "request body was interrupted"));
    const chunks = [];
    let size = 0;
    let over = false;
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) over = true;
      else if (!over) chunks.push(c);
    });
    req.on("end", () => {
      if (over) return reject(new HttpError(413, "too-large", `body exceeds ${limit} bytes`));
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        reject(new HttpError(400, "bad-request", "body is not JSON"));
      }
    });
    req.on("error", reject);
  });
}

export function createNativeRoutes(core, { beginUsage = () => () => {} } = {}) {
  const L = core.limits;
  const conns = new Set();
  const connById = new Map();
  const pendings = new Map();   // pending id -> {id, pkg, conn, controller, settled, timer}
  const capabilities = new CapabilityRuntime(core, fail);
  const files = new FilePickerRuntime(core, { fail, sendJson, readJsonBody });
  let disposed = false;
  const staticViews = new Map();   // file -> {stamp, view: normalized JSON value and byte size}

  const pluginOrFail = (pkg, caps) => {
    const rec = core.plugin(pkg);
    if (rec === undefined) fail(404, "not-found", `no enabled plugin ${pkg} declares dshGo`);
    const state = core.stateOf(rec, caps);
    if (state === "degraded") fail(409, "degraded", `${pkg} is degraded for this run`);
    if (state !== "ok") fail(409, "not-native", `${pkg} is ${state}`);
    return rec;
  };

  // Whether pkg is still the plugin load and registration that origin was taken from.
  const isCurrent = (pkg, kind, id, origin) => {
    const now = core.plugin(pkg);
    return !disposed && now !== undefined && core.stateOf(now) === "ok"
      && now.uid === origin.uid && now.stamp === origin.stamp
      && core.registration(pkg, kind, id)?.token === origin.token;
  };

  // -------------------------------------------------------------- contributions

  function contributions(req, res, url) {
    if (req.method !== "GET") fail(405, "method-not-allowed", "GET only");
    const caps = parseCaps(url.searchParams);
    const body = core.contributions(caps);
    const etag = `"${body.rev}"`;
    if (req.headers["if-none-match"] === etag) {
      res.writeHead(304, { etag, "cache-control": "no-store" });
      res.end();
      return;
    }
    sendJson(res, 200, body, { etag });
  }

  // -------------------------------------------------------------- views

  async function staticView(file) {
    let st;
    try {
      st = await stat(file);
    } catch {
      fail(500, "invalid-view", "static view file is missing");
    }
    const stamp = `${st.mtimeMs}:${st.size}`;
    const hit = staticViews.get(file);
    if (hit?.stamp === stamp) return hit.view;
    if (st.size > L.viewBytes) fail(500, "invalid-view", `static view exceeds ${L.viewBytes} bytes`);
    let view;
    try {
      view = JSON.parse(await readFile(file, "utf8"));
    } catch {
      fail(500, "invalid-view", "static view file is not JSON");
    }
    if (!isPlainObject(view)) fail(500, "invalid-view", "static view must be an object");
    const json = toJson(view);
    if (json && json.bytes > L.viewBytes) fail(500, "invalid-view", `static view exceeds ${L.viewBytes} bytes`);
    const normalized = json && { value: json.value, bytes: json.bytes };
    staticViews.set(file, { stamp, view: normalized });
    return normalized;
  }

  async function view(req, res, url, rest) {
    if (req.method !== "GET") fail(405, "method-not-allowed", "GET only");
    const caps = parseCaps(url.searchParams);
    const { pkg, tail } = splitPackagePath(rest);
    const id = tail.length === 1 ? tail[0] : "";
    if (!ID.test(id)) fail(400, "bad-request", "path must be views/<pkg>/<panel id>");
    const scope = scopeFromQuery(url.searchParams);
    const rec = pluginOrFail(pkg, caps);
    const item = rec.parsed.items.panels.find((p) => p.id === id);
    if (item === undefined) fail(404, "not-found", `${pkg} declares no panel ${id}`);
    const reg = core.registration(pkg, "panels", id);
    // Like invoke: a view or first data that finishes after a reload answers no-handler.
    const origin = { uid: rec.uid, stamp: rec.stamp, token: reg?.token };
    const requireCurrent = () => {
      if (!isCurrent(pkg, "panels", id, origin)) fail(409, "no-handler", "panel registration was unloaded or changed");
    };
    let viewJson;
    if (reg !== undefined) {
      let result;
      try {
        result = typeof reg.def.view === "function"
          ? await withTimeout(call(reg.def.view, { ...scope.scope }, caps.forPlugin()), L.viewTimeoutMs)
          : reg.def.view;
      } catch (error) {
        requireCurrent();
        core.violation(pkg, error?.timeout ? "timeout" : "plugin-error", `view(${id}): ${errorText(error)}`);
        if (error?.timeout) fail(504, "timeout", `view(${id}) took longer than ${L.viewTimeoutMs} ms`);
        fail(500, "plugin-error", `view(${id}) failed`);
      }
      requireCurrent();
      const json = isPlainObject(result) ? toJson(result) : undefined;
      if (json === undefined) {
        core.violation(pkg, "invalid-view", `view(${id}) is not a JSON object`);
        fail(500, "invalid-view", `view(${id}) is not a JSON object`);
      }
      if (json.bytes > L.viewBytes) {
        core.violation(pkg, "invalid-view", `view(${id}) is ${json.bytes} bytes (max ${L.viewBytes})`);
        fail(500, "invalid-view", `view(${id}) exceeds ${L.viewBytes} bytes`);
      }
      viewJson = json;
    } else if (item.viewFile !== undefined) {
      viewJson = await staticView(item.viewFile).finally(requireCurrent);
    } else {
      fail(409, "no-handler", `${pkg} has neither panel("${id}") nor a static view`);
    }
    const stats = { bytes: viewJson.bytes, ...viewStats(viewJson.value) };
    const issues = [];
    if (stats.nodes > L.viewNodes || stats.depth > L.viewDepth) {
      issues.push({ path: `/runtime/${id}`, code: "too-many", severity: "warn", message: `view has ${stats.nodes} nodes / depth ${stats.depth} (max ${L.viewNodes} / ${L.viewDepth}); the app truncates` });
    }
    let data = null;
    let rev = null;
    let live = false;
    if (typeof reg?.def.data === "function") {
      const feed = core.feed(pkg, id, "panel", scope, caps.locale);
      if (feed !== undefined) {
        feed.pin();
        try {
          await feed.waitFirst(L.firstDataWaitMs);
        } finally {
          feed.unpin();
        }
        requireCurrent();
        if (feed.data !== undefined) {
          data = feed.data;
          rev = feed.rev;
        }
        live = !feed.stopped;
      }
    }
    core.success(pkg);
    sendJson(res, 200, { v: PROTOCOL, pkg, id, title: panelTitle(item, caps.locale), view: viewJson.value, data, rev, live, stats, issues });
  }

  // -------------------------------------------------------------- invoke

  async function invoke(req, res) {
    if (req.method !== "POST") fail(405, "method-not-allowed", "POST only");
    if (String(req.headers["content-type"]).split(";", 1)[0].trim().toLowerCase() !== "application/json") {
      req.resume();
      fail(415, "unsupported-media-type", "content-type must be application/json");
    }
    const body = await readJsonBody(req, L.invokeBytes);
    if (!isPlainObject(body)) fail(400, "bad-request", "body must be an object");
    if (body.v !== PROTOCOL) fail(400, Number.isInteger(body.v) ? "unsupported-version" : "bad-request", `v must be ${PROTOCOL}`);
    if (typeof body.pkg !== "string" || !PKG.test(body.pkg)) fail(400, "bad-request", "pkg is not a package name");
    if (typeof body.id !== "string" || !ID.test(body.id)) fail(400, "bad-request", "id is not an id");
    const surfaceKey = SURFACE_KEYS[body.surface];
    if (surfaceKey === undefined) fail(400, "bad-request", "surface must be composer.actions, message.actions, composer.strip or panel");
    const isPanel = body.surface === "panel";
    if (body.action !== undefined && (!isPanel || typeof body.action !== "string" || body.action.length < 1 || body.action.length > 64)) fail(400, "bad-request", "action is a 1-64 character string, panel only");
    if (body.value !== undefined) {
      if (!isPanel) fail(400, "bad-request", "value is panel only");
      const json = toJson(body.value);
      if (json === undefined || json.bytes > L.invokeValueBytes) fail(413, "too-large", `value exceeds ${L.invokeValueBytes} bytes`);
    }
    const scope = normalizeScope(body.scope);
    if (scope === undefined) fail(400, "bad-request", "invalid scope");
    if (body.context !== undefined && !isPlainObject(body.context)) fail(400, "bad-request", "context must be an object");
    for (const [k, v] of Object.entries(body.context ?? {})) {
      if (typeof v !== "string") fail(400, "bad-request", `context.${k} must be a string`);
      if (utf8Bytes(v) > L.contextFieldBytes) fail(413, "too-large", `context.${k} exceeds ${L.contextFieldBytes} bytes`);
    }
    const locale = typeof body.locale === "string" && body.locale.length <= 35 && LOCALE.test(body.locale) ? body.locale : "";
    if (body.stream !== undefined && (typeof body.stream !== "string" || body.stream.length > 64)) fail(400, "bad-request", "stream must be the welcome.conn string");
    if (body.userGesture !== undefined && typeof body.userGesture !== "boolean") fail(400, "bad-request", "userGesture must be a boolean");

    const rec = pluginOrFail(body.pkg);
    const item = rec.parsed.items[surfaceKey]?.find((x) => x.id === body.id);
    if (item === undefined) fail(404, "not-found", `${body.pkg} declares no ${body.surface} ${body.id}`);
    const capabilityConn = connById.get(body.stream);
    if (!(item.requires ?? []).every(x => capabilityConn?.features?.includes(x))) fail(409, "unsupported", "action requires negotiated capabilities");
    if (item.effect !== undefined) fail(409, "no-handler", `${body.id} has a static effect; the app runs it without invoke`);
    const panel = isPanel ? core.registration(body.pkg, "panels", body.id) : undefined;
    const handler = core.registration(body.pkg, "handlers", body.id);
    let kind = "panels", registration = panel;
    let fn = isPanel && body.action !== undefined ? panel?.def.actions?.[body.action] : undefined;
    if (fn == null) { kind = "handlers"; registration = handler; fn = handler?.def; }
    if (typeof fn !== "function") fail(409, "no-handler", `no handler for ${body.id}${body.action ? `/${body.action}` : ""}`);
    // Bind all results (not only file capabilities) to this exact registration.
    const origin = { uid: rec.uid, stamp: rec.stamp, token: registration.token };
    const current = () => isCurrent(body.pkg, kind, body.id, origin);
    const rejectStale = () => {
      controller.abort();
      return sendJson(res, 200, { v: PROTOCOL, effects: [], issues: [{ path: "/runtime/effects", code: "bad-effect", severity: "warn", message: "invocation registration was unloaded or changed" }] });
    };
    // An action may explicitly patch a different panel; don't patch its replacement either.
    const targets = new Map(rec.parsed.items.panels.map(p => [p.id, core.registration(body.pkg, "panels", p.id)?.token]));
    const filterPatches = norm => {
      norm.effects = norm.effects.filter(effect => {
        if (effect.type !== "patch" || core.registration(body.pkg, "panels", effect.id)?.token === targets.get(effect.id)) return true;
        norm.issues.push({ path: "/runtime/effects", code: "bad-effect", severity: "warn", message: "patch target registration was unloaded or changed" });
        return false;
      });
    };
    // Freeze file authority before user code runs (including its synchronous prefix).
    // A result from this invocation cannot acquire a replacement registration's callback.
    const fileInvocation = rec.parsed.capabilities?.includes("files")
      ? files.captureInvocation(rec, { kind, registration, panel, handler }) : undefined;

    const release = core.admitInvoke(body.pkg);
    if (release === undefined) fail(429, "rate-limited", "too many invokes", { "retry-after": String(core.retryAfter(body.pkg)) });
    const allowed = (CONTEXT_FOR[body.surface] ?? []).filter((k) => rec.parsed.wants.includes(k));
    const arg = { ...scope.scope };
    for (const k of allowed) if (typeof body.context?.[k] === "string") arg[k] = body.context[k];
    const controller = new AbortController();
    const event = { surface: body.surface, id: body.id, locale, signal: controller.signal };
    if (body.action !== undefined) event.action = body.action;
    if (body.value !== undefined) event.value = body.value;
    const settleUsage = beginUsage();
    let result, deferred;
    try {
      ({ result, deferred } = await withTimeout(call(fn, arg, event).then(result => {
        const deferred = splitPending(result);
        // Own eager work even if the outer handler finishes after its deadline.
        // Assimilate a thenable once; later delivery consumes this same Promise.
        // Never start lazy work, and never mutate the plugin's result object.
        const work = deferred?.ok ? deferred.work : deferred ? result.result : undefined;
        if (typeof work !== "function" && typeof work?.then === "function") {
          const owned = Promise.resolve(work);
          owned.then(undefined, () => {});
          if (deferred.ok) deferred.work = owned;
        }
        return { result, deferred };
      }), L.handlerTimeoutMs));
    } catch (error) {
      settleUsage(current() ? 2 : 4);
      controller.abort();
      if (!current()) return rejectStale();
      core.violation(body.pkg, error?.timeout ? "timeout" : "plugin-error", `on(${body.id}): ${errorText(error)}`);
      if (error?.timeout) fail(504, "timeout", `handler took longer than ${L.handlerTimeoutMs} ms`);
      fail(500, "plugin-error", "handler failed");
    } finally {
      release();
    }
    const panels = new Set(rec.parsed.items.panels.map((p) => p.id));
    if (!current()) { settleUsage(4); return rejectStale(); }
    if (deferred !== undefined) {
      return startPending(res, { settleUsage, pkg: body.pkg, id: body.id, streamId: body.stream, scope, panels, source: isPanel ? body.id : undefined, controller, deferred, current, filterPatches });
    }
    const norm = normalizeEffects(result, { panels, source: isPanel ? body.id : undefined, capabilities: capabilities.options(rec, capabilityConn), userGesture: body.userGesture === true });
    if (!current()) return rejectStale();
    filterPatches(norm);
    norm.effects = capabilities.bind(norm.effects, rec, capabilityConn, scope, locale, norm.issues);
    norm.effects = files.bind(norm.effects, rec, capabilityConn, scope, locale, body, norm.issues, fileInvocation);
    settleUsage(norm.violation ? 2 : 1);
    if (norm.violation) core.violation(body.pkg, "bad-effect", `on(${body.id}) returned invalid effects: ${norm.issues.map((i) => i.message).join("; ").slice(0, 200)}`);
    else core.success(body.pkg);
    for (const e of norm.effects) if (e.type === "patch") core.patchFeed(body.pkg, e.id, scope, e.data);
    sendJson(res, 200, { v: PROTOCOL, effects: norm.effects, issues: norm.issues });
  }

  // -------------------------------------------------------------- deferred results (§4.7)

  function startPending(res, { settleUsage, pkg, id, streamId, scope, panels, source, controller, deferred, current, filterPatches }) {
    // A refused deferred result must not leave an eager rejected Promise unhandled.
    const swallow = () => { if (typeof deferred.work?.then === "function") deferred.work.then(undefined, () => {}); };
    if (!deferred.ok) {
      settleUsage(2);
      swallow();
      controller.abort();
      core.violation(pkg, "bad-effect", `on(${id}): ${deferred.issues[0].message}`);
      return sendJson(res, 200, { v: PROTOCOL, effects: [], issues: deferred.issues });
    }
    const conn = typeof streamId === "string" ? connById.get(streamId) : undefined;
    if (conn === undefined || conn.ws.closed) {
      settleUsage(4);
      swallow();
      controller.abort();
      fail(409, "no-stream", "a deferred result needs an open stream: pass welcome.conn as `stream`");
    }
    let active = 0;
    for (const p of pendings.values()) if (p.pkg === pkg) active++;
    if (active >= L.pendingPerPlugin) {
      settleUsage(4);
      swallow();
      controller.abort();
      fail(429, "too-many-pending", `at most ${L.pendingPerPlugin} pending results per plugin`, { "retry-after": "1" });
    }
    core.success(pkg);
    const entry = { id: `p${randomBytes(8).toString("hex")}`, pkg, conn, controller, current, settleUsage, settled: false, timer: undefined };
    pendings.set(entry.id, entry);
    conn.pendings.add(entry.id);
    entry.timer = setTimeout(() => settle(entry, { t: "void", reason: "timeout" }), deferred.timeoutMs);
    entry.timer.unref?.();
    let responded;
    const gate = new Promise((resolve) => { responded = resolve; });
    const work = typeof deferred.work === "function" ? call(deferred.work, controller.signal) : Promise.resolve(deferred.work);
    work.then(async (value) => {
      await gate;
      if (entry.settled) return;   // expired, cancelled or disconnected: the late result is dropped
      if (!current()) return settle(entry, { t: "void", reason: "cancelled" });
      const norm = normalizeEffects(value, { panels, source, deferred: true });
      if (!current()) return settle(entry, { t: "void", reason: "cancelled" });
      filterPatches(norm);
      if (norm.violation) core.violation(pkg, "bad-effect", `deferred on(${id}) returned invalid effects: ${norm.issues.map((i) => i.message).join("; ").slice(0, 200)}`);
      else core.success(pkg);
      for (const e of norm.effects) if (e.type === "patch") core.patchFeed(pkg, e.id, scope, e.data);
      settle(entry, { t: "done", effects: norm.effects, ...(norm.issues.length > 0 ? { issues: norm.issues } : {}) }, false, norm.violation ? 2 : 1);
    }, async (error) => {
      await gate;
      if (entry.settled) return;
      if (!current()) return settle(entry, { t: "void", reason: "cancelled" });
      core.ctx.logger?.warn?.("dsh-go-bridge: deferred %s/%s failed: %s", pkg, id, errorText(error));
      settle(entry, { t: "void", reason: "error" });
    });
    const pending = { id: entry.id, timeoutMs: deferred.timeoutMs };
    if (deferred.label !== undefined) pending.label = deferred.label;
    sendJson(res, 200, { v: PROTOCOL, effects: [], pending, issues: deferred.issues });
    responded();
  }

  /** Each pending id settles exactly once; only its own connection hears about it. */
  function settle(entry, msg, abort = true, outcome = msg.reason === "cancelled" ? 3 : 2) {
    if (entry.settled) return;
    entry.settled = true;
    entry.settleUsage(outcome);
    clearTimeout(entry.timer);
    pendings.delete(entry.id);
    entry.conn.pendings.delete(entry.id);
    if (abort) entry.controller.abort();
    entry.conn.send({ ...msg, pending: entry.id });
  }

  function dropPendings(conn) {
    for (const pid of conn.pendings) {
      const e = pendings.get(pid);
      if (e === undefined) continue;
      e.settled = true;
      e.settleUsage(4);
      clearTimeout(e.timer);
      pendings.delete(pid);
      e.controller.abort();
    }
    conn.pendings.clear();
  }

  // -------------------------------------------------------------- assets

  async function asset(req, res, rest) {
    if (req.method !== "GET" && req.method !== "HEAD") fail(405, "method-not-allowed", "GET only");
    const { pkg, tail } = splitPackagePath(rest);
    if (tail.some((s) => s === "" || s === "." || s === ".." || s.includes("/") || s.includes("\\") || s.includes("\0"))) fail(404, "not-found", "no such asset");
    const rec = core.plugin(pkg);
    if (rec?.parsed.assetsDir === undefined) fail(404, "not-found", "no such asset");
    const type = IMAGE_TYPES[extname(tail[tail.length - 1]).toLowerCase()];
    if (type === undefined) fail(404, "not-found", "no such asset");
    let file = insidePackage(rec.parsed.assetsDir, tail.join("/"));
    let st;
    try {
      if (file === undefined) throw new Error();
      const [real, realDir] = await Promise.all([realpath(file), realpath(rec.parsed.assetsDir)]);
      if (!real.startsWith(realDir + sep)) throw new Error();
      file = real;
      st = await stat(file);
      if (!st.isFile() || st.size > L.assetBytes) throw new Error();
    } catch {
      fail(404, "not-found", "no such asset");
    }
    const etag = `"${st.size.toString(36)}-${Math.floor(st.mtimeMs).toString(36)}"`;
    const headers = { "content-type": type, "cache-control": "private, max-age=300", etag, "x-content-type-options": "nosniff" };
    if (req.headers["if-none-match"] === etag) {
      res.writeHead(304, headers);
      res.end();
      return;
    }
    const bytes = await readFile(file);
    if (bytes.length > L.assetBytes) fail(404, "not-found", "no such asset");
    res.writeHead(200, { ...headers, "content-length": bytes.length });
    res.end(req.method === "HEAD" ? undefined : bytes);
  }

  // -------------------------------------------------------------- stream

  const offChanged = core.onChanged(() => {
    for (const entry of [...pendings.values()]) if (!entry.current()) settle(entry, { t: "void", reason: "cancelled" });
    for (const c of conns) if (c.helloed) c.send({ t: "changed" });
  });

  function upgrade(req, socket, head) {
    const ws = acceptUpgrade(req, socket, head, { maxMessage: L.streamInboundFrameBytes });
    if (ws === undefined) return;
    const openedAt = performance.now();
    const conn = { id: randomBytes(12).toString("base64url"), ws, helloed: false, subs: new Map(), pendings: new Set(), lastRecv: openedAt, openedAt };
    conn.send = (msg) => {
      if (ws.closed) return;
      if (ws.bufferedAmount > L.streamBacklogBytes) {
        ws.close(1013, "backlog");
        return;
      }
      ws.send(JSON.stringify(msg));
    };
    if (conns.size >= L.streamConnections) {
      ws.close(1013, "too many connections");
      return;
    }
    conns.add(conn);
    connById.set(conn.id, conn);
    const hb = setInterval(() => {
      const now = performance.now();
      if (now - conn.lastRecv > L.idleTimeoutSeconds * 1000) return ws.close(1001, "idle");
      if (!conn.helloed && now - conn.openedAt > 10000) return ws.close(1008, "hello expected");
      ws.ping();
    }, L.heartbeatSeconds * 1000);
    hb.unref?.();
    ws.on("activity", () => { conn.lastRecv = performance.now(); });
    ws.on("close", () => {
      clearInterval(hb);
      conns.delete(conn);
      connById.delete(conn.id);
      dropPendings(conn);
      files.drop(conn);
      capabilities.drop(conn);
      for (const sub of conn.subs.values()) sub.feed?.detach(sub);
      conn.subs.clear();
    });
    ws.on("message", (text) => {
      let msg;
      try {
        msg = JSON.parse(text);
      } catch {
        return ws.close(1008, "not JSON");
      }
      if (!isPlainObject(msg) || typeof msg.t !== "string") return ws.close(1008, "not a message");
      try {
        onMessage(conn, msg);
      } catch (error) {
        core.ctx.logger?.warn?.(error);
        ws.close(1011, "internal error");
      }
    });
  }

  function onMessage(conn, msg) {
    if (!conn.helloed) {
      if (msg.t !== "hello") return conn.ws.close(1008, "hello expected");
      if (!Array.isArray(msg.v) || !msg.v.includes(PROTOCOL)) {
        conn.send({ t: "error", code: "unsupported-version", message: `bridge speaks v${PROTOCOL}` });
        return conn.ws.close(1008, "unsupported version");
      }
      conn.helloed = true;
      conn.features = featuresOf(msg.features);
      conn.locale = typeof msg.locale === "string" && msg.locale.length <= 35 && LOCALE.test(msg.locale) ? msg.locale : "";
      conn.send({ t: "welcome", v: PROTOCOL, bridge: core.version, hb: L.heartbeatSeconds, conn: conn.id, ...(Array.isArray(msg.features) ? { features: conn.features } : {}) });
      return;
    }
    if (capabilities.message(conn, msg)) return;
    switch (msg.t) {
      case "sub": return subscribe(conn, msg);
      case "unsub": {
        const sub = typeof msg.sub === "string" ? conn.subs.get(msg.sub) : undefined;
        if (sub !== undefined) {
          conn.subs.delete(msg.sub);
          sub.feed?.detach(sub);
        }
        return;
      }
      case "cancel": {
        const e = typeof msg.pending === "string" ? pendings.get(msg.pending) : undefined;
        if (e !== undefined && e.conn === conn) settle(e, { t: "void", reason: "cancelled" });
        return;
      }
      case "ping": return conn.send(typeof msg.at === "number" ? { t: "pong", at: msg.at } : { t: "pong" });
      default: return;   // unknown types are ignored (forward compatible)
    }
  }

  function subscribe(conn, msg) {
    const bad = (message) => conn.send({ t: "error", code: "bad-request", message });
    if (typeof msg.sub !== "string" || !SUB_ID.test(msg.sub)) return bad("sub must be a 1-32 character string");
    if (typeof msg.pkg !== "string" || !PKG.test(msg.pkg)) return bad("pkg is not a package name");
    if (typeof msg.id !== "string" || !ID.test(msg.id)) return bad("id is not an id");
    if (msg.rev !== undefined && (typeof msg.rev !== "string" || msg.rev.length > 64)) return bad("rev must be a string");
    const scope = normalizeScope(msg.scope);
    if (scope === undefined) return bad("invalid scope");
    const old = conn.subs.get(msg.sub);
    if (old !== undefined) {
      conn.subs.delete(msg.sub);
      old.feed?.detach(old);
    }
    const end = (reason) => conn.send({ t: "end", sub: msg.sub, reason });
    if (conn.subs.size >= L.streamSubscriptions) return end("limit");
    const rec = core.plugin(msg.pkg);
    if (rec === undefined) return end("not-found");
    const state = core.stateOf(rec);
    if (state === "degraded") return end("degraded");
    if (state !== "ok") return end("not-native");
    const declared = rec.parsed.ids.get(msg.id);
    if (declared !== "panels" && declared !== "composer.strip" && declared !== "turn.note") return end("not-found");
    // A turn's note belongs to a conversation.
    if (declared === "turn.note" && scope.scope.sessionId === undefined) return end("not-found");
    const feed = core.feed(msg.pkg, msg.id, declared === "panels" ? "panel" : declared === "turn.note" ? "note" : "strip", scope, conn.locale);
    if (feed === undefined) return end("limit");
    const sub = {
      id: msg.sub,
      feed,
      send: (m) => conn.send(m),
      feedEnded: (f) => {
        if (conn.subs.get(msg.sub)?.feed === f) conn.subs.delete(msg.sub);
      },
    };
    conn.subs.set(msg.sub, sub);
    feed.attach(sub, msg.rev);
  }

  // -------------------------------------------------------------- dispatch

  /** Handles a /dsh-go/v1/<native route>; returns false for paths it does not own. */
  async function handle(req, res, path, url) {
    let route;
    if (path === `${BASE}contributions`) route = () => contributions(req, res, url);
    else if (path === `${BASE}invoke`) route = () => invoke(req, res);
    else if (path.startsWith(`${BASE}files/`)) route = () => files.handle(req, res, url, path.slice(`${BASE}files/`.length));
    else if (path.startsWith(`${BASE}views/`)) route = () => view(req, res, url, path.slice(`${BASE}views/`.length));
    else if (path.startsWith(`${BASE}media/`)) route = () => {
      const { pkg, tail } = splitPackagePath(path.slice(`${BASE}media/`.length));
      if (tail.length !== 1) fail(400, "bad-request", "media needs one id");
      return capabilities.media(req, res, url, pkg, tail[0]);
    };
    else if (path.startsWith(`${BASE}assets/`)) route = () => asset(req, res, path.slice(`${BASE}assets/`.length));
    else return false;
    try {
      await route();
    } catch (error) {
      if (!(error instanceof HttpError)) {
        core.ctx.logger?.warn?.(error);
        error = new HttpError(500, "plugin-error", "internal error");
      }
      if (!res.headersSent) sendJson(res, error.status, { v: PROTOCOL, error: { code: error.code, message: error.message } }, error.headers);
      else res.destroy();
    }
    return true;
  }

  function dispose() {
    disposed = true;
    offChanged();
    capabilities.dispose();
    files.dispose();
    for (const c of conns) dropPendings(c);
    for (const c of [...conns]) c.ws.close(1001, "bridge stopping");
  }

  return { handle, upgrade, dispose, connections: () => conns.size };
}
