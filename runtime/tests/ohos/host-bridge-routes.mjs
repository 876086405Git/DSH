import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

// Real HTTP/WS through Host's bridge, not direct handler calls or mocked credentials.
export async function runBridgeRouteContract({ base, cookie, rpc, WebSocket, out, fixture, ownedSessionId }) {
  const directory = join(out, 'bridge-routes'); await mkdir(directory, { recursive: false });
  const result = { status: 'RUNNING', rows: [], stream: { sent: [], received: [] }, startedUTC: new Date().toISOString(), scope: 'All fixed Dart route templates on a private Host runtime; runtime-capabilities belongs to OH, native media/files belong to bridge; no device media playback or system chooser claim' };
  let socket, closed, wsError; const frames = [], waiters = new Set();
  const persist = () => writeFile(join(directory, 'report.json'), JSON.stringify(result, null, 2) + '\n');
  const check = (condition, message) => assert.ok(condition, message);
  const jsonCode = body => body?.error?.code ?? body?.code ?? null;
  async function request(id, method, path, { body, raw, anonymous = false, headers = {} } = {}) {
    const data = raw ?? (body === undefined ? undefined : Buffer.from(JSON.stringify(body)));
    const row = { id, method, path, authentication: anonymous ? 'none' : 'real-launch-cookie', startUTC: new Date().toISOString(), ...(body === undefined ? {} : { requestBody: body }) };
    if (data) row.requestBytes = { bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') };
    result.rows.push(row);
    try {
      const response = await new Promise((resolve, reject) => {
        const req = http.request(new URL(path, base), { method, headers: { ...(anonymous ? {} : { Cookie: cookie }), ...(data ? { 'content-type': raw ? 'application/octet-stream' : 'application/json', 'content-length': data.length } : {}), ...headers } }, res => {
          const chunks = []; let size = 0;
          res.on('data', bytes => { size += bytes.length; if (size > 2 * 1024 * 1024) res.destroy(new Error('contract response limit')); else chunks.push(bytes); });
          res.on('error', reject); res.on('end', () => resolve({ status: res.statusCode, headers: Object.fromEntries(Object.entries(res.headers).filter(([key]) => key.toLowerCase() !== 'set-cookie')), raw: Buffer.concat(chunks) }));
        });
        req.on('error', reject); req.setTimeout(15000, () => req.destroy(new Error(`contract timeout ${id}`))); req.end(data);
      });
      const filename = `${String(result.rows.length).padStart(2, '0')}-${id}.bin`;
      await writeFile(join(directory, filename), response.raw);
      row.response = { status: response.status, headers: response.headers, bytes: response.raw.length, sha256: createHash('sha256').update(response.raw).digest('hex'), file: filename };
      try { response.json = JSON.parse(response.raw.toString('utf8')); row.response.json = response.json; row.response.errorCode = jsonCode(response.json); } catch { row.response.text = response.raw.toString('utf8'); }
      row.endUTC = new Date().toISOString(); await persist(); return response;
    } catch (error) { row.error = { name: error.name, message: error.message }; row.endUTC = new Date().toISOString(); await persist(); throw error; }
  }
  // This is the production session API over authenticated HTTP, not a fixture handler.
  // OH has no image codec: valid content must reach the explicit codec refusal.
  const attachments = { status: 'RUNNING', cases: [], scope: 'owner full-reference HTTP; no reader authorization or OH codec-success claim' };
  result.attachments = attachments;
  async function attachmentCase(id, sessionId, reference, code, reason, { legacy = false, anonymous = false } = {}) {
    const rpcId = randomUUID();
    const body = { type: 'client-request', rpcId, method: 'session/attachment', payload: { args: {
      request: legacy ? { sessionId, attachmentId: reference.attachmentId } : { sessionId, attachment: reference },
    } } };
    const response = await request('attachment-' + id, 'POST', '/api/session/attachment', { body, anonymous });
    const row = { id, sessionId, expectedCode: code, expectedReason: reason ?? null, passed: false };
    attachments.cases.push(row);
    if (anonymous) {
      check([401, 403].includes(response.status), 'anonymous attachment must be rejected by real authentication');
    } else {
      check(response.status === 200, 'attachment RPC uses the real HTTP result envelope: ' + id);
      check(response.json?.type === 'server-response' && response.json.rpcId === rpcId, 'attachment RPC identity: ' + id);
      const failure = response.json.result;
      check(failure?.ok === false && failure.error?.code === code, 'attachment error code: ' + id);
      if (reason !== undefined) check(failure.error.details?.reason === reason, 'attachment error reason: ' + id);
      row.actualCode = failure.error.code;
      row.actualReason = failure.error.details?.reason ?? null;
    }
    row.passed = true; await persist();
  }
  function nextFrame(predicate, description) {
    const index = frames.findIndex(predicate); if (index >= 0) return Promise.resolve(frames.splice(index, 1)[0]);
    if (wsError) return Promise.reject(wsError);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve: frame => { clearTimeout(waiter.timer); waiters.delete(waiter); resolve(frame); }, reject: error => { clearTimeout(waiter.timer); waiters.delete(waiter); reject(error); } };
      waiter.timer = setTimeout(() => waiter.reject(new Error(`native stream timeout: ${description}`)), 15000); waiters.add(waiter);
    });
  }
  function send(frame) { result.stream.sent.push(frame); socket.send(JSON.stringify(frame)); }
  async function closeStream() {
    if (!socket || socket.readyState === WebSocket.CLOSED) return;
    let forced = false;
    const timer = setTimeout(() => { forced = true; socket.terminate(); }, 1000);
    socket.close(1000, 'contract complete'); await closed; clearTimeout(timer); result.stream.forcedTermination = forced;
  }
  try {
    const cap = await request('runtime-capabilities', 'GET', '/dsh-go/v1/runtime-capabilities');
    check(cap.status === 200 && cap.json?.v === 1 && cap.json.platform === 'openharmony' && cap.json.nodeVersion === '24.22.1', 'OH authenticated capability contract');
    const inventory = await request('inventory', 'GET', '/dsh-go/v1/inventory');
    check(inventory.status === 200 && inventory.json?.v === 1 && typeof inventory.json.bridge === 'string' && inventory.json.routeGuard === true, 'bridge inventory and its real loopback routeGuard');
    const anon = await request('inventory-anonymous', 'GET', '/dsh-go/v1/inventory', { anonymous: true });
    check([401, 403].includes(anon.status), 'anonymous inventory must be guarded');
    const canary = await request('guard-canary-authenticated', 'GET', '/dsh-go-guard-canary'); check(canary.status === 204, 'actual canary registered');
    const canaryAnon = await request('guard-canary-anonymous', 'GET', '/dsh-go-guard-canary', { anonymous: true }); check([401, 403].includes(canaryAnon.status), 'anonymous canary guarded');

    const listing = await request('plugin-config-list', 'GET', '/dsh-go/v1/plugin-config');
    check(listing.status === 200 && Array.isArray(listing.json?.entries), 'plugin-config list');
    check(listing.json.entries.some(entry => entry.entryId === fixture.entryId && entry.configurable && entry.writable && entry.owner === 'installed' && entry.bundle === 'dsh-go-fixture-host-config-bundle'), 'declared installed fixture is configurable and writable');
    check(listing.json.entries.some(entry => entry.entryId === fixture.nativeEntryId && entry.configurable === false && entry.owner === 'overlay'), 'absolute native fixture remains outside editable bundle authority');
    const entryPath = `/dsh-go/v1/plugin-config/${encodeURIComponent(fixture.entryId)}`;
    const config = await request('plugin-config-read', 'GET', entryPath); check(config.status === 200 && config.json?.value?.label === 'initial-label' && typeof config.json.revision === 'string', 'read real fixture config');
    const changed = await request('plugin-config-write', 'POST', entryPath, { body: { revision: config.json.revision, ops: [{ op: 'set', path: ['label'], value: 'changed-label' }] } });
    check(changed.status === 200 && changed.json?.value?.label === 'changed-label', 'write real fixture config');
    const reread = await request('plugin-config-reread', 'GET', entryPath); check(reread.status === 200 && reread.json?.value?.label === 'changed-label', 'configuration readback');

    const deletion = await request('session-deletion-capability', 'GET', '/dsh-go/v1/sessions/deletion');
    check(deletion.status === 200 && deletion.json?.version === 1 && deletion.json.supported === true, 'safe deletion seam available');
    const sessionId = ownedSessionId; check(typeof sessionId === 'string' && sessionId.length > 0, 'completed private session supplied'); result.disposableSession = sessionId;
    const listedBefore = await rpc('session/list', { _request: {} });
    result.sessionListBefore = listedBefore; check(Array.isArray(listedBefore.items) && listedBefore.items.some(item => item.sessionId === sessionId), 'completed private session really listed before deletion');
    const image = fixture.attachments.reference;
    check(image.attachmentId === 'sha256:' + fixture.assetSHA256 && image.bytes === fixture.assetBytes && image.width === 1 && image.height === 1, 'fixed real PNG full reference');
    await attachmentCase('full-reference', sessionId, image, 'session/attachment-invalid', 'OHOS_IMAGE_CODEC_UNAVAILABLE');
    await attachmentCase('missing-object', sessionId, { ...image, attachmentId: fixture.attachments.missingId }, 'session/attachment-invalid', 'ATTACHMENT_NOT_FOUND');
    await attachmentCase('corrupt-object', sessionId, { ...image, attachmentId: fixture.attachments.corruptId }, 'session/attachment-invalid', 'ATTACHMENT_CORRUPT');
    await attachmentCase('invalid-reference', sessionId, { ...image, attachmentId: 'not-an-attachment-id' }, 'session/attachment-invalid', 'INVALID_ATTACHMENT_REF');
    await attachmentCase('legacy-shape', sessionId, image, 'gateway/input-invalid', undefined, { legacy: true });
    await attachmentCase('anonymous', sessionId, image, null, undefined, { anonymous: true });
    const deleted = await request('session-delete', 'POST', '/dsh-go/v1/sessions/delete', { body: { sessionId } });
    check(deleted.status === 200 && deleted.json?.deleted === true && deleted.json.sessionId === sessionId, 'delete only owned disposable session');
    const listedAfter = await rpc('session/list', { _request: {} });
    result.sessionListAfter = listedAfter; check(Array.isArray(listedAfter.items) && !listedAfter.items.some(item => item.sessionId === sessionId), 'actual subsequent session absence');
    // sessionId is permission scope, not an image-history lookup. Owner bypasses
    // remoteAccess.decide; this is deliberately not a restricted-reader test.
    await attachmentCase('deleted-owner-session', sessionId, image, 'session/attachment-invalid', 'OHOS_IMAGE_CODEC_UNAVAILABLE');
    check(attachments.cases.length === 7 && attachments.cases.every(row => row.passed), 'all seven real attachment HTTP cases');
    attachments.status = 'PASS_OH_FULL_REFERENCE_CONTRACT';


    const caps = 'v=1&app=0.10.0&locale=zh-CN&features=audio,files&surfaces=panels&components=stack,text,metric';
    const contributions = await request('contributions', 'GET', `/dsh-go/v1/contributions?${caps}`);
    check(contributions.status === 200 && contributions.json?.v === 1 && contributions.json.plugins?.some(plugin => plugin.pkg === fixture.pkg && plugin.state === 'ok'), 'real path-loaded native contribution');
    check(typeof contributions.headers.etag === 'string', 'contributions ETag');
    const etag = await request('contributions-etag', 'GET', `/dsh-go/v1/contributions?${caps}`, { headers: { 'if-none-match': contributions.headers.etag } }); check(etag.status === 304 && etag.raw.length === 0, 'ETag revalidation');
    const view = await request('view', 'GET', `/dsh-go/v1/views/${fixture.pkg}/proof?${caps}`);
    check(view.status === 200 && view.json?.v === 1 && view.json.pkg === fixture.pkg && view.json.view?.children?.[0]?.text === 'initial-label' && view.json.data?.bumps === 0, 'real panel view and first data');
    const asset = await request('asset', 'GET', `/dsh-go/v1/assets/${fixture.pkg}/proof.png`);
    check(asset.status === 200 && asset.headers['content-type'] === 'image/png' && createHash('sha256').update(asset.raw).digest('hex') === fixture.assetSHA256, 'real PNG asset bytes');

    socket = new WebSocket(base.replace('http:', 'ws:') + '/dsh-go/v1/stream', { headers: { Cookie: cookie }, handshakeTimeout: 15000 });
    closed = new Promise(resolve => socket.once('close', (code, reason) => { result.stream.close = { code, reason: reason.toString() }; resolve(); }));
    const fail = error => { wsError = error; for (const waiter of [...waiters]) waiter.reject(error); };
    socket.on('error', fail);
    socket.on('message', bytes => { try { const frame = JSON.parse(bytes.toString()); result.stream.received.push(frame); const waiter = [...waiters].find(waiter => waiter.predicate(frame)); if (waiter) waiter.resolve(frame); else frames.push(frame); } catch (error) { fail(error); } });
    await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
    result.stream.upgraded = true;
    send({ t: 'hello', v: [1], locale: 'zh-CN', features: ['audio', 'files'] });
    const welcome = await nextFrame(frame => frame.t === 'welcome', 'welcome');
    check(welcome.v === 1 && typeof welcome.conn === 'string' && welcome.features?.includes('audio') && welcome.features.includes('files'), 'native hello/welcome negotiation');
    send({ t: 'sub', sub: 'proof', pkg: fixture.pkg, id: 'proof', scope: {} });
    const first = await nextFrame(frame => frame.sub === 'proof' && frame.t === 'data', 'initial data'); check(first.data?.bumps === 0, 'real initial subscription data');
    const invoke = (id, action, extra = {}) => request(id, 'POST', '/dsh-go/v1/invoke', { body: { v: 1, pkg: fixture.pkg, id: 'proof', surface: 'panel', action, scope: {}, stream: welcome.conn, ...extra } });
    const bump = await invoke('invoke', 'bump'); check(bump.status === 200 && bump.json?.v === 1 && bump.json.effects?.some(effect => effect.type === 'toast' && effect.text === 'bumped'), 'real action effects');
    const update = await nextFrame(frame => frame.sub === 'proof' && ['data', 'patch'].includes(frame.t), 'action data update'); check((update.data ?? update.merge)?.bumps === 1, 'subscription observes action update');
    const pending = await invoke('stream-pending', 'hold'); check(pending.status === 200 && typeof pending.json?.pending?.id === 'string', 'real deferred operation');
    send({ t: 'cancel', pending: pending.json.pending.id });
    const cancelled = await nextFrame(frame => frame.pending === pending.json.pending.id && frame.t === 'void', 'cancelled pending'); check(cancelled.reason === 'cancelled', 'native cancellation result');

    const audio = await invoke('media-lease', 'audio'); check(audio.status === 200, 'audio effect response');
    const play = audio.json?.effects?.find(effect => effect.type === 'audio' && effect.op === 'play'); check(typeof play?.lease === 'string', 'issued live audio lease');
    const mediaPath = `/dsh-go/v1/media/${fixture.pkg}/tone?${new URLSearchParams({ lease: play.lease, key: 'proof-key' })}`;
    const media = await request('media', 'GET', mediaPath); check(media.status === 200 && media.headers['content-type'] === 'audio/wav' && media.raw.length === 48 && media.raw.subarray(0, 4).toString() === 'RIFF', 'real leased audio bytes');
    const choice = await invoke('file-request', 'choose', { userGesture: true }); check(choice.status === 200, 'file-picker effect response');
    const effect = choice.json?.effects?.find(effect => effect.type === 'pickFile'); check(/^[A-Za-z0-9_-]{32}$/.test(effect?.request ?? ''), 'real issued file request');
    const fileBytes = Buffer.from('owned 中文 selected-file bytes\n'); const fileSHA = createHash('sha256').update(fileBytes).digest('hex');
    const fileRoot = `/dsh-go/v1/files/${effect.request}`;
    const upload = await request('file-upload', 'POST', `${fileRoot}/upload?${new URLSearchParams({ stream: welcome.conn, name: '中文.txt', mediaType: 'text/plain' })}`, { raw: fileBytes });
    check(upload.status === 200 && upload.json?.file?.bytes === fileBytes.length, 'real file upload');
    const completePath = `${fileRoot}/complete?${new URLSearchParams({ stream: welcome.conn })}`;
    const complete = await request('file-complete', 'POST', completePath, { body: { status: 'selected' } }); check(complete.status === 200, 'real file completion');
    const selected = complete.json?.effects?.find(item => item.type === 'patch' && item.id === 'proof')?.data;
    check(selected?.callbacks === 1 && selected.status === 'selected' && selected.files?.[0]?.sha256 === fileSHA, 'callback consumed actual selected bytes exactly once');
    const repeated = await request('file-complete-again', 'POST', completePath, { body: { status: 'selected' } }); check(repeated.status === 404 && jsonCode(repeated.json) === 'not-found', 'completed request revoked');
    const state = await invoke('fixture-state', 'state'); const stateValue = JSON.parse(state.json?.effects?.find(item => item.type === 'copy')?.text ?? 'null');
    check(state.status === 200 && stateValue?.callbacks === 1 && stateValue.pendingCancelled === 1, 'real callback and cancel state');
    send({ t: 'unsub', sub: 'proof' }); await closeStream();
    check(result.stream.close?.code === 1000 && result.stream.forcedTermination === false, 'native stream closes normally');
    const revoked = await request('media-after-close', 'GET', mediaPath); check(revoked.status === 404 && jsonCode(revoked.json) === 'not-found', 'stream close revokes media lease');
    const occupancyBody = { bootRev: 'add12-private-boot', slots: { 'composer.before': [{ package: fixture.pkg, cell: 'private-cell', active: true }] }, attribution: 'fixture', unresolved: 0 };
    const occupancy = await request('occupancy', 'POST', '/dsh-go/v1/occupancy', { body: occupancyBody }); check(occupancy.status === 204, 'browser-half occupancy write');
    const inventoryAfter = await request('inventory-after-occupancy', 'GET', '/dsh-go/v1/inventory'); check(inventoryAfter.status === 200 && inventoryAfter.json?.bootRev === occupancyBody.bootRev && inventoryAfter.json.slots?.['composer.before']?.[0]?.package === fixture.pkg, 'occupancy observed through inventory');
    result.status = 'PASS_HOST_BRIDGE_ROUTE_CONTRACT';
    result.requiredTemplates = 15;
  } catch (error) { result.status = 'FAIL_HOST_BRIDGE_ROUTE_CONTRACT'; result.error = { name: error.name, message: error.message }; throw error; }
  finally {
    for (const waiter of [...waiters]) waiter.reject(new Error('contract closing'));
    await closeStream(); result.endedUTC = new Date().toISOString(); await persist();
  }
  return result;
}
