// dsh-go-bridge, host half (docs/design/plugin-seams.md §5.2, §9.2).
//
//   GET  /dsh-go/v1/inventory   wire format v1: release, packages with browser halves, the last
//                               slot occupancy report and `routeGuard`, measured on every
//                               read (see probeGuard)
//   POST /dsh-go/v1/occupancy   the browser half reports the live slot composition of its page
//   GET  /dsh-go/v1/capabilities protocol major and implemented route families (not permissions)
//
//   /dsh-go/v1/{contributions,views,invoke,assets} + WS /dsh-go/v1/stream
//                               native plugin protocol v1 (docs/design/native-plugins-protocol.md),
//                               backed by the `dshGo` service plugins get with ctx.inject(['dshGo'])
//
// All routes require what /api requires (Connection's Host/Origin fence plus the browser cookie
// or an API credential), checked here as well as by the patched webserver. On a host whose
// webserver lacks the dsh-app route guard (a remote host that installed this package) it wraps
// every registered route with the same check, unless `guardRoutes: false`.
//
// Zero dependencies: the dsh-app runtime loads this file by absolute path, where no
// @deepseek-ai package resolves.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { STATUS_CODES, get as httpGet } from "node:http";
import { get as httpsGet } from "node:https";
import { createPluginConfig, pluginConfigUnavailable } from "./plugin-config.js";
import { injectPromiseWithResolvers } from "./web-promise.js";
import { createSessionDeletion, sessionDeletionUnavailable } from "./session-deletion.js";
import { createSpeechRoutes } from "./speech.js";
import { createUsage } from "./usage.js";
import { createCompanionRoutes } from "./companion/routes.js";
import { createCompanionPromptContext, FULL_PRESET } from './companion/prompt-context.js';
import { createCompanionStore } from "./companion/store.js";
import { createRecallCoordinator } from "./companion/recall.js";
import { createRecallContexts } from "./companion/recall-context.js";
import { createCompanionSignals } from "./companion/signals.js";
import { NativeCore } from "./native/core.js";
import { effectiveLimits } from "./native/limits.js";
import { STREAM_PATH, createNativeRoutes } from "./native/routes.js";

export const name = "dsh-go-bridge";

const PREFIX = "/dsh-go";
/** Unauthenticated canary route: the guard self-test expects it to be refused without credentials. */
const CANARY = "/dsh-go-guard-canary";
const GUARD_PROBE_TTL_MS = 10000;
const VERSION = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version;
const CAPABILITIES = [
  "inventory", "occupancy", "native-ui", "native-stream", "native-media", "native-files",
  "plugin-config", "session-deletion", "companion", "companion-prompt-context", "companion-recall", "companion-signals",
  "speech",
];
const ORIGINAL = Symbol.for("cordis.original");
const GUARDED = Symbol.for("dsh-go.guarded");
const DEFAULT_OPEN_ROUTES = ["exact /connect", "exact /oauth/callback"];
const MAX_BODY = 512 * 1024;
const MAX_SLOTS = 400;
const MAX_OCCUPANTS = 200;
const SLOT_KEY = /^[A-Za-z0-9_.:-]{1,128}$/;

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
const isOfficial = (pkg) => typeof pkg === "string" && pkg.startsWith("@deepseek-ai/");
const str = (v, max) => (typeof v === "string" && v.length <= max ? v : undefined);
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const int = (v) => Math.round(num(v));

/** `@scope/name/sub` -> `@scope/name`, `name/sub` -> `name`; paths and `cordis:` rows -> undefined. */
function packageOf(specifier) {
  if (typeof specifier !== "string" || specifier === "" || /^(\.|\/|file:|cordis:|[A-Za-z]:)/.test(specifier)) return undefined;
  const parts = specifier.split("/");
  return specifier.startsWith("@") ? (parts.length >= 2 ? `${parts[0]}/${parts[1]}` : undefined) : parts[0];
}

function cachePath() {
  const home = process.env.DSH_HOME?.trim() || join(homedir(), ".dsh");
  return join(home, "cache", "dsh-go-bridge", "occupancy.json");
}

/** A right pane tab type (`sidebar.right.pane.tab(.title)` occupants): what it is called, how it opens. */
function sanitizeTab(t) {
  if (!isObject(t)) return undefined;
  const id = str(t.id, 214);
  const kind = str(t.kind, 214);
  if (id === undefined || kind === undefined) return undefined;
  const guide = (Array.isArray(t.guide) ? t.guide.slice(0, 20) : []).filter(isObject).map((g) => {
    const entry = { id: str(g.id, 214) ?? "", order: int(g.order) };
    const title = str(g.title, 256);
    if (title !== undefined) entry.title = title;
    return entry;
  }).filter((g) => g.id !== "");
  const out = { id, kind, guide };
  const title = str(t.title, 256);
  if (title !== undefined) out.title = title;
  if (t.multiple === true) out.multiple = true;
  return out;
}

/** One occupant in wire format; entries the page could not attribute to a package are dropped. */
function sanitizeOccupant(o) {
  if (!isObject(o)) return undefined;
  const pkg = str(o.package, 214);
  if (pkg === undefined || pkg === "" || pkg === name) return undefined;
  const out = {
    package: pkg,
    cell: str(o.cell, 256) ?? "",
    order: int(o.order),
    official: isOfficial(pkg),
    priority: int(o.priority),
    active: o.active === true,
  };
  const label = str(o.label, 256);
  if (label !== undefined) out.label = label;
  const registrant = str(o.registrant, 214);
  if (registrant !== undefined) out.registrant = registrant;
  const tab = sanitizeTab(o.tab);
  if (tab !== undefined) out.tab = tab;
  return out;
}

/** Validated occupancy report, or a status code. */
function parseReport(body) {
  if (!isObject(body) || !isObject(body.slots)) return 400;
  const bootRev = str(body.bootRev, 128);
  if (bootRev === undefined) return 400;
  const keys = Object.keys(body.slots);
  if (keys.length > MAX_SLOTS) return 413;
  const slots = {};
  for (const key of keys) {
    const list = body.slots[key];
    if (!SLOT_KEY.test(key) || !Array.isArray(list) || list.length > MAX_OCCUPANTS) return 400;
    const occupants = list.map(sanitizeOccupant).filter((o) => o !== undefined);
    if (occupants.length > 0) slots[key] = occupants;
  }
  const report = { bootRev, reportedAt: Date.now(), slots };
  const attribution = str(body.attribution, 16);
  if (attribution !== undefined) report.attribution = attribution;
  if (typeof body.unresolved === "number") report.unresolved = int(body.unresolved);
  return report;
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    if (req.aborted || req.destroyed) return reject(new Error("request body was interrupted"));
    const chunks = [];
    let size = 0;
    let over = false;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) over = true;
      else if (!over) chunks.push(chunk);
    });
    req.on("end", () => (over ? reject(Object.assign(new Error("body too large"), { status: 413 })) : resolve(Buffer.concat(chunks))));
    req.on("error", reject);
  });
}

function send(res, status, body) {
  const headers = { "cache-control": "no-store", "x-content-type-options": "nosniff" };
  if (body === undefined) {
    res.writeHead(status, headers);
    res.end();
    return;
  }
  const text = typeof body === "string" ? `${body}\n` : JSON.stringify(body);
  headers["content-type"] = typeof body === "string" ? "text/plain; charset=utf-8" : "application/json; charset=utf-8";
  res.writeHead(status, headers);
  res.end(text);
}

/** Connection's verdict for one request: undefined (admit), 401, 403, or 503 while it is absent. */
function rejectionOf(ctx, req) {
  const connection = ctx.get("connection");
  return connection === undefined ? 503 : connection.requestRejection(req);
}

/**
 * Fallback guard for webservers without the dsh-app route-guard patch: wraps every route
 * already in the tables and every later registration. Returns the guard state.
 */
function installFallbackGuard(webCtx, open) {
  const raw = webCtx.webServer[ORIGINAL] ?? webCtx.webServer;
  if (typeof raw.dshGoRouteRejection === "function") return "patched";
  if (raw[GUARDED]) return "bridge";
  const openSet = new Set(open);
  const wrapHttp = (route) => {
    if (route[GUARDED] || openSet.has(`${route.kind} ${route.path}`)) return route;
    return {
      ...route,
      [GUARDED]: route,
      handler: async (req, res) => {
        const status = rejectionOf(webCtx, req);
        if (status !== undefined) {
          const unavailable = status === 503 && (sessionDeletionUnavailable(req) || pluginConfigUnavailable(req));
          res.writeHead(status, { "cache-control": "no-store", "content-type": unavailable ? "application/json; charset=utf-8" : "text/plain; charset=utf-8", "x-dsh-go-guard": "reject" });
          res.end(req.method === "HEAD" ? undefined : unavailable ? JSON.stringify(unavailable) : `${STATUS_CODES[status]}\n`);
          return;
        }
        return route.handler(req, res);
      },
    };
  };
  const wrapUpgrade = (route) => {
    if (route[GUARDED] || openSet.has(`upgrade ${route.path}`)) return route;
    return {
      ...route,
      [GUARDED]: route,
      handler: (req, socket, head) => {
        const status = rejectionOf(webCtx, req);
        if (status === undefined) return route.handler(req, socket, head);
        socket.end(`HTTP/1.1 ${status} ${STATUS_CODES[status]}\r\nConnection: close\r\nContent-Length: 0\r\nX-Dsh-Go-Guard: reject\r\n\r\n`);
      },
    };
  };
  const rewrap = (table, wrap) => {
    for (const [path, route] of table) table.set(path, wrap(route));
  };
  const unwrap = (table) => {
    for (const [path, route] of table) if (route[GUARDED] && route[GUARDED] !== true) table.set(path, route[GUARDED]);
  };
  webCtx.effect(() => {
    rewrap(raw.exact, wrapHttp);
    rewrap(raw.prefixes, wrapHttp);
    rewrap(raw.upgrades, wrapUpgrade);
    const register = raw.register;
    const registerUpgrade = raw.registerUpgrade;
    raw.register = function (route) { return register.call(this, wrapHttp(route)); };
    raw.registerUpgrade = function (route) { return registerUpgrade.call(this, wrapUpgrade(route)); };
    raw[GUARDED] = true;
    return () => {
      delete raw.register;
      delete raw.registerUpgrade;
      delete raw[GUARDED];
      unwrap(raw.exact);
      unwrap(raw.prefixes);
      unwrap(raw.upgrades);
    };
  }, "dsh-go-bridge: fallback route guard");
  return "bridge";
}

function packageList(ctx, graph) {
  const packages = new Map();
  for (const entry of graph?.entries ?? []) {
    if (typeof entry?.id === "string") packages.set(entry.id, { name: entry.id, hasClient: true, rev: entry.rev ?? null, official: isOfficial(entry.id) });
  }
  try {
    for (const entry of ctx.get("loader")?.entries() ?? []) {
      if (entry.disabled || entry.fiber === undefined) continue;
      const pkg = packageOf(entry.options?.name);
      if (pkg !== undefined && !packages.has(pkg)) packages.set(pkg, { name: pkg, hasClient: false, rev: null, official: isOfficial(pkg) });
    }
  } catch (error) {
    ctx.logger?.warn?.(error);
  }
  return [...packages.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function apply(ctx, config) {
  const options = isObject(config) ? config : {};
  const persist = options.persist !== false;
  const open = [...DEFAULT_OPEN_ROUTES, ...(Array.isArray(options.openRoutes) ? options.openRoutes.filter((r) => typeof r === "string") : [])];
  let occupancy;
  if (persist) {
    try {
      const stored = JSON.parse(readFileSync(cachePath(), "utf8"));
      const saved = parseReport(stored);
      if (typeof saved === "object") occupancy = { ...saved, reportedAt: num(stored.reportedAt) };
    } catch {}
  }
  const save = (value) => {
    if (!persist) return;
    try {
      const path = cachePath();
      mkdirSync(join(path, ".."), { recursive: true });
      writeFileSync(`${path}.tmp`, JSON.stringify(value));
      renameSync(`${path}.tmp`, path);
    } catch (error) {
      ctx.logger?.warn?.(error);
    }
  };

  // Native plugin protocol: the service exists whenever the bridge runs (no cost without plugins).
  const native = new NativeCore(ctx, effectiveLimits(options.native), VERSION);
  ctx.effect(() => () => native.dispose(), "dsh-go-bridge: native core");
  ctx.provide("dshGo", native.service);
  let companionRecall;
  const companionPrompt = createCompanionPromptContext({
    isCurrent: agent => ctx.get('agents')?.get(agent.id) === agent &&
      ctx.get('agentPresets')?.presetForSession(agent.session) === FULL_PRESET,
    allowMemory: agent => companionRecall?.allowsQueryContext(agent) === true,
  });
  ctx.provide('dshGoCompanionContext', companionPrompt);
  ctx.effect(() => () => companionPrompt.clear(), 'dsh-go-bridge: companion prompt context');
  const isCompanion = agent => ctx.get('agentPresets')?.presetForSession(agent.session) === FULL_PRESET;
  ctx.on('agent/inbox/claimed', ({ agent, message, turn }) => {
    if (isCompanion(agent)) companionPrompt.claim(agent, message, turn);
  });
  ctx.on('agent/inbox/discarded', ({ agent, message }) => companionPrompt.discard(agent, message));
  const usage = createUsage();
  ctx.on('session/event', (session, event) => {
    usage.observe(event);
    if (event.type === 'user/message') companionPrompt.commit(session, event.data, event.time);
    if (event.type === 'turn/end') companionPrompt.end(session);
  });
  ctx.on('agent/disposed', ({ agent }) => companionPrompt.retire(agent));
  const companionSignals = createCompanionSignals(ctx);
  ctx.effect(() => () => companionSignals.dispose(), "dsh-go-bridge: companion signals");
  // HTTP writes and engine admission share exactly one store/coordinator per
  // bridge generation. Missing or incompatible engine modules keep recall off.
  const companionStore = createCompanionStore();
  const companionContexts = createRecallContexts();
  let recallDisposed = false;
  const recallAdapter = import("./companion/recall-engine.js")
    .then((module) => recallDisposed ? undefined : module.createRecallEngineAdapter(ctx, { contexts: companionContexts }))
    .then((adapter) => {
      if (!recallDisposed && adapter) ctx.provide("dshGoCompanionRecallEngine", adapter);
      return recallDisposed ? undefined : adapter;
    }).catch(() => undefined);
  companionRecall = createRecallCoordinator({ store: companionStore, adapter: recallAdapter, promptContext: companionPrompt });
  companionRecall.registerContext = companionContexts.registerContext;
  ctx.provide("dshGoCompanionRecall", companionRecall);
  ctx.effect(() => () => {
    recallDisposed = true;
    companionRecall.dispose();
    companionContexts.dispose();
  }, "dsh-go-bridge: companion recall");
  ctx.on("internal/plugin", () => native.markDirty());
  let pluginConfig;
  ctx.on("internal/status", (fiber) => { native.markDirty(); pluginConfig?.statusChanged(fiber); });

  ctx.inject(["webServer"], (webCtx) => {
    webCtx.effect(() => webCtx.webServer.tapIndex(injectPromiseWithResolvers),
      "dsh-go-bridge: browser Promise.withResolvers");
    const routeGuardMode = options.guardRoutes === false ? "off" : installFallbackGuard(webCtx, open);

    // Guard self-test: a credential-less request to an unauthenticated route registered like any
    // plugin route must be refused before its handler runs. Measured, never assumed, because the
    // app opens local web islands only when this holds.
    let canaryHits = 0;
    let guardProbe;   // { at, ok }
    webCtx.effect(() => webCtx.webServer.register({
      kind: "exact",
      path: CANARY,
      handler: (req, res) => {
        canaryHits++;
        send(res, 204);
      },
    }), "dsh-go-bridge: guard canary");
    const probeGuard = async () => {
      if (guardProbe !== undefined && Date.now() - guardProbe.at < GUARD_PROBE_TTL_MS) return guardProbe.ok;
      const before = canaryHits;
      let status = 0;
      try {
        const url = new URL(CANARY, webCtx.webServer.getOrigin());
        status = await new Promise((resolve) => {
          const fetchOwn = url.protocol === "https:" ? httpsGet : httpGet;
          const req = fetchOwn(url, { agent: false, timeout: 3000, rejectUnauthorized: false }, (res) => {
            res.resume();
            resolve(res.statusCode ?? 0);
          });
          req.on("timeout", () => req.destroy());
          req.on("error", () => resolve(0));
        });
      } catch (error) {
        webCtx.logger?.warn?.(error);
      }
      const ok = (status === 401 || status === 403) && canaryHits === before;
      guardProbe = { at: Date.now(), ok };
      return ok;
    };

    const inventory = async () => {
      let graph;
      try {
        graph = webCtx.get("clientModules")?.graph();
      } catch (error) {
        webCtx.logger?.warn?.(error);
      }
      const currentRev = typeof graph?.rev === "string" ? graph.rev : null;
      return {
        v: 1,
        bridge: VERSION,
        release: isObject(graph?.release) ? graph.release : null,
        // bootRev names the boot graph the occupancy table was taken from; currentRev is the
        // graph a page loaded now would boot (they differ after a plugin change -> probe).
        ...(occupancy === undefined ? {} : { bootRev: occupancy.bootRev }),
        currentRev,
        packages: packageList(webCtx, graph),
        slots: occupancy === undefined ? null : occupancy.slots,
        occupancy: occupancy === undefined ? null : {
          reportedAt: occupancy.reportedAt,
          stale: occupancy.bootRev !== currentRev,
          ...(occupancy.attribution === undefined ? {} : { attribution: occupancy.attribution }),
          ...(occupancy.unresolved === undefined ? {} : { unresolved: occupancy.unresolved }),
        },
        routeGuard: await probeGuard(),
        routeGuardMode,
      };
    };

    const nativeRoutes = createNativeRoutes(native, { beginUsage: usage.beginPlugin });
    pluginConfig = createPluginConfig(webCtx, { readBody, send });
    const sessionDeletion = createSessionDeletion(webCtx, { readBody, send });
    const speechRoutes = createSpeechRoutes(webCtx, { send, fetch: options.speech?.fetch, apiKeyEnv: options.speech?.apiKeyEnv });
    webCtx.effect(() => () => speechRoutes.dispose(), "dsh-go-bridge: speech routes");
    const companionRoutes = createCompanionRoutes({ send, store: companionStore, recall: companionRecall, signals: companionSignals, ctx: webCtx, promptContext: companionPrompt });
    webCtx.effect(() => () => nativeRoutes.dispose(), "dsh-go-bridge: native routes");
    webCtx.effect(() => webCtx.webServer.registerUpgrade({
      path: STREAM_PATH,
      handler: (req, socket, head) => {
        const rejection = rejectionOf(webCtx, req);
        if (rejection !== undefined) {
          socket.end(`HTTP/1.1 ${rejection} ${STATUS_CODES[rejection]}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
          return;
        }
        nativeRoutes.upgrade(req, socket, head);
      },
    }), "dsh-go-bridge: native stream");

    const handler = async (req, res) => {
      const rejection = rejectionOf(webCtx, req);
      if (rejection !== undefined) return send(res, rejection, rejection === 503 && (sessionDeletionUnavailable(req) || pluginConfigUnavailable(req)) || STATUS_CODES[rejection]);
      const url = new URL(req.url ?? "/", "http://dsh-go.invalid");
      const path = url.pathname;
      if (path === `${PREFIX}/v1/usage/collect`) {
        if (req.method !== "POST") return send(res, 405);
        if (!["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(req.socket.remoteAddress)) return send(res, 403);
        const body = await readBody(req, 16).catch(() => null);
        if (body?.toString() !== "on" && body?.toString() !== "off") return send(res, 400);
        return send(res, 200, usage.pull(body.toString() === "on"));
      }
      if (await sessionDeletion.handle(req, res, path)) return;
      if (await pluginConfig.handle(req, res, path)) return;
      if (await speechRoutes.handle(req, res, path)) return;
      if (await companionRoutes.handle(req, res, path)) return;
      if (path.startsWith(`${PREFIX}/v1/`) && await nativeRoutes.handle(req, res, path, url)) return;
      if (path === `${PREFIX}/v1/capabilities`) {
        if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, { error: { code: "method-not-allowed", message: "method not allowed" } });
        return send(res, 200, { v: 1, bridge: VERSION, capabilities: CAPABILITIES });
      }
      if (path === `${PREFIX}/v1/inventory`) {
        if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, { error: { code: "method-not-allowed", message: "method not allowed" } });
        return send(res, 200, await inventory());
      }
      if (path === `${PREFIX}/v1/occupancy`) {
        if (req.method !== "POST") return send(res, 405, { error: { code: "method-not-allowed", message: "method not allowed" } });
        if (String(req.headers["content-type"]).split(";", 1)[0].trim().toLowerCase() !== "application/json") {
          req.resume();
          return send(res, 415, { error: { code: "unsupported-media-type", message: "content-type must be application/json" } });
        }
        let report;
        try {
          report = parseReport(JSON.parse((await readBody(req, MAX_BODY)).toString("utf8")));
        } catch (error) {
          return send(res, error?.status ?? 400, { error: { code: error?.status === 413 ? "too-large" : "bad-request", message: error?.status === 413 ? "body too large" : "body is not JSON" } });
        }
        if (typeof report === "number") return send(res, report, { error: { code: report === 413 ? "too-large" : "bad-request", message: STATUS_CODES[report] } });
        // A page whose bridge started late (HMR) cannot attribute older entries; it does not
        // replace a better report of the same boot graph.
        const worse = occupancy !== undefined && occupancy.bootRev === report.bootRev
          && (report.unresolved ?? 0) > (occupancy.unresolved ?? 0);
        if (!worse) {
          occupancy = report;
          save(report);
        }
        return send(res, 204);
      }
      return send(res, 404, { error: { code: "route-not-found", message: "not found" } });
    };

    webCtx.effect(() => webCtx.webServer.register({ kind: "prefix", path: PREFIX, handler }), "dsh-go-bridge: /dsh-go routes");
  });
}
