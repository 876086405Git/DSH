// Native plugin protocol v1 against a running `dsh web` with dsh-go-bridge and the fixture plugins
// (runtime/tests/run-native-tests.sh). Node built-ins only.
//
//   node runtime/tests/native-bridge.mjs <base-url> <launch-token> [--empty] [--shipped]
//
// --shipped: the bridge runs with its default timers (runtime/test-host.sh inside the rootfs), so
// the heartbeat / idle / linger checks that need the shortened test timers are skipped.
// DSH_GO_BRIDGE_LIB points at the bridge's lib/native directory when the repo is not around.
import http from "node:http";
import { randomBytes } from "node:crypto";
import { pathToFileURL } from "node:url";

const WS = await import(process.env.DSH_GO_BRIDGE_LIB
  ? pathToFileURL(`${process.env.DSH_GO_BRIDGE_LIB.replace(/\/$/, "")}/ws.js`).href
  : new URL("../bridge/dsh-go-bridge/lib/native/ws.js", import.meta.url));
const [baseArg, token, ...flags] = process.argv.slice(2);
if (!baseArg || !token) {
  console.error("usage: native-bridge.mjs <base-url> <launch-token> [--empty]");
  process.exit(2);
}
const EMPTY = flags.includes("--empty");
const SHIPPED = flags.includes("--shipped");
const base = new URL(baseArg);
const USAGE = "dsh-go-fixture-usage";
const QUICK = "dsh-go-fixture-quick";
const STATIC = "@dsh-go-fixture/static";
const CAPS = "v=1&app=0.10.0&locale=zh-CN&surfaces=composer.actions,message.actions,composer.strip,panels&components=stack,row,text,metric";

let failed = 0;
let passed = 0;
const pass = (msg) => { passed++; console.log(`  \x1b[32mPASS\x1b[0m ${msg}`); };
const fail = (msg) => { failed++; console.log(`  \x1b[31mFAIL\x1b[0m ${msg}`); };
const check = (ok, msg) => (ok ? pass(msg) : fail(msg));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const section = (s) => console.log(`== ${s}`);

function request(method, path, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
    const started = Date.now();
    const req = http.request({
      host: base.hostname, port: base.port, method, path,
      headers: {
        host: base.host,
        ...(payload !== undefined && typeof body !== "string" ? { "content-type": "application/json" } : {}),
        ...headers,
        ...(payload !== undefined ? { "content-length": Buffer.byteLength(payload) } : {}),
      },
    }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw = Buffer.concat(chunks);
        let json;
        try { json = JSON.parse(raw.toString("utf8")); } catch {}
        resolve({ status: res.statusCode, headers: res.headers, raw, text: raw.toString("utf8"), json, ms: Date.now() - started });
      });
    });
    req.on("error", reject);
    req.setTimeout(20000, () => req.destroy(new Error(`timeout ${method} ${path}`)));
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}

/** Minimal WebSocket client: masked frames out, JSON messages in, answers pings unless told not to. */
function wsConnect(headers = {}, { answerPings = true } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: base.hostname, port: base.port, path: "/dsh-go/v1/stream",
      headers: { host: base.host, connection: "Upgrade", upgrade: "websocket", "sec-websocket-version": "13", "sec-websocket-key": randomBytes(16).toString("base64"), ...headers },
    });
    req.on("response", (res) => { res.resume(); resolve({ status: res.statusCode }); });
    req.on("error", reject);
    req.on("upgrade", (res, socket, head) => {
      const queue = [];
      const waiters = [];
      let buf = head ?? Buffer.alloc(0);
      let closeCode;
      let closeResolve;
      const closed = new Promise((r) => { closeResolve = r; });
      const c = {
        status: res.statusCode,
        pings: 0,
        queue,
        closed,
        get closeCode() { return closeCode; },
        send(obj) { if (!socket.destroyed) socket.write(WS.encodeFrame(0x1, typeof obj === "string" ? obj : JSON.stringify(obj), { mask: true })); },
        raw(frame) { socket.write(frame); },
        close() { try { socket.write(WS.encodeFrame(0x8, Buffer.from([0x03, 0xe8]), { mask: true })); } catch {} socket.end(); },
        /** Next message matching `pred` (consumed), or undefined after `ms`. */
        next(pred = () => true, ms = 3000) {
          const i = queue.findIndex(pred);
          if (i >= 0) return Promise.resolve(queue.splice(i, 1)[0]);
          return new Promise((resolve2) => {
            const w = { pred, resolve: resolve2 };
            w.timer = setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); resolve2(undefined); }, ms);
            waiters.push(w);
          });
        },
        drain() { queue.splice(0); },
      };
      const deliver = (msg) => {
        const i = waiters.findIndex((w) => w.pred(msg));
        if (i >= 0) { const [w] = waiters.splice(i, 1); clearTimeout(w.timer); w.resolve(msg); } else queue.push(msg);
      };
      const parse = () => {
        while (buf.length >= 2) {
          const op = buf[0] & 0x0f;
          let len = buf[1] & 0x7f;
          let off = 2;
          if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
          else if (len === 127) { if (buf.length < 10) return; len = buf.readUInt32BE(6); off = 10; }
          if (buf.length < off + len) return;
          const payload = buf.subarray(off, off + len);
          buf = buf.subarray(off + len);
          if (op === 0x1) { try { deliver(JSON.parse(payload.toString("utf8"))); } catch { deliver({ t: "__bad__" }); } }
          else if (op === 0x9) { c.pings++; if (answerPings && !socket.destroyed) socket.write(WS.encodeFrame(0xa, payload, { mask: true })); }
          else if (op === 0x8) { closeCode = payload.length >= 2 ? payload.readUInt16BE(0) : 1005; socket.end(); closeResolve(closeCode); }
        }
      };
      socket.on("data", (d) => { buf = Buffer.concat([buf, d]); parse(); });
      socket.on("close", () => { closeCode ??= 1006; closeResolve(closeCode); });
      socket.on("error", () => {});
      parse();
      resolve(c);
    });
    req.end();
  });
}

const withTimeout = (p, ms, fallback) => Promise.race([p, sleep(ms).then(() => fallback)]);

// ------------------------------------------------------------------ login
section("login");
const login = await request("GET", `/?token=${encodeURIComponent(token)}`);
const setCookie = [].concat(login.headers["set-cookie"] ?? []).find((c) => c.startsWith("dsh-auth-"));
check(login.status === 303 && setCookie, `GET /?token -> ${login.status} + cookie`);
if (!setCookie) process.exit(1);
const C = { cookie: setCookie.split(";")[0] };
const get = (path, headers = {}) => request("GET", path, { headers: { ...C, ...headers } });
const post = (path, body, headers = {}) => request("POST", path, { headers: { ...C, ...headers }, body });
const invoke = (body, headers) => post("/dsh-go/v1/invoke", { v: 1, ...body }, headers);
const contributions = async (q = CAPS, headers) => get(`/dsh-go/v1/contributions?${q}`, headers);

section("bridge protocol capabilities");
const bridgeCapabilities = await get("/dsh-go/v1/capabilities");
check(bridgeCapabilities.status === 200 && bridgeCapabilities.json?.v === 1 && typeof bridgeCapabilities.json?.bridge === "string",
  `capabilities -> ${bridgeCapabilities.status}, v=${bridgeCapabilities.json?.v}, bridge=${bridgeCapabilities.json?.bridge}`);
check(["inventory", "native-ui", "native-stream", "native-media", "native-files"].every(name => bridgeCapabilities.json?.capabilities?.includes(name)),
  "capabilities declare implemented native routes even without a plugin");
const capabilitiesMethod = await post("/dsh-go/v1/capabilities", {});
check(capabilitiesMethod.status === 405 && capabilitiesMethod.json?.error?.code === "method-not-allowed", "capabilities only accepts GET");
const absentRoute = await get("/dsh-go/v1/unknown-route");
check(absentRoute.status === 404 && absentRoute.json?.error?.code === "route-not-found", "unknown route has a distinct route-not-found code");

if (EMPTY) {
  section("no plugin declares dshGo: nothing changes");
  const r = await contributions();
  check(r.status === 200 && Array.isArray(r.json?.plugins) && r.json.plugins.length === 0, `contributions -> ${r.status}, plugins ${JSON.stringify(r.json?.plugins)}`);
  check(r.json?.limits?.viewBytes === 32768 && r.json?.bridge, `limits and bridge ${r.json?.bridge} present`);
  check(r.json?.bridge === bridgeCapabilities.json?.bridge, "capabilities and contributions use the same implementation version");
  const v = await get(`/dsh-go/v1/views/${USAGE}/usage?${CAPS}`);
  check(v.status === 404 && v.json?.error?.code === "not-found", `view of a missing plugin -> ${v.status} ${v.json?.error?.code}`);
  const ws = await wsConnect(C);
  ws.send({ t: "hello", v: [1] });
  const w = await ws.next((m) => m.t === "welcome");
  check(w?.v === 1, "stream still answers hello");
  ws.close();
  const inv = await get("/dsh-go/v1/inventory");
  check(inv.status === 200 && inv.json?.routeGuard === true, `inventory unaffected (routeGuard=${inv.json?.routeGuard})`);
  console.log(`== native (empty): ${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

// ------------------------------------------------------------------ guard
section("guard: every native route needs the cookie");
for (const [method, path] of [["GET", "/dsh-go/v1/capabilities"], ["GET", `/dsh-go/v1/contributions?${CAPS}`], ["GET", `/dsh-go/v1/views/${USAGE}/usage`], ["POST", "/dsh-go/v1/invoke"], ["GET", `/dsh-go/v1/assets/${STATIC}/img/dot.png`]]) {
  const anon = await request(method, path, method === "POST" ? { body: { v: 1 } } : {});
  check(anon.status === 401, `${method} ${path.split("?")[0]} without cookie -> ${anon.status}`);
  const evil = await request(method, path, { headers: { ...C, origin: "http://evil.example" }, ...(method === "POST" ? { body: { v: 1 } } : {}) });
  check(evil.status === 403, `${method} ${path.split("?")[0]} cookie + cross-site Origin -> ${evil.status}`);
}
const anonWs = await wsConnect({});
check(anonWs.status === 401, `WS stream without cookie -> ${anonWs.status}`);
const evilWs = await wsConnect({ ...C, origin: "http://evil.example" });
check(evilWs.status === 403, `WS stream cookie + cross-site Origin -> ${evilWs.status}`);

// ------------------------------------------------------------------ contributions
section("contributions");
await sleep(300);
const c1 = await contributions();
check(c1.status === 200 && c1.json?.v === 1 && typeof c1.json?.rev === "string", `GET contributions -> ${c1.status} rev=${c1.json?.rev} in ${c1.ms} ms`);
check(c1.json?.bridge === bridgeCapabilities.json?.bridge, "capabilities and contributions use the same implementation version");
check(c1.ms < 300, `local round trip ${c1.ms} ms < 300 ms`);
const plugins = c1.json?.plugins ?? [];
const pkgs = plugins.map((p) => p.pkg);
check(pkgs.length === 3 && [USAGE, QUICK, STATIC].every((p) => pkgs.includes(p)), `exactly the three fixtures: ${pkgs.join(", ")}`);
check(JSON.stringify(pkgs) === JSON.stringify([...pkgs].sort((a, b) => a.localeCompare(b))), "sorted by package name");
check(c1.headers.etag === `"${c1.json?.rev}"`, `ETag ${c1.headers.etag}`);
const c304 = await contributions(CAPS, { "if-none-match": c1.headers.etag });
check(c304.status === 304 && c304.raw.length === 0, `If-None-Match -> ${c304.status}`);
const usage = plugins.find((p) => p.pkg === USAGE);
check(usage?.title === "用量" && usage.version === "1.2.3" && usage.state === "ok" && usage.native === true && usage.icon === "chart", `usage row: ${usage?.title} ${usage?.version} ${usage?.state}`);
check(JSON.stringify(usage?.contributes["composer.strip"]) === JSON.stringify([{ id: "cost", icon: "coin", text: null, panel: "usage", tappable: true, live: true, ready: true }]), `usage strip ${JSON.stringify(usage?.contributes["composer.strip"])}`);
check(usage?.contributes.panels[0]?.live === true && usage.contributes.panels[0].ready === true && JSON.stringify(usage.contributes.panels[0].placement) === '["session.tab","features"]', "usage panel ready + live + placement");
check(usage?.contributes.panels[1]?.id === "plain" && usage.contributes.panels[1].live === false && usage.contributes.panels[1].ready === true, "plain panel ready, not live");
check(usage?.issues.length === 0, `usage has no issues ${JSON.stringify(usage?.issues)}`);
const quick = plugins.find((p) => p.pkg === QUICK);
const qa = quick?.contributes["composer.actions"] ?? [];
check(qa[0]?.label === "译成英文" && qa[0].ready && qa[0].effect === undefined, "translate: zh label, ready via on()");
check(JSON.stringify(qa[1]?.effect) === '[{"type":"insert","text":"总结上面的对话"}]' && qa[1].ready, "sum: static effect normalized to a list");
check(quick?.contributes["message.actions"].length === 2 && quick.contributes["message.actions"].every((a) => a.ready), "message actions ready");
check(quick?.contributes.panels.length === 4, `quick panels capped at 4 (${quick?.contributes.panels.map((p) => p.id)})`);
const qcodes = (quick?.issues ?? []).map((i) => i.code);
check(qcodes.includes("too-many") && qcodes.includes("undeclared"), `quick issues: ${qcodes.join(", ")}`);
check(JSON.stringify(quick?.wants) === '["clipboard","message"]', `quick wants ${JSON.stringify(quick?.wants)}`);
const stat = plugins.find((p) => p.pkg === STATIC);
const scodes = (stat?.issues ?? []).map((i) => `${i.code}@${i.path}`);
check(stat?.state === "ok" && [...stat.title].length === 24, `static title truncated to 24: ${stat?.title}`);
for (const want of ["unknown-field@/dshGo/future", "invalid-field@/dshGo/wants/1", "duplicate-id@/dshGo/contributes/composer.actions/1/id",
  "invalid-field@/dshGo/contributes/composer.actions/2/id", "invalid-field@/dshGo/contributes/composer.actions/3/effect",
  "missing-field@/dshGo/contributes/message.actions/0/label", "invalid-field@/dshGo/contributes/composer.strip/0/panel",
  "invalid-field@/dshGo/contributes/panels/0/placement/1", "view-file@/dshGo/contributes/panels/1/view", "unknown-surface@/dshGo/contributes/pets",
  "too-long@/dshGo/title", "no-handler@/dshGo/contributes/composer.actions/3"]) {
  check(scodes.includes(want), `static issue ${want}`);
}
check(JSON.stringify(stat?.contributes["composer.actions"].map((a) => [a.id, a.ready])) === '[["hello",true],["weird",false]]', "static actions: hello ready (effect), weird not ready");
check(JSON.stringify(stat?.contributes["composer.actions"][0].effect) === '[{"type":"insert","text":"你好"},{"type":"toast","text":"x"}]', "static effect shorthand inside the manifest list");
check(stat?.contributes["composer.strip"][0]?.text === "静态状态条" && stat.contributes["composer.strip"][0].ready && !stat.contributes["composer.strip"][0].tappable, "static strip text only");
check(stat?.contributes.panels[0]?.ready === true && stat.contributes.panels[1]?.ready === false, "static view panel ready; escaping view file not");
const en = await contributions(CAPS.replace("zh-CN", "en"));
const enQuick = en.json?.plugins.find((p) => p.pkg === QUICK);
check(en.json?.plugins.find((p) => p.pkg === USAGE)?.title === "Usage" && enQuick?.contributes["composer.actions"][0].label === "To English", `locale en: titles and 10-char truncation (${enQuick?.contributes["composer.actions"][0].label})`);
check(en.json?.rev !== c1.json?.rev, "rev differs per locale");
const v2 = await contributions("v=2");
check(v2.status === 400 && v2.json?.error?.code === "unsupported-version", `v=2 -> ${v2.status} ${v2.json?.error?.code}`);
const listsBridge = pkgs.includes("dsh-go-bridge") || pkgs.some((p) => p.startsWith("@deepseek-ai/"));
check(!listsBridge, "bridge and official packages are never listed");

// ------------------------------------------------------------------ views
section("views");
const vu = await get(`/dsh-go/v1/views/${USAGE}/usage?${CAPS.replace("zh-CN", "en")}&sessionId=s1`);
check(vu.status === 200 && vu.json?.title === "Usage" && vu.json.view?.type === "stack" && vu.json.view.title === "usage s1", `usage view -> ${vu.status} ${vu.json?.view?.title}`);
check(JSON.stringify(vu.json?.data) === '{"count":0,"note":"start","nested":{"a":1,"b":2}}' && typeof vu.json?.rev === "string" && vu.json.live === true, `initial data ${JSON.stringify(vu.json?.data)} rev=${vu.json?.rev}`);
check(vu.json?.stats?.nodes === 3 && vu.json.stats.depth === 2 && vu.json.stats.bytes > 0, `stats ${JSON.stringify(vu.json?.stats)}`);
let fx = (await get("/native-fixture/state")).json;
check(fx?.lastCaps?.locale === "en" && fx.lastCaps.protocol === 1 && fx.lastCaps.app === "0.10.0" && fx.lastCaps.components.includes("metric"), `caps passed to view(): ${JSON.stringify(fx?.lastCaps)}`);
const vp = await get(`/dsh-go/v1/views/${USAGE}/plain?${CAPS}`);
check(vp.status === 200 && vp.json?.data === null && vp.json.rev === null && vp.json.live === false && vp.json.view?.text === "plain", "plain view: no data, not live");
const vs = await get(`/dsh-go/v1/views/${STATIC}/about?${CAPS}`);
check(vs.status === 200 && vs.json?.title === "关于" && vs.json.view?.children?.[1]?.type === "keyValue", `scoped package static view -> ${vs.status}`);
const ve = await get(`/dsh-go/v1/views/${STATIC}/escape?${CAPS}`);
check(ve.status === 409 && ve.json?.error?.code === "no-handler", `panel with rejected view file -> ${ve.status} ${ve.json?.error?.code}`);
const v404 = await get(`/dsh-go/v1/views/${USAGE}/nope?${CAPS}`);
check(v404.status === 404 && v404.json?.error?.code === "not-found", `unknown panel -> ${v404.status}`);
const v404b = await get(`/dsh-go/v1/views/no-such-plugin/usage?${CAPS}`);
check(v404b.status === 404, `unknown package -> ${v404b.status}`);
const vbad = await get(`/dsh-go/v1/views/${USAGE}/usage?${CAPS}&sessionId=a%0Ab`);
check(vbad.status === 400 && vbad.json?.error?.code === "bad-request", `control character in scope -> ${vbad.status}`);
const vtools = await get(`/dsh-go/v1/views/${QUICK}/tools?${CAPS}`);
check(vtools.status === 200 && vtools.json?.view?.children?.[0]?.text === "locale=zh-CN", "quick tools view");

// ------------------------------------------------------------------ stream
section("stream");
const ws = await wsConnect(C);
check(ws.status === 101, `WS upgrade with cookie -> ${ws.status}`);
ws.send({ t: "hello", v: [1], locale: "en" });
const welcome = await ws.next((m) => m.t === "welcome");
check(welcome?.v === 1 && welcome.hb === (SHIPPED ? 25 : 1) && typeof welcome.bridge === "string", `welcome ${JSON.stringify(welcome)}`);
ws.send({ t: "sub", sub: "s1", pkg: USAGE, id: "usage", scope: { sessionId: "s1" }, rev: vu.json.rev });
const sync = await ws.next((m) => m.sub === "s1");
check(sync?.t === "sync" && sync.rev === vu.json.rev, `sub with the GET rev -> ${sync?.t} (feed kept alive between GET and sub)`);
fx = (await get("/native-fixture/state")).json;
check(fx?.dataStarts === 1, `data() started once for GET + sub (${fx?.dataStarts})`);
check(fx?.dataCaps?.locale === "en" && fx.dataCaps.protocol === 1, `data() gets caps ${JSON.stringify(fx?.dataCaps)} (feed shared per locale)`);
await get(`/native-fixture/emit?scope=${encodeURIComponent('{"sessionId":"s1"}')}&n=5`);
const p1 = await ws.next((m) => m.sub === "s1");
check(p1?.t === "patch" && p1.base === vu.json.rev && JSON.stringify(p1.merge) === '{"count":5,"note":"emit","nested":{"b":5}}', `5 emits in one tick -> one patch ${JSON.stringify(p1)}`);
const extra = await ws.next((m) => m.sub === "s1", 400);
check(extra === undefined, "no further message (coalesced at 4 Hz)");
await get(`/native-fixture/emit-raw?scope=${encodeURIComponent('{"sessionId":"s1"}')}&bytes=20000`);
const big = await ws.next((m) => m.sub === "s1");
check(big?.t === "data" && big.data?.blob?.length === 20000, `patch over 16 KiB -> full data (${big?.t})`);
await get(`/native-fixture/emit-raw?scope=${encodeURIComponent('{"sessionId":"s1"}')}&bytes=40000`);
const none = await ws.next((m) => m.sub === "s1", 600);
check(none === undefined, "data over 32 KiB is dropped (violation), nothing sent");
await get(`/native-fixture/emit?scope=${encodeURIComponent('{"sessionId":"s1"}')}&n=1`);
const p2 = await ws.next((m) => m.sub === "s1");
check(p2?.t === "patch" && p2.base === big.rev && p2.merge.blob === null && p2.merge.count === 6, `next patch deletes blob, base = previous rev (${JSON.stringify(p2?.merge)})`);
await get(`/native-fixture/refresh?scope=${encodeURIComponent('{"sessionId":"s1"}')}`);
const stale = await ws.next((m) => m.sub === "s1");
check(stale?.t === "stale", "plugin refresh() -> stale");
await get(`/native-fixture/refresh?scope=${encodeURIComponent('{"sessionId":"other"}')}`);
check(await ws.next((m) => m.sub === "s1", 300) === undefined, "refresh for another scope does not reach s1");
ws.send({ t: "sub", sub: "st", pkg: USAGE, id: "cost", scope: { sessionId: "s1" } });
const strip = await ws.next((m) => m.sub === "st");
check(strip?.t === "data" && [...(strip.data?.text ?? "")].length === 24 && strip.data.tone === "warn" && strip.data.extra === undefined, `strip data ${JSON.stringify(strip?.data)}`);
ws.send({ t: "sub", sub: "x1", pkg: USAGE, id: "nope" });
check((await ws.next((m) => m.sub === "x1"))?.reason === "not-found", "sub unknown id -> end not-found");
ws.send({ t: "sub", sub: "x2", pkg: QUICK, id: "translate" });
check((await ws.next((m) => m.sub === "x2"))?.reason === "not-found", "sub an action (not a panel / strip) -> end not-found");
ws.send({ t: "sub", sub: "x3", pkg: "Bad Name", id: "x" });
check((await ws.next((m) => m.t === "error"))?.code === "bad-request", "malformed sub -> error bad-request, connection stays");
ws.send({ t: "ping", at: 7 });
check((await ws.next((m) => m.t === "pong"))?.at === 7, "ping -> pong");
ws.send({ t: "future-type", x: 1 });
ws.send({ t: "ping" });
check((await ws.next((m) => m.t === "pong")) !== undefined, "unknown message type ignored");
if (!SHIPPED) {
  await sleep(1200);
  check(ws.pings >= 1, `bridge sends WebSocket pings (${ws.pings})`);
}
ws.send({ t: "unsub", sub: "st" });

// reconnect + catch-up
const lastRev = p2.rev;
ws.close();
await ws.closed;
await get(`/native-fixture/emit?scope=${encodeURIComponent('{"sessionId":"s1"}')}&n=2`);
// The fixture's emit is coalesced asynchronously. Observe the new revision
// before reconnecting, or a fast runner can legitimately receive sync for the
// old revision while the timer has not published the requested count yet.
let published;
const publishDeadline = Date.now() + 2000;
do {
  published = await get(`/dsh-go/v1/views/${USAGE}/usage?${CAPS.replace("zh-CN", "en")}&sessionId=s1`);
  if (published.status === 200 && published.json?.data?.count === 8 && published.json.rev !== lastRev) break;
  await sleep(20);
} while (Date.now() < publishDeadline);
check(published.status === 200 && published.json?.data?.count === 8 && published.json.rev !== lastRev,
  "fixture publish did not reach the view before reconnect");
const ws2 = await wsConnect(C);
ws2.send({ t: "hello", v: [1], locale: "en" });
await ws2.next((m) => m.t === "welcome");
ws2.send({ t: "sub", sub: "s1", pkg: USAGE, id: "usage", scope: { sessionId: "s1" }, rev: lastRev });
let catchup = await ws2.next((m) => m.sub === "s1");
// The emit HTTP response is not a feed publication barrier. If the 4 Hz flush
// is still pending, attach first confirms the old published rev, then patches it.
if (catchup?.t === "sync") {
  check(catchup.rev === lastRev, `pending flush -> sync at requested rev ${catchup.rev}`);
  const update = await ws2.next((m) => m.sub === "s1");
  check(update?.t === "patch" && update.base === lastRev && typeof update.rev === "string" && update.rev !== lastRev
    && JSON.stringify(update.merge) === '{"count":8,"nested":{"b":8}}',
    `pending flush -> exact patch from old rev: ${JSON.stringify(update)}`);
  // Preserve the stale-rev/full-snapshot assertion after observing publication.
  ws2.send({ t: "sub", sub: "s1", pkg: USAGE, id: "usage", scope: { sessionId: "s1" }, rev: lastRev });
  catchup = await ws2.next((m) => m.sub === "s1");
  check(catchup?.rev === update?.rev, "stale-rev snapshot uses the published patch rev");
}
check(catchup?.t === "data" && catchup.data?.count === 8 && typeof catchup.rev === "string" && catchup.rev !== lastRev, `reconnect with old rev -> full data count=${catchup?.data?.count}`);
ws2.send({ t: "sub", sub: "s1", pkg: USAGE, id: "usage", scope: { sessionId: "s1" }, rev: catchup.rev });
const currentSync = await ws2.next((m) => m.sub === "s1");
check(currentSync?.t === "sync" && currentSync.rev === catchup.rev, "re-sub with current rev -> sync");

// protocol errors, idle, limits
const bad1 = await wsConnect(C);
bad1.send({ t: "sub", sub: "a", pkg: USAGE, id: "usage" });
check(await withTimeout(bad1.closed, 3000, "open") === 1008, "first frame not hello -> close 1008");
const bad2 = await wsConnect(C);
bad2.send({ t: "hello", v: [2] });
const ver = await bad2.next((m) => m.t === "error");
check(ver?.code === "unsupported-version" && await withTimeout(bad2.closed, 3000, "open") === 1008, "hello v:[2] -> error + 1008");
const bad3 = await wsConnect(C);
bad3.send("x".repeat(5000));
check(await withTimeout(bad3.closed, 3000, "open") === 1009, "inbound frame over 4 KiB -> 1009");
if (!SHIPPED) {
  const mute = await wsConnect(C, { answerPings: false });
  mute.send({ t: "hello", v: [1] });
  await mute.next((m) => m.t === "welcome");
  const t0 = Date.now();
  const muteCode = await withTimeout(mute.closed, 8000, "open");
  check(muteCode === 1001, `peer that never answers is closed 1001 after ${Date.now() - t0} ms (idle 4 s)`);
}
ws2.drain();
for (let i = 0; i < 32; i++) ws2.send({ t: "sub", sub: `c${i}`, pkg: USAGE, id: "cost", scope: { sessionId: `x${i}` } });
const capEnd = await ws2.next((m) => m.t === "end" && m.reason === "limit", 3000);
check(capEnd?.sub === "c31", `33rd subscription on one connection -> end limit (${capEnd?.sub})`);
for (let i = 0; i < 32; i++) ws2.send({ t: "unsub", sub: `c${i}` });
const extraConns = [];
for (let i = 0; i < 7; i++) { const c = await wsConnect(C); c.send({ t: "hello", v: [1] }); await c.next((m) => m.t === "welcome"); extraConns.push(c); }
const ninth = await wsConnect(C);
check(await withTimeout(ninth.closed, 3000, "open") === 1013, "9th connection -> 1013");
for (const c of extraConns) c.close();

// ------------------------------------------------------------------ invoke
section("invoke");
const tr = await invoke({ pkg: QUICK, id: "translate", surface: "composer.actions", scope: { sessionId: "s1" }, context: { draft: "D", clipboard: "hello" }, locale: "zh-CN" });
check(tr.status === 200 && JSON.stringify(tr.json?.effects) === '[{"type":"insert","text":"EN(hello)|draft=absent"},{"type":"toast","text":"已翻译"}]', `translate -> ${tr.status} ${JSON.stringify(tr.json?.effects)} (undeclared draft stripped) in ${tr.ms} ms`);
const sp = await invoke({ pkg: QUICK, id: "speak", surface: "message.actions", scope: { sessionId: "s1", messageId: "m1" }, context: { message: "hi", clipboard: "c" } });
check(sp.status === 200 && sp.json?.effects?.[0]?.text === "msg:hi:m1", `speak gets the message: ${JSON.stringify(sp.json?.effects)}`);
const sum = await invoke({ pkg: QUICK, id: "sum", surface: "composer.actions" });
check(sum.status === 409 && sum.json?.error?.code === "no-handler", `static-effect action is not invoked -> ${sum.status}`);
const good = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "good" });
check(good.status === 200 && JSON.stringify(good.json?.effects) === JSON.stringify([
  { type: "open", page: "panel:tools" }, { type: "link", url: "https://example.com/a?b=1" }, { type: "command", name: "compact", args: "now" }, { type: "refresh", id: "tools" }]) && good.json.issues.length === 0,
`whitelisted effects pass: ${JSON.stringify(good.json?.effects)}`);
const mixed = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "mixed" });
const mcodes = (mixed.json?.issues ?? []).map((i) => i.code);
check(mixed.status === 200 && mixed.json.effects.length === 1 && mixed.json.effects[0].type === "toast" && [...mixed.json.effects[0].text].length === 40, `mixed: only the truncated toast survives (${JSON.stringify(mixed.json?.effects)})`);
check(JSON.stringify(mcodes) === '["bad-effect","bad-effect","bad-effect","unknown-effect","too-long"]', `mixed issues ${mcodes.join(", ")}`);
const echo = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "echo", value: { a: 1 }, context: { draft: "D" } });
check(echo.status === 200 && echo.json?.effects?.[0]?.text === 'echo:{"a":1}:nodraft', `panel action gets value, no context (${echo.json?.effects?.[0]?.text})`);
const slow = await invoke({ pkg: QUICK, id: "slow", surface: "message.actions" });
check(slow.status === 504 && slow.json?.error?.code === "timeout" && slow.ms >= 2900 && slow.ms < 4500, `slow handler -> ${slow.status} after ${slow.ms} ms`);
const bump = await invoke({ pkg: USAGE, id: "usage", surface: "panel", action: "bump", scope: { sessionId: "s1" } });
check(bump.status === 200 && bump.json?.effects?.[0]?.text === "bumped 9" && JSON.stringify(bump.json.effects[1]) === '{"type":"patch","id":"usage","data":{"note":"patched"}}', `bump -> ${JSON.stringify(bump.json?.effects)}`);
let model = { ...catchup.data };
for (let m; (m = await ws2.next((x) => x.sub === "s1", 600)) !== undefined;) {
  if (m.t === "patch") model = Object.fromEntries(Object.entries({ ...model, ...m.merge }).filter(([, v]) => v !== null));
  if (m.t === "data") model = m.data;
}
check(model.count === 9 && model.note === "patched", `bump's emit and its patch effect both reach the feed: count=${model.count} note=${model.note}`);
for (const [label, body, status, code, headers] of [
  ["tool.card surface", { pkg: QUICK, id: "tools", surface: "tool.card" }, 400, "bad-request"],
  ["v 2", { v: 2, pkg: QUICK, id: "translate", surface: "composer.actions" }, 400, "unsupported-version"],
  ["value on an action", { pkg: QUICK, id: "translate", surface: "composer.actions", value: 1 }, 400, "bad-request"],
  ["unknown id", { pkg: QUICK, id: "ghost", surface: "composer.actions" }, 404, "not-found"],
  ["id on the wrong surface", { pkg: QUICK, id: "translate", surface: "message.actions" }, 404, "not-found"],
  ["unknown package", { pkg: "nope", id: "x", surface: "panel" }, 404, "not-found"],
  ["context field over 16 KiB", { pkg: QUICK, id: "translate", surface: "composer.actions", context: { clipboard: "x".repeat(17000) } }, 413, "too-large"],
  ["panel without handler for the action", { pkg: USAGE, id: "plain", surface: "panel", action: "x" }, 409, "no-handler"],
]) {
  const r = await invoke(body, headers);
  check(r.status === status && r.json?.error?.code === code, `${label} -> ${r.status} ${r.json?.error?.code}`);
}
const huge = await post("/dsh-go/v1/invoke", JSON.stringify({ v: 1, pkg: QUICK, id: "translate", surface: "composer.actions", pad: "x".repeat(70000) }), { "content-type": "application/json" });
check(huge.status === 413, `body over 64 KiB -> ${huge.status}`);
const plain = await post("/dsh-go/v1/invoke", "{}", { "content-type": "text/plain" });
check(plain.status === 415, `text/plain -> ${plain.status}`);
const getInv = await get("/dsh-go/v1/invoke");
check(getInv.status === 405, `GET invoke -> ${getInv.status}`);

// ------------------------------------------------------------------ deferred results (§4.7)
section("deferred results");
const dws = await wsConnect(C);
dws.send({ t: "hello", v: [1], locale: "en" });
const dwel = await dws.next((m) => m.t === "welcome");
check(typeof dwel?.conn === "string" && dwel.conn.length >= 16, `welcome carries a connection id (${dwel?.conn?.length} chars)`);
const bystander = await wsConnect(C);
bystander.send({ t: "hello", v: [1] });
const bwel = await bystander.next((m) => m.t === "welcome");
check(bwel?.conn !== dwel?.conn, "each connection gets its own id");
const later = async (action, extra = {}) => { await sleep(300); return invoke({ pkg: QUICK, id: "tools", surface: "panel", action, stream: dwel.conn, ...extra }); };
const quickState = async () => (await get("/native-fixture/state")).json?.quick ?? { aborted: [] };

const d1 = await later("later");
check(d1.status === 200 && d1.json?.effects?.length === 0 && typeof d1.json?.pending?.id === "string" && d1.json.pending.timeoutMs === 5000 && d1.ms < 1000,
  `pending answer within the window: ${JSON.stringify(d1.json?.pending)} in ${d1.ms} ms`);
check([...(d1.json?.pending?.label ?? "")].length === 16 && d1.json.issues.some((i) => i.code === "too-long"), `label truncated to 16 (${d1.json?.pending?.label})`);
const done1 = await dws.next((m) => m.pending === d1.json?.pending?.id, 3000);
check(done1?.t === "done" && JSON.stringify(done1.effects) === '[{"type":"insert","text":"later"},{"type":"toast","text":"完成"},{"type":"patch","id":"tools","data":{"note":"deferred"}}]',
  `done on the initiating connection: ${JSON.stringify(done1?.effects)}`);
check(done1?.issues?.some((i) => i.code === "bad-effect" && i.message.includes("deferred")), "link dropped from a deferred result (only insert / copy / toast / patch)");
check(await bystander.next((m) => m.pending === d1.json?.pending?.id, 300) === undefined, "other connections never see it");
for (const [label, stream] of [["no stream", undefined], ["unknown stream", "nope"], ["a closed stream", "x".repeat(16)]]) {
  await sleep(300);
  const r = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "later", ...(stream === undefined ? {} : { stream }) });
  check(r.status === 409 && r.json?.error?.code === "no-stream", `${label} -> ${r.status} ${r.json?.error?.code}`);
}
const d2 = await later("fast");
const done2 = await dws.next((m) => m.pending === d2.json?.pending?.id, 2000);
check(d2.json?.pending && !("label" in d2.json.pending) && d2.json.pending.timeoutMs === 30000 && done2?.t === "done" && done2.effects[0]?.text === "fast",
  `pending: true -> default 30 s, result delivered (${done2?.t})`);
const d3 = await later("clamp");
const done3 = await dws.next((m) => m.pending === d3.json?.pending?.id, 2000);
check(d3.json?.pending?.timeoutMs === 60000 && done3?.t === "done", `timeoutMs clamped to ${d3.json?.pending?.timeoutMs}`);
const d4 = await later("forever");
const t4 = Date.now();
const void4 = await dws.next((m) => m.pending === d4.json?.pending?.id, 3000);
check(void4?.t === "void" && void4.reason === "timeout" && Date.now() - t4 >= 1000, `expired after ${Date.now() - t4} ms -> void timeout`);
check(await dws.next((m) => m.pending === d4.json?.pending?.id, 400) === undefined, "result arriving after expiry is dropped");
check((await quickState()).aborted.includes("forever"), "event.signal / result signal aborted on expiry");
const d5 = await later("fail");
check((await dws.next((m) => m.pending === d5.json?.pending?.id, 2000))?.reason === "error", "rejected result -> void error");
const d5b = await later("failEager");
check((await dws.next((m) => m.pending === d5b.json?.pending?.id, 2000))?.reason === "error", "eager rejected Promise -> void error (no unhandled rejection)");
const d6 = await later("nowork");
check(d6.status === 200 && d6.json?.pending === undefined && d6.json.issues[0]?.code === "bad-effect", "pending without result -> no pending, bad-effect");
const d7 = await later("eager");
const done7 = await dws.next((m) => m.pending === d7.json?.pending?.id, 2000);
check(done7?.effects?.[0]?.text === "eager" && d7.json.issues.some((i) => i.message.includes("ignored next to pending")), "effects next to pending are ignored (issue), eager Promise result delivered");
// cancel
const ha = await later("hold", { value: { tag: "a" } });
bystander.send({ t: "cancel", pending: ha.json?.pending?.id });
check(await dws.next((m) => m.pending === ha.json?.pending?.id, 400) === undefined, "cancel from another connection is ignored");
dws.send({ t: "cancel", pending: ha.json?.pending?.id });
const voidA = await dws.next((m) => m.pending === ha.json?.pending?.id, 2000);
check(voidA?.t === "void" && voidA.reason === "cancelled" && (await quickState()).aborted.includes("hold:a"), "cancel -> void cancelled, plugin sees abort");
dws.send({ t: "cancel", pending: ha.json?.pending?.id });
check(await dws.next((m) => m.pending === ha.json?.pending?.id, 300) === undefined, "settles exactly once");
// per-plugin limit
const hb = await later("hold", { value: { tag: "b" } });
const hc = await later("hold", { value: { tag: "c" } });
const hd = await later("hold", { value: { tag: "d" } });
check(hb.json?.pending && hc.json?.pending && hd.status === 429 && hd.json?.error?.code === "too-many-pending" && hd.headers["retry-after"] === "1",
  `third concurrent pending -> ${hd.status} ${hd.json?.error?.code}`);
const usageWhileFull = await invoke({ pkg: USAGE, id: "usage", surface: "panel", action: "bump", scope: { sessionId: "s1" } });
check(usageWhileFull.status === 200, "the limit is per plugin");
// disconnect voids
dws.close();
await dws.closed;
await sleep(200);
const ab = (await quickState()).aborted;
check(ab.includes("hold:b") && ab.includes("hold:c"), "closing the connection aborts its pendings");
const dws2 = await wsConnect(C);
dws2.send({ t: "hello", v: [1] });
const dwel2 = await dws2.next((m) => m.t === "welcome");
check(await dws2.next((m) => m.pending === hb.json?.pending?.id || m.pending === hc.json?.pending?.id, 500) === undefined, "no re-delivery after reconnect");
await sleep(300);
const he = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "hold", value: { tag: "e" }, stream: dwel2.conn });
check(he.status === 200 && he.json?.pending, "slots freed after the disconnect");
const oldConn = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "later", stream: dwel.conn });
check(oldConn.status === 409 && oldConn.json?.error?.code === "no-stream", "the old connection id is dead");
dws2.send({ t: "cancel", pending: he.json?.pending?.id });
await dws2.next((m) => m.pending === he.json?.pending?.id, 1000);
dws2.close();
bystander.close();

// ------------------------------------------------------------------ assets
section("assets");
const dot = await get(`/dsh-go/v1/assets/${STATIC}/img/dot.png`);
check(dot.status === 200 && dot.headers["content-type"] === "image/png" && dot.raw.length === 69 && dot.headers.etag, `png -> ${dot.status} ${dot.headers["content-type"]} ${dot.raw.length} B`);
const dot304 = await get(`/dsh-go/v1/assets/${STATIC}/img/dot.png`, { "if-none-match": dot.headers.etag });
check(dot304.status === 304, `If-None-Match -> ${dot304.status}`);
for (const p of [`${STATIC}/notes.txt`, `${STATIC}/img%2F..%2F..%2Fpackage.json`, `${STATIC}/%2E%2E/package.json`, `${QUICK}/x.png`, `${STATIC}/img/missing.png`]) {
  const r = await get(`/dsh-go/v1/assets/${p}`);
  check((r.status === 404 || r.status === 400) && !r.headers["content-type"]?.startsWith("image/"), `asset ${p} -> ${r.status} (refused)`);
}

// ------------------------------------------------------------------ isolation + degradation
section("misbehaving plugin: contained, then degraded");
const watch = await wsConnect(C);
watch.send({ t: "hello", v: [1] });
await watch.next((m) => m.t === "welcome");
const okFirst = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "good" });
check(okFirst.status === 200, "a clean invoke resets the violation streak");
watch.send({ t: "sub", sub: "boom", pkg: QUICK, id: "boom" });
const boomEnd = await watch.next((m) => m.sub === "boom");
check(boomEnd?.t === "end" && boomEnd.reason === "error", `data() throws -> end error (violation 1): ${JSON.stringify(boomEnd)}`);
const vb = await get(`/dsh-go/v1/views/${QUICK}/boom?${CAPS}`);
check(vb.status === 500 && vb.json?.error?.code === "plugin-error", `view() throws -> ${vb.status} ${vb.json?.error?.code} (violation 2)`);
const vh = await get(`/dsh-go/v1/views/${QUICK}/huge?${CAPS}`);
check(vh.status === 500 && vh.json?.error?.code === "invalid-view", `view over 32 KiB -> ${vh.status} ${vh.json?.error?.code} (violation 3)`);
const th = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "throws" });
check(th.status === 500 && th.json?.error?.code === "plugin-error", `handler throws -> ${th.status} (violation 4)`);
const usageMid = await get(`/dsh-go/v1/views/${USAGE}/plain?${CAPS}`);
check(usageMid.status === 200, "other plugins keep working meanwhile");
const ga = await invoke({ pkg: QUICK, id: "tools", surface: "panel", action: "garbage" });
check(ga.status === 200 && ga.json?.effects?.length === 0 && ga.json.issues[0]?.code === "bad-effect", "handler returns 42 -> no effects (violation 5)");
const changed = await watch.next((m) => m.t === "changed", 2000);
check(changed !== undefined, "stream pushes changed after degradation");
const cd = await contributions();
const dq = cd.json?.plugins.find((p) => p.pkg === QUICK);
check(dq?.state === "degraded" && dq.native === false && dq.contributes.panels.length === 0 && dq.issues.some((i) => i.code === "degraded"), `quick is degraded: state=${dq?.state} native=${dq?.native}`);
check(dq?.issues.some((i) => i.code === "violation" && i.count >= 5), "violation issue carries the count");
const dv = await get(`/dsh-go/v1/views/${QUICK}/tools?${CAPS}`);
check(dv.status === 409 && dv.json?.error?.code === "degraded", `degraded view -> ${dv.status} ${dv.json?.error?.code}`);
const di = await invoke({ pkg: QUICK, id: "translate", surface: "composer.actions" });
check(di.status === 409 && di.json?.error?.code === "degraded", `degraded invoke -> ${di.status}`);
watch.send({ t: "sub", sub: "dq", pkg: QUICK, id: "tools" });
check((await watch.next((m) => m.sub === "dq"))?.reason === "degraded", "degraded sub -> end degraded");
const uok = await invoke({ pkg: USAGE, id: "usage", surface: "panel", action: "bump", scope: { sessionId: "s1" } });
check(uok.status === 200, "usage plugin unaffected");
const inv = await get("/dsh-go/v1/inventory");
check(inv.status === 200 && inv.json?.v === 1 && inv.json.routeGuard === true, `inventory still fine (routeGuard=${inv.json?.routeGuard})`);
const attr = (await get("/native-fixture/attribution")).json;
check(typeof attr?.error === "string" && attr.error.includes("plugin context"), `service used without a plugin context throws: ${attr?.error}`);

// ------------------------------------------------------------------ cache invalidation
section("plugin disable / enable");
watch.drain();
const beforeToggle = await contributions();
const off = await get("/native-fixture/toggle?entry=fx-quick&disabled=1");
check(off.status === 200 && off.json?.disabled === true, `disable fx-quick -> ${JSON.stringify(off.json)}`);
check(await watch.next((m) => m.t === "changed", 2000) !== undefined, "changed pushed on disable");
const afterOff = await contributions();
check(!afterOff.json?.plugins.some((p) => p.pkg === QUICK) && afterOff.json.rev !== beforeToggle.json.rev, `disabled plugin gone, rev ${beforeToggle.json?.rev} -> ${afterOff.json?.rev}`);
const offInv = await invoke({ pkg: QUICK, id: "translate", surface: "composer.actions" });
check(offInv.status === 404, `invoke on a disabled plugin -> ${offInv.status}`);
watch.send({ t: "sub", sub: "su", pkg: USAGE, id: "usage", scope: { sessionId: "tog" } });
await watch.next((m) => m.sub === "su");
const offUsage = await get("/native-fixture/toggle?entry=fx-static&disabled=1");
check(offUsage.json?.disabled === true, "disable fx-static");
const on = await get("/native-fixture/toggle?entry=fx-quick&disabled=0");
check(on.status === 200 && on.json?.disabled === false, `re-enable fx-quick -> ${JSON.stringify(on.json)}`);
await sleep(600);
const afterOn = await contributions();
const rq = afterOn.json?.plugins.find((p) => p.pkg === QUICK);
check(rq?.state === "ok" && rq.native === true && !rq.issues.some((i) => i.code === "degraded"), `re-enabled plugin is back and no longer degraded (state=${rq?.state})`);
check(!afterOn.json?.plugins.some((p) => p.pkg === STATIC), "fx-static disabled -> gone");
const tr2 = await invoke({ pkg: QUICK, id: "translate", surface: "composer.actions", context: { clipboard: "again" } });
check(tr2.status === 200 && tr2.json?.effects?.[0]?.text?.startsWith("EN(again)"), "handlers re-registered after reload");
await get("/native-fixture/toggle?entry=fx-static&disabled=0");
watch.close();
ws2.close();

// feed linger: after the last subscriber leaves, data() is cancelled
if (!SHIPPED) {
  const before = (await get("/native-fixture/state")).json;
  await sleep(2200);
  const after = (await get("/native-fixture/state")).json;
  check(after.dataCancels > before.dataCancels && after.feeds.length === 0, `feeds cancelled after linger (cancels ${before.dataCancels} -> ${after.dataCancels}, live ${after.feeds.length})`);
}

// rate limit last (it drains the bucket)
section("rate limit");
const burst = await Promise.all(Array.from({ length: 12 }, () => invoke({ pkg: USAGE, id: "usage", surface: "panel", action: "bump", scope: { sessionId: "rl" } })));
const limited = burst.filter((r) => r.status === 429);
check(limited.length > 0 && limited.every((r) => r.json?.error?.code === "rate-limited" && Number(r.headers["retry-after"]) >= 1), `12 concurrent invokes -> ${burst.filter((r) => r.status === 200).length} ok, ${limited.length} × 429 with retry-after`);

console.log(`== native: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
