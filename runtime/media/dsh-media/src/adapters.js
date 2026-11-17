// Provider wire protocols. Every endpoint and model whitelist lives in the catalog.
// No retry of creation: a lost response can already be a charged operation.
import { CATALOG } from './config.js';
import { prepareHttpRequest, parseMediaUrl } from './http.js';
import { checkAbort, fail } from './errors.js';

const taskId = value => {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/.test(value)) fail('response');
  return value;
};
export function providerEndpoint(service, suffix) {
  let base;
  try { base = new URL(service.baseUrl); } catch { fail('unsafe_url'); }
  if (base.username || base.password || base.search || base.hash) fail('unsafe_url');
  const spec = CATALOG.profiles[service.profile];
  if (spec) {
    if (base.pathname !== '/' || base.port || !(spec.hosts.includes(base.hostname)
      || (spec.workspaceHostSuffix && base.hostname.endsWith(spec.workspaceHostSuffix)
        && /^[a-zA-Z0-9-]+$/.test(base.hostname.slice(0, -spec.workspaceHostSuffix.length))))) fail('unsafe_url');
    return base.origin + suffix;
  }
  if (!['openai-gpt-image', 'openai-compatible'].includes(service.profile)) fail('invalid_request');
  return base.href.replace(/\/+$/, '') + suffix;
}

export function createDescriptor(request, refs = []) {
  const { service, model, prompt, n = 1, aspect, quality, seconds, resolution } = request;
  const profile = service.profile;
  const size = request.size ?? model.aspectSizes?.[aspect];
  const spec = CATALOG.profiles[profile];
  const path = spec?.path ?? (refs.length ? '/images/edits' : '/images/generations');
  let body;
  const headers = {};
  if (profile.startsWith('openai-')) {
    body = { model: model.id, prompt, n, ...(size ? { size } : {}), ...(quality ? { quality } : {}) };
    if (refs.length) {
      if (profile !== 'openai-gpt-image') fail('invalid_request');
      body.images = refs.map(image_url => ({ image_url }));
    }
    if (service.responseFormat) body.response_format = service.responseFormat;
  } else if (profile === 'ark-image') {
    body = { model: model.id, prompt, size: size ?? model.sizes[0], response_format: 'url', ...(refs.length ? { image: refs[0] } : {}) };
  } else if (profile === 'ali-wan-image') {
    body = { model: model.id, input: { messages: [{ role: 'user', content: [...refs.map(image => ({ image })), { text: prompt }] }] },
      parameters: { n, size: (size ?? model.sizes[0]).replace('x', '*'), enable_sequential: false } };
  } else if (profile === 'silicon-image') {
    body = { model: model.id, prompt, ...(size ? { image_size: size } : model.sizes[0] ? { image_size: model.sizes[0] } : {}), ...(refs.length ? { image: refs[0] } : {}) };
  } else if (profile === 'ark-video') {
    body = { model: model.id, content: [{ type: 'text', text: prompt }, ...refs.map(url => ({ type: 'image_url', image_url: { url }, role: 'first_frame' }))],
      duration: seconds ?? model.durations[0], resolution: resolution ?? model.resolutions[0], ratio: refs.length ? 'adaptive' : aspect ?? '16:9' };
  } else if (profile === 'ali-video') {
    headers['X-DashScope-Async'] = 'enable';
    body = { model: model.id, input: { prompt, ...(refs.length ? { media: [{ type: 'first_frame', url: refs[0] }] } : {}) },
      parameters: { duration: seconds ?? model.durations[0], resolution: (resolution ?? model.resolutions[0]).toUpperCase(),
        ...(!refs.length ? { ratio: aspect ?? '16:9' } : {}), prompt_extend: false } };
  } else if (profile === 'silicon-video') {
    body = { model: model.id, prompt, image_size: model.videoSizes[aspect] ?? model.defaultSize, ...(refs.length ? { image: refs[0] } : {}) };
  } else fail('invalid_request');
  return { method: 'POST', path, body, headers };
}

function errorStatus(status, value, failedTaskReceipt = false) {
  if (status === 401 || status === 403) fail('authentication');
  if (status === 429) fail('rate_limit');
  if (['DataInspectionFailed', 'InputTextSensitiveContentDetected', 'InputImageSensitiveContentDetected', 'OutputImageSensitiveContentDetected', 'OutputVideoSensitiveContentDetected', 'content_policy_violation', 'moderation_blocked'].includes(value?.code ?? value?.error?.code)) fail('policy');
  if (status < 200 || status >= 300 || (value?.error && !failedTaskReceipt) || value?.code) fail('provider');
}
export function normalizeImages(profile, value, n) {
  let rows = value?.data;
  if (profile === 'ali-wan-image') rows = value?.output?.choices?.flatMap(choice => choice?.message?.content ?? []).filter(row => row?.type !== 'text' && row?.text === undefined).map(row => ({ url: row?.image }));
  if (profile === 'silicon-image') rows = value?.images;
  if (!Array.isArray(rows) || rows.length !== n || rows.some(row => !row || row.error || row.is_image_safe === false
    || (typeof row.url === 'string') === (typeof row.b64_json === 'string'))) fail('response');
  return rows.map(({ url, b64_json }) => url !== undefined ? { url } : { b64_json });
}
export function normalizeTask(profile, value, expectedId) {
  let id, state, url;
  if (profile === 'ark-video') {
    id = value?.id; state = ({ queued: 'queued', running: 'running', succeeded: 'succeeded', cancelled: 'cancelled', failed: 'failed', expired: 'failed' })[value?.status]; url = value?.content?.video_url;
  } else if (profile === 'ali-video') {
    id = value?.output?.task_id; state = ({ PENDING: 'queued', RUNNING: 'running', SUCCEEDED: 'succeeded', CANCELED: 'cancelled', FAILED: 'failed', UNKNOWN: 'unknown' })[value?.output?.task_status]; url = value?.output?.video_url;
  } else if (profile === 'silicon-video') {
    // SiliconFlow query receipts do not echo requestId; the exact request binds the response.
    id = expectedId; state = ({ InQueue: 'queued', InProgress: 'running', Succeed: 'succeeded', Failed: 'failed' })[value?.status];
    if (state === 'succeeded' && value?.results?.videos?.length !== 1) fail('response');
    url = value?.results?.videos?.[0]?.url;
  }
  if (taskId(id) !== expectedId || !state || (state === 'succeeded' && typeof url !== 'string')) fail('response');
  return { taskId: id, state, ...(state === 'succeeded' ? { url } : {}) };
}

export function createMediaClient({ transport, queryTimeoutMs = 30_000 } = {}) {
  if (!Number.isSafeInteger(queryTimeoutMs) || queryTimeoutMs < 1 || queryTimeoutMs > 30_000) fail('invalid_request');
  async function prepareSend(service, descriptor, secret, { signal, maxResponseBytes = 32 * 1024 * 1024, timeoutMs = 180_000 } = {}, queryId) {
    checkAbort(signal);
    const url = providerEndpoint(service, descriptor.path);
    parseMediaUrl(url); // Test transports rewrite a validated production URL internally.
    const timer = AbortSignal.timeout(timeoutMs);
    const active = signal ? AbortSignal.any([signal, timer]) : timer;
    const body = descriptor.body === undefined ? undefined : Buffer.from(JSON.stringify(descriptor.body));
    const options = { method: descriptor.method, headers: { authorization: 'Bearer ' + secret,
      'content-type': 'application/json', accept: 'application/json', 'accept-encoding': 'identity', ...descriptor.headers }, body, signal: active, maxBytes: maxResponseBytes };
    const rethrow = error => {
      if (timer.aborted && !signal?.aborted) fail('timeout');
      throw error;
    };
    const perform = transport === undefined
      ? await prepareHttpRequest(url, options).catch(rethrow)
      : () => transport(url, options);
    return async () => {
      let response;
      try { response = await perform(); } catch (error) { rethrow(error); }
      checkAbort(active);
      let value;
      try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(response.body)); } catch { errorStatus(response.status); fail('response'); }
      errorStatus(response.status, value, service.profile === 'ark-video' && queryId !== undefined
        && value?.id === queryId && value?.status === 'failed');
      return value;
    };
  }
  async function send(...args) {
    return (await prepareSend(...args))();
  }
  async function createFrom(request, perform) {
    let value;
    try { value = await perform(); }
    catch (error) {
      if (['authentication', 'rate_limit', 'policy', 'invalid_request', 'unsafe_url'].includes(error?.code)) throw error;
      fail('submission_unknown');
    }
    try {
      if (request.model.kind === 'image') return { images: normalizeImages(request.service.profile, value, request.n) };
      const profile = request.service.profile;
      return { taskId: taskId(profile === 'ark-video' ? value?.id : profile === 'ali-video' ? value?.output?.task_id : value?.requestId) };
    } catch { fail('submission_unknown'); }
  }
  return {
    async create(request, refs, secret, options) {
      return createFrom(request, () => send(request.service, createDescriptor(request, refs), secret, options));
    },
    async prepareCreate(request, refs, secret, options) {
      // Custom transports remain behind the caller's submission gate.
      const perform = transport === undefined
        ? await prepareSend(request.service, createDescriptor(request, refs), secret, options)
        : () => send(request.service, createDescriptor(request, refs), secret, options);
      return () => createFrom(request, perform);
    },
    async query(request, id, secret, options) {
      taskId(id);
      const profile = request.service.profile;
      const descriptor = { path: CATALOG.profiles[profile].queryPath.replace('{id}', encodeURIComponent(id)), method: profile === 'silicon-video' ? 'POST' : 'GET', ...(profile === 'silicon-video' ? { body: { requestId: id } } : {}) };
      return normalizeTask(profile, await send(request.service, descriptor, secret, { ...options, timeoutMs: queryTimeoutMs }, id), id);
    },
    async cancel(request, id, secret, options) {
      taskId(id);
      const profile = request.service.profile;
      if (CATALOG.profiles[profile]?.cancel !== 'queued-only') return 'unsupported';
      // A fresh query avoids deleting Ark's completed result record by mistake.
      const status = await this.query(request, id, secret, options);
      if (status.state !== 'queued') return status.state === 'cancelled' ? 'cancelled' : 'not-cancellable';
      const path = CATALOG.profiles[profile].queryPath.replace('{id}', encodeURIComponent(id)) + (profile === 'ali-video' ? '/cancel' : '');
      await send(request.service, { method: profile === 'ali-video' ? 'POST' : 'DELETE', path }, secret, { ...options, timeoutMs: 15_000 });
      // A DELETE acknowledgement alone is not evidence of cancellation if a race completed the task.
      const after = await this.query(request, id, secret, options);
      return after.state === 'cancelled' ? 'cancelled' : 'unconfirmed';
    },
  };
}
