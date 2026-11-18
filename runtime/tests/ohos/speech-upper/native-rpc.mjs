// Actual frozen 1216 SpeechPlugin + OhosPcmStream/queue. Only Flutter transport
// and AudioRenderer OS calls are fixture boundaries; no real device or codec.
import fs from 'node:fs';
import readline from 'node:readline';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import http from 'node:http';
const root = resolve(process.argv[2]), mode = process.argv[3];
const { pcmFixture, deferred } = await import(pathToFileURL(resolve(root, 'runtime/tests/ohos/pcm-stream-fixture.mjs')).href);
const opening = deferred();
const options = mode === 'create-fail' ? { create() { throw Error('explicit OS create failure'); } }
  : mode === 'start-fail' ? { start() { throw Error('explicit OS start failure'); } }
  : mode === 'format-mismatch' ? { format: { channels: 2 } }
  : mode === 'pending-start' ? { start: () => opening.promise } : {};
const native = pcmFixture(options), events = [], methodCalls = [];
let bridge, bridgeServer, bridgeUrl, bridgeRequests = 0, providerRequests = 0, providerAborts = 0;
let audioController, pcmEof = false, bridgeSha256;
if (process.argv[4]) {
  const path = resolve(process.argv[4]);
  bridgeSha256 = createHash('sha256').update(fs.readFileSync(path)).digest('hex');
  const { createSpeechRoutes } = await import(pathToFileURL(path).href);
  const send = (res, status, value) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(value)); };
  const ctx = { get(name) { return name === 'credentials' ? { async resolve() { return { value: 'explicit-local-fixture' }; } } : undefined; } };
  bridge = createSpeechRoutes(ctx, { send, fetch: async (_url, request) => {
    providerRequests++;
    const body = new ReadableStream({
      start(controller) {
        audioController = controller;
        controller.enqueue(Uint8Array.from([1, 2, 3]));
        request.signal.addEventListener('abort', () => {
          providerAborts++;
          if (!pcmEof) { try { controller.error(Error('fixture upstream aborted')); } catch {} }
        }, { once: true });
      },
    });
    return { ok: true, status: 200, headers: new Headers({ 'content-type': 'audio/pcm' }), body };
  } });
  bridgeServer = http.createServer(async (req, res) => {
    bridgeRequests++;
    if (!await bridge.handle(req, res, new URL(req.url, 'http://localhost').pathname)) send(res, 404, {});
  });
  await new Promise(resolveReady => bridgeServer.listen(0, '127.0.0.1', resolveReady));
  bridgeUrl = `http://127.0.0.1:${bridgeServer.address().port}`;
}
let methods;
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
class MethodChannel {
  constructor(messenger, name) { this.messenger = messenger; this.name = name; methods = this; }
  setMethodCallHandler(handler) { this.handler = handler; }
  invokeMethod(method, args) {
    const event = { method, args: Object.fromEntries(args) };
    events.push(event); emit({ event });
  }
}
const Plugin = native.load(resolve(root, 'app/ohos/entry/src/main/ets/plugins/SpeechPlugin.ets'), {
  '@ohos/flutter_ohos': { MethodChannel },
  '@ohos.app.ability.UIAbility': { default: class UIAbility {} },
}).default;
const plugin = new Plugin(), ability = {}, engine = { getBinaryMessenger: () => ({}) };
plugin.onAttachedToEngine(engine); plugin.onAttachedToAbility({ getAbility: () => ability }); Plugin.onForeground(ability);
const pump = setInterval(() => {
  for (const renderer of native.renderers) {
    if (!renderer.released && renderer.state === native.audio.AudioState.STATE_RUNNING && renderer.listeners.has('writeData')) {
      renderer.pump(8);
    }
  }
}, 2);
function status() {
  return { mode, methodCalls, nativeCalls: native.calls, events,
    bridgeRequests, providerRequests, providerAborts, pcmEof,
    rendererCount: native.renderers.length,
    renderers: native.renderers.map(renderer => ({ starts: renderer.starts, pauses: renderer.pauses,
      flushes: renderer.flushes, stops: renderer.stops, releases: renderer.releases,
      committed: renderer.committed.map(bytes => [...bytes]) })) };
}
async function call(method, args = {}) {
  methodCalls.push({ method, id: args.id, bytes: args.bytes?.length });
  if (Array.isArray(args.bytes)) args.bytes = Uint8Array.from(args.bytes);
  return await new Promise((resolveReply, reject) => methods.handler.onMethodCall({ method, argument: key => args[key] }, {
    success: resolveReply,
    error: (code, message) => reject(Object.assign(Error(message), { code })),
    notImplemented: () => reject(Object.assign(Error('missing'), { code: 'MissingPluginException' })),
  }));
}
const rl = readline.createInterface({ input: process.stdin });
rl.on('line', line => {
  const request = JSON.parse(line);
  (async () => {
    let value;
    if (request.method === 'fixture/status') value = status();
    else if (request.method === 'fixture/release-start') { opening.resolve(); value = null; }
    else if (request.method === 'fixture/release-audio') {
      if (audioController && !pcmEof) { pcmEof = true; audioController.enqueue(Uint8Array.from([4, 5, 6])); audioController.close(); }
      value = null;
    }
    else if (request.method === 'fixture/background') { Plugin.onBackground(ability); value = null; }
    else if (request.method === 'fixture/shutdown') {
      opening.resolve(); await call('stop'); clearInterval(pump); bridge?.dispose();
      if (bridgeServer) { bridgeServer.closeAllConnections(); await new Promise(resolveClosed => bridgeServer.close(resolveClosed)); }
      value = status(); rl.close();
    } else value = await call(request.method, request.args);
    emit({ reply: request.id, value });
  })().catch(error => emit({ reply: request.id, error: error.code ?? 'fixture-error', message: error.message }));
});
const locked = ['app/ohos/entry/src/main/ets/plugins/SpeechPlugin.ets', 'app/ohos/entry/src/main/ets/plugins/OhosPcmStream.ets',
  'app/ohos/entry/src/main/ets/plugins/PcmStreamTypes.ets', 'app/ohos/entry/src/main/ets/plugins/PcmByteQueue.ets',
  'runtime/tests/ohos/pcm-stream-fixture.mjs',
  ...['OhosSpeechPlayback', 'OhosSpeechCall', 'OhosCallCapture', 'CallEnergyGate', 'VoicePcmTap',
      'VoicePcm', 'VoiceTypes', 'VoiceMicLease'].map(name => 'app/ohos/entry/src/main/ets/plugins/' + name + '.ets')];
emit({ ready: true, bridgeUrl, bridgeSha256, inputSha256: Object.fromEntries(locked.map(path => [path,
  createHash('sha256').update(fs.readFileSync(resolve(root, path))).digest('hex')])) });
