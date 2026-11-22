import { constants } from 'node:fs';
import { open, realpath, lstat } from 'node:fs/promises';
import { isAbsolute, relative, sep, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { randomUUID } from 'node:crypto';
import { containsSecret, inspectImage } from './core.js';
import { inspectVideo } from './video.js';
import { base64DecodedLength } from './base64.js';
import { createMediaClient } from './adapters.js';
import { requestBytes } from './http.js';
import { prepareImageStore } from './storage.js';
import { createStreamStager } from './stream-staging.js';
import { MediaError, checkAbort, safeFailure, fail } from './errors.js';

const within = (root, path) => { const rel = relative(root, path); return rel !== '..' && !rel.startsWith('..' + sep) && !isAbsolute(rel); };
function storageFailure(error) {
  throw error instanceof MediaError ? error : new MediaError('storage');
}

export async function readReferences(paths, context) {
  const refs = [];
  for (const path of paths ?? []) {
    const before = await context.authorizeWorkspace();
    if (!isAbsolute(path) || !within(before.workspaceRoot, path) || await realpath(path) !== path) fail('permission');
    const namedBefore = await lstat(path);
    if (!namedBefore.isFile() || namedBefore.isSymbolicLink()) fail('invalid_request');
    const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0));
    try {
      const info = await handle.stat();
      if (info.ino !== namedBefore.ino || info.dev !== namedBefore.dev) fail('permission');
      if (!info.isFile() || info.size < 12 || info.size > 10 * 1024 * 1024) fail('too_large');
      checkAbort(context.signal);
      const bytes = Buffer.alloc(info.size);
      if ((await handle.read(bytes, 0, bytes.length, 0)).bytesRead !== bytes.length) fail('storage');
      const after = await handle.stat(), named = await lstat(path), policy = await context.authorizeWorkspace();
      if (after.size !== info.size || after.mtimeMs !== info.mtimeMs || after.ino !== named.ino || after.dev !== named.dev
        || named.isSymbolicLink() || await realpath(path) !== path || policy.cwd !== before.cwd
        || policy.workspaceRoot !== before.workspaceRoot || policy.mode !== before.mode) fail('permission');
      const image = inspectImage(bytes);
      if (!['image/png', 'image/jpeg', 'image/webp'].includes(image.mime)) fail('invalid_request');
      context.captureReference?.({ path, ino: after.ino, dev: after.dev, size: after.size, mtimeMs: after.mtimeMs, ctimeMs: after.ctimeMs });
      refs.push('data:' + image.mime + ';base64,' + bytes.toString('base64'));
    } finally { await handle.close(); }
  }
  return refs;
}
export async function validateReferencePins(pins) {
  for (const pin of pins ?? []) {
    const now = await lstat(pin.path);
    if (!now.isFile() || now.isSymbolicLink() || await realpath(pin.path) !== pin.path
      || ['ino', 'dev', 'size', 'mtimeMs', 'ctimeMs'].some(key => now[key] !== pin[key])) fail('permission');
  }
}

export function mediaMeta(request, rid, status, job) {
  return { v: 1, rid, kind: request.model.kind, status, ...(job ? { job } : {}), items: [],
    request: { provider: request.service.provider, model: request.model.id, label: request.model.label,
      n: request.n ?? 1, refs: request.refs?.length ?? 0,
      ...(request.aspect ? { aspect: request.aspect } : {}), ...(request.quality ? { quality: request.quality } : {}),
      ...(request.resolution ? { resolution: request.resolution } : {}),
      ...(request.seconds ? { seconds: request.seconds } : {}) }, prompt: request.prompt };
}
export async function generateMedia(request, context) {
  const rid = context.admission?.rid ?? 'm_' + randomUUID();
  const createdAt = new Date().toISOString();
  const outputDate = context.admission?.outputDate ?? createdAt.slice(0, 10);
  const timeout = AbortSignal.timeout(request.model.kind === 'video' ? 30 * 60_000 : 180_000);
  const signal = AbortSignal.any([context.signal, timeout]);
  const client = context.client ?? createMediaClient({ transport: context.transport ?? undefined });
  const transport = context.transport ?? requestBytes;
  let store, secret, providerTask, submitted = false, remoteSucceeded = false, cancelledRemote;
  const meta = mediaMeta(request, rid, 'done', context.job?.id);
  try {
    checkAbort(signal);
    // An interrupted publication may have left an owned-looking file without its index.
    // A recovery attempt gets new names: never overwrite or delete uncertain leftovers.
    store = await prepareImageStore({ ...context, signal, rid, date: outputDate,
      publicationSuffix: context.resumeTaskId ? randomUUID() : undefined }).catch(storageFailure);
    const maximumItems = Array.from({ length: request.n ?? 1 }, (_, i) => ({
      path: store.outputPath(i + 1, request.model.kind === 'video' ? 'mp4' : 'webp'),
      mime: request.model.kind === 'video' ? 'video/mp4' : 'image/jpeg', width: 16384, height: 16384, bytes: context.limits.maxVideoBytes ?? context.limits.maxImageBytes,
      ...(request.model.kind === 'video' ? { duration: 3600, codec: 'hevc' } : {}),
    }));
    if (Buffer.byteLength(JSON.stringify({ 'dsh-go/media': { ...meta, items: maximumItems } })) > 8192) fail('metadata');
    const refs = context.resumeTaskId ? [] : context.referenceSources ?? await readReferences(request.refs, { ...context, signal });
    secret = await context.resolveCredential();
    if (typeof secret !== 'string' || secret.length < 1 || secret.length > 8192 || /[\r\n]/.test(secret)) fail('credential');
    // Reject a secret deliberately echoed through any public metadata/input field.
    if (containsSecret({ request, cwd: store.cwd }, secret)) fail('credential');
    await store.recheck();
    await validateReferencePins(context.referencePins);
    checkAbort(signal);
    let performCreate;
    if (!context.resumeTaskId) {
      const options = { signal, maxResponseBytes: context.limits.maxResponseBytes };
      performCreate = typeof client.prepareCreate === 'function'
        ? await client.prepareCreate(request, refs, secret, options)
        : () => client.create(request, refs, secret, options);
      checkAbort(signal);
      await context.admission?.begin();
    }
    submitted = true; // Intent may have reached the provider, even if the response is lost.
    const created = context.resumeTaskId ? { taskId: context.resumeTaskId } : await performCreate();
    if (request.model.kind === 'image') {
      let total = 0;
      for (const source of created.images) {
        checkAbort(signal);
        let bytes;
        if (source.b64_json) { base64DecodedLength(source.b64_json, context.limits.maxImageBytes); bytes = Buffer.from(source.b64_json, 'base64'); }
        else {
          // Public-address checks and DNS pinning are performed by the transport. Never forward credentials.
          let url = source.url;
          for (let hops = 0; ; hops++) {
            const result = await transport(url, { method: 'GET', headers: { accept: 'image/*', 'accept-encoding': 'identity' }, signal, maxBytes: context.limits.maxImageBytes });
            if ([301, 302, 303, 307, 308].includes(result.status)) {
              if (hops === 3 || typeof result.headers.location !== 'string') fail('response');
              url = new URL(result.headers.location, url).href; continue;
            }
            if (result.status !== 200) fail('response');
            bytes = result.body; break;
          }
        }
        total += bytes.length;
        if (bytes.length > context.limits.maxImageBytes || total > context.limits.maxTotalImageBytes) fail('too_large');
        const info = inspectImage(bytes);
        const path = await store.stage(bytes, info.extension).catch(storageFailure);
        meta.items.push({ path, mime: info.mime, width: info.width, height: info.height, bytes: bytes.length });
      }
    } else {
      providerTask = created.taskId;
      if (!context.resumeTaskId) await context.admission?.submitted(providerTask);
      context.job?.updateProgress('服务端已接收，等待生成');
      for (;;) {
        checkAbort(signal);
        const task = await client.query(request, providerTask, secret, { signal });
        if (task.state === 'failed') fail('generation_failed');
        if (task.state === 'unknown') fail('remote_may_continue');
        if (task.state === 'cancelled') { cancelledRemote = 'cancelled'; fail('cancelled'); }
        if (task.state === 'succeeded') {
          remoteSucceeded = true; // Later download/storage failures do not make this outcome unknown.
          context.job?.updateProgress('正在保存视频原件');
          const staged = await (context.stageDownload ?? createStreamStager())(task.url, {
            directory: store.stagingDirectory, signal, maxBytes: context.limits.maxVideoBytes,
            ownDownload: store.ownDownload,
          });
          const info = await inspectVideo(staged.path, signal);
          const path = await store.stageDownloaded(staged, info.extension).catch(storageFailure);
          meta.items.push({ path, mime: info.mime, width: info.width, height: info.height,
            bytes: staged.bytes, duration: info.duration, codec: info.codec });
          break;
        }
        context.job?.updateProgress(task.state === 'queued' ? '视频正在排队' : '视频正在生成');
        await sleep(context.pollMs ?? 15_000, undefined, { signal });
      }
    }
    if (Buffer.byteLength(JSON.stringify({ 'dsh-go/media': meta })) > 8192 || containsSecret(meta, secret)) fail('metadata');
    await context.admission?.settle();
    await store.commit(meta, { sessionId: context.sessionId, createdAt }).catch(storageFailure);
    return { meta, text: 'AI 生成' + (request.model.kind === 'video' ? '视频' : '图片') + '已保存：\n' + meta.items.map(item => item.path).join('\n') };
  } catch (error) {
    if (providerTask && signal.aborted && !cancelledRemote) {
      // Cancellation needs its own short deadline; the job signal is already aborted.
      try { cancelledRemote = await client.cancel(request, providerTask, secret, { signal: AbortSignal.timeout(20_000) }); }
      catch { cancelledRemote = 'unconfirmed'; }
    }
    try {
      if (!submitted) await context.admission?.releaseUnsent();
    } finally {
      // A failed ledger release must not leave the prepared store behind.
      const cleaned = store ? await store.abort().catch(() => false) : true;
      if (!cleaned) throw new MediaError('cleanup_failed');
    }
    if (cancelledRemote === 'cancelled') fail('cancelled');
    if (signal.aborted && providerTask && cancelledRemote !== 'cancelled') fail('remote_may_continue');
    if (signal.aborted && submitted && !providerTask) fail('submission_unknown');
    if (providerTask && !remoteSucceeded && !['generation_failed', 'policy', 'cancelled'].includes(error?.code)) fail('remote_may_continue');
    if (timeout.aborted) fail('timeout');
    throw safeFailure(error, signal);
  } finally { secret = undefined; }
}
