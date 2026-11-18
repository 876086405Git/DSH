// Native plugins v1.2 (docs/design/native-plugins-protocol.md §11) against a running `dsh web` with
// dsh-go-bridge and runtime/tests/fixtures/native-voice (runtime/tests/run-native-tests.sh).
// Node built-ins only.
//
//   node runtime/tests/native-capabilities-live.mjs <base-url> <launch-token>
//
// DSH_GO_BRIDGE_LIB points at the bridge's lib/native directory when the repo is not around
// (runtime/test-host.sh runs it inside the rootfs).
import http from "node:http";
import { randomBytes } from "node:crypto";
import { pathToFileURL } from "node:url";

const WS = await import(process.env.DSH_GO_BRIDGE_LIB
  ? pathToFileURL(`${process.env.DSH_GO_BRIDGE_LIB.replace(/\/$/, "")}/ws.js`).href
  : new URL("../bridge/dsh-go-bridge/lib/native/ws.js", import.meta.url));
const [baseArg, token] = process.argv.slice(2);
if (!baseArg || !token) {
  console.error("usage: native-capabilities-live.mjs <base-url> <launch-token>");
  process.exit(2);
}
const base = new URL(baseArg);
const PKG = "dsh-go-fixture-voice";
const CAPS = "v=1&app=0.10.0&locale=zh-CN";
const ALL = ["audio", "voice", "micro", "overlay"];

let failed = 0;
let passed = 0;
const check = (ok, msg) => {
  if (ok) { passed++; console.log(`  \x1b[32mPASS\x1b[0m ${msg}`); } else { failed++; console.log(`  \x1b[31mFAIL\x1b[0m ${msg}`); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const section = (s) => console.log(`== ${s}`);

function request(method, path, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const req = http.request({
      host: base.hostname, port: base.port, method, path,
      headers: { host: base.host, ...(payload ? { "content-type": "application/json", "content-length": Buffer.byteLength(payload) } : {}), ...headers },
    }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw = Buffer.concat(chunks);
        let json;
        try { json = JSON.parse(raw.toString("utf8")); } catch {}
        resolve({ status: res.statusCode, headers: res.headers, raw, json });
      });
    });
    req.on("error", reject);
    req.setTimeout(40000, () => req.destroy(new Error(`timeout ${method} ${path}`)));
    if (payload) req.write(payload);
    req.end();
  });
}

function wsConnect(headers) {
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
      const deliver = (msg) => {
        msg.at = Date.now();
        const i = waiters.findIndex((w) => w.pred(msg));
        if (i >= 0) { const [w] = waiters.splice(i, 1); clearTimeout(w.timer); w.resolve(msg); } else queue.push(msg);
      };
      socket.on("data", (d) => {
        buf = Buffer.concat([buf, d]);
        while (buf.length >= 2) {
          const op = buf[0] & 0x0f;
          let len = buf[1] & 0x7f;
          let off = 2;
          if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
          if (buf.length < off + len) return;
          const payload = buf.subarray(off, off + len);
          buf = buf.subarray(off + len);
          if (op === 0x1) deliver(JSON.parse(payload.toString("utf8")));
          else if (op === 0x9 && !socket.destroyed) socket.write(WS.encodeFrame(0xa, payload, { mask: true }));
        }
      });
      socket.on("error", () => {});
      resolve({
        status: res.statusCode,
        queue,
        pause() { socket.pause(); }, resume() { socket.resume(); },
        send(obj) { if (!socket.destroyed) socket.write(WS.encodeFrame(0x1, JSON.stringify(obj), { mask: true })); },
        close() { socket.destroy(); },
        next(pred = () => true, ms = 3000) {
          const i = queue.findIndex(pred);
          if (i >= 0) return Promise.resolve(queue.splice(i, 1)[0]);
          return new Promise((r) => {
            const w = { pred, resolve: r };
            w.timer = setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); r(undefined); }, ms);
            waiters.push(w);
          });
        },
      });
    });
    req.end();
  });
}

section("login");
const login = await request("GET", `/?token=${encodeURIComponent(token)}`);
const setCookie = [].concat(login.headers["set-cookie"] ?? []).find((c) => c.startsWith("dsh-auth-"));
check(login.status === 303 && setCookie, `GET /?token -> ${login.status}`);
if (!setCookie) process.exit(1);
const C = { cookie: setCookie.split(";")[0] };
const get = (path, headers = {}) => request("GET", path, { headers: { ...C, ...headers } });
const invoke = (body) => request("POST", "/dsh-go/v1/invoke", { headers: C, body: { v: 1, locale: "zh-CN", ...body } });
await sleep(400);

section("declarations: kept for every app, ready only for an app that has the feature");
const plain = await get(`/dsh-go/v1/contributions?${CAPS}`);
const row = plain.json?.plugins?.find((p) => p.pkg === PKG);
check(row?.state === "ok" && JSON.stringify(row.capabilities) === JSON.stringify(ALL), `capabilities ${JSON.stringify(row?.capabilities)}`);
check(JSON.stringify(row?.contributes.media) === '[{"id":"speech"}]' && JSON.stringify(row?.contributes.micro) === '[{"id":"caption"}]', "media and micro declared");
check(JSON.stringify(row?.contributes.overlays) === '[{"id":"line","channel":"caption","text":"朗读中"}]', `overlay ${JSON.stringify(row?.contributes.overlays)}`);
const readPlain = row?.contributes["message.actions"].find((a) => a.id === "read");
check(readPlain?.ready === false && JSON.stringify(readPlain.requires) === '["audio"]', "read: requires audio, not ready without it");
check(row?.contributes.panels[0]?.micro === "caption", "panel names its caption channel");
const featured = await get(`/dsh-go/v1/contributions?${CAPS}&features=${ALL.join(",")}`);
const readReady = featured.json?.plugins?.find((p) => p.pkg === PKG)?.contributes["message.actions"].find((a) => a.id === "read");
check(readReady?.ready === true, "read is ready for an app with audio");
check(plain.json?.rev !== featured.json?.rev || plain.headers.etag !== undefined, "separate cache entries per feature set");

section("an app without features: v1.1 welcome, capability effects never run");
const old = await wsConnect(C);
old.send({ t: "hello", v: [1] });
const oldWelcome = await old.next((m) => m.t === "welcome");
check(oldWelcome && oldWelcome.features === undefined, "welcome has no features");
const oldTap = await invoke({ pkg: PKG, id: "read", surface: "message.actions", scope: { sessionId: "s1" }, stream: oldWelcome?.conn });
check(oldTap.status === 409 && oldTap.json?.error?.code === "unsupported", `tap on read -> ${oldTap.status} ${oldTap.json?.error?.code}`);
old.send({ t: "micro.sub", sub: "m1", pkg: PKG, id: "caption" });
check((await old.next((m) => m.t === "micro.end"))?.reason === "unsupported", "micro refused without the feature");
old.close();

section("an app with features: lease, media, events");
const ws = await wsConnect(C);
ws.send({ t: "hello", v: [1], locale: "zh-CN", features: [...ALL, "teleport"] });
const welcome = await ws.next((m) => m.t === "welcome");
check(JSON.stringify(welcome?.features) === JSON.stringify(ALL), `welcome.features ${JSON.stringify(welcome?.features)}`);
const tap = await invoke({ pkg: PKG, id: "read", surface: "message.actions", scope: { sessionId: "s1", messageId: "m42" }, stream: welcome?.conn });
const [play, voice, overlay] = tap.json?.effects ?? [];
check(tap.status === 200 && play?.type === "audio" && play.op === "play" && play.src === "media:speech" && play.key === "m_m42", `play effect ${JSON.stringify(play)}`);
check(typeof play?.lease === "string" && play.lease.length >= 32 && voice?.lease === play.lease && overlay?.lease === play.lease, "one unguessable lease for the three roles");
const mediaPath = `/dsh-go/v1/media/${PKG}/speech?lease=${encodeURIComponent(play?.lease ?? "")}&key=m_m42`;
const anon = await request("GET", mediaPath);
check(anon.status === 401, `media without the cookie -> ${anon.status}`);
const evil = await get(mediaPath, { origin: "http://evil.example" });
check(evil.status === 403, `media from a cross-site Origin -> ${evil.status}`);
const wrongKey = await get(mediaPath.replace("key=m_m42", "key=other"));
check(wrongKey.status === 404, `media with another key -> ${wrongKey.status}`);
const extra = await get(`${mediaPath}&url=http://127.0.0.1:8765/`);
check(extra.status === 400, `media with a URL parameter -> ${extra.status}`);
const media = await get(mediaPath);
check(media.status === 200 && media.headers["content-type"] === "audio/wav" && media.raw.subarray(0, 4).toString() === "RIFF" && media.raw.length === 44 + 9600, `media -> ${media.status} ${media.headers["content-type"]} ${media.raw.length} B`);
check(media.headers["cache-control"] === "no-store" && media.headers["x-content-type-options"] === "nosniff", "no-store, nosniff");

section("micro: its own channel, at most 10 a second, latest only");
ws.send({ t: "micro.sub", sub: "m1", pkg: PKG, id: "caption", scope: { sessionId: "s1" } });
const frames = [];
const until = Date.now() + 1500;
while (Date.now() < until) {
  const m = await ws.next((x) => x.t === "micro.data" && x.sub === "m1", until - Date.now());
  if (m) frames.push(m);
}
const revisions = frames.map(f => f.rev.split("."));
check(frames.length >= 8 && frames.length <= 17, `${frames.length} updates in 1.5 s from a 50 Hz producer`);
check(new Set(revisions.map(r => r[0])).size === 1 && revisions.every((r, i) => i === 0 || Number(r[1]) === Number(revisions[i - 1][1]) + 1), "one epoch, unique contiguous revisions in receive order");
check(frames.every((f) => /^[0-9a-f]{16}\.[1-9][0-9]*$/.test(f.rev) && typeof f.data.text === "string" && Object.keys(f.data).every((k) => k === "text" || k === "progress")), "rev <epoch>.<seq>, the small model only");
ws.send({ t: "micro.unsub", sub: "m1" });
await sleep(300);
const lateFrames = ws.queue.filter((m) => m.t === "micro.data" && m.sub === "m1" && m.at > Date.now() - 150);
check(lateFrames.length === 0, "nothing after micro.unsub");

// A paused reader may decode several correctly throttled sends together.
const delayed = await wsConnect(C);
delayed.send({ t: "hello", v: [1], locale: "zh-CN", features: ALL });
await delayed.next(m => m.t === "welcome");
delayed.send({ t: "micro.sub", sub: "paused", pkg: PKG, id: "caption", scope: { sessionId: "paused-reader" } });
const buffered = [await delayed.next(m => m.t === "micro.data" && m.sub === "paused")];
delayed.pause(); await sleep(350); delayed.resume();
while (buffered.length < 5) {
  const frame = await delayed.next(m => m.t === "micro.data" && m.sub === "paused");
  if (!frame) break;
  buffered.push(frame);
}
const bufferedRevisions = buffered.filter(Boolean).map(f => f.rev.split("."));
check(bufferedRevisions.length === 5 && new Set(bufferedRevisions.map(r => r[0])).size === 1 && bufferedRevisions.every((r, i) => i === 0 || Number(r[1]) === Number(bufferedRevisions[i - 1][1]) + 1), "paused reader retains unique contiguous revisions without loss");
delayed.send({ t: "micro.unsub", sub: "paused" }); delayed.close();

section("capability events reach the plugin; terminals end the lease");
ws.send({ t: "cap.event", lease: play?.lease, seq: 1, event: "voice.speechStart" });
await sleep(50);
const afterSpeech = await get(mediaPath);
check(afterSpeech.status === 404, `speechStart ends the audio role: media -> ${afterSpeech.status}`);
ws.send({ t: "cap.event", lease: play?.lease, seq: 2, event: "voice.speechEnd" });
ws.send({ t: "cap.event", lease: play?.lease, seq: 3, event: "voice.stopped", reason: "speech-ended" });
ws.send({ t: "cap.event", lease: play?.lease, seq: 4, event: "overlay.closed", reason: "audio-ended" });
ws.send({ t: "cap.event", lease: play?.lease, seq: 5, event: "overlay.closed" });
ws.send({ t: "cap.event", lease: "forged", seq: 6, event: "audio.ended" });
await sleep(150);
const ev = await invoke({ pkg: PKG, id: "events", surface: "message.actions", scope: { sessionId: "s1" } });
const state = JSON.parse(ev.json?.effects?.[0]?.text ?? "{}");
check(JSON.stringify(state.events) === JSON.stringify(["voice.speechStart@s1", "voice.speechEnd@s1", "voice.stopped@s1", "overlay.closed@s1"]), `plugin heard ${JSON.stringify(state.events)}`);
check(state.media === 1 && JSON.stringify(state.keys) === '["m_m42"]', `media made once, for its key (${state.media})`);
ws.send({ t: "cap.event", lease: play?.lease, seq: 7, event: "audio.ended" });
await sleep(100);
const after = await invoke({ pkg: PKG, id: "events", surface: "message.actions", scope: { sessionId: "s1" } });
check(JSON.parse(after.json?.effects?.[0]?.text ?? "{}").events?.length === 4, "a revoked lease takes no more events");

section("disconnect revokes");
const tap2 = await invoke({ pkg: PKG, id: "read", surface: "message.actions", scope: { sessionId: "s1", messageId: "m43" }, stream: welcome?.conn });
const lease2 = tap2.json?.effects?.[0]?.lease;
ws.close();
await sleep(200);
const gone = await get(`/dsh-go/v1/media/${PKG}/speech?lease=${encodeURIComponent(lease2 ?? "")}&key=m_m43`);
check(lease2 && gone.status === 404, `media after the socket closed -> ${gone.status}`);

console.log(`== native v1.2 (live): ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
