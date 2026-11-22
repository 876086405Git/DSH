import { realpath, stat } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { credentialRef } from '@deepseek-ai/dsh-credentials';
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { Config, catalogModel, runtimeSnapshot } from './config.js';
import { generateMedia, mediaMeta, readReferences, validateReferencePins } from './media-engine.js';
import { admitGeneration, recoverAdmission } from './budget.js';
import { createBudgetLedger } from './budget-ledger.js';
import { GENERATION_HEADER_INSTRUCTIONS } from './header.js';
import { MediaError, checkAbort, safeFailure } from './errors.js';

export { Config };
export const name = 'dsh-media';
export const inject = [
  'tools', 'credentials', 'fs', 'workingDirectory', 'sandboxPolicy', 'systemPrompt', 'jobs', 'approval',
];

export const SYSTEM_PROMPT = [
  GENERATION_HEADER_INSTRUCTIONS,
  '仅在当前用户明确要求时使用 generate_image、edit_image 或 generate_video；参考图必须是用户指定的工作区文件。',
  '视频工具返回真实后台 job；完成通知后使用 get_media_result 获取文件与卡片，不要重复提交生成。',
  '使用已有 job_kill 停止后台工作。只有供应商确认取消才可称已取消；其他情况服务端可能继续并收费。',
  '费用审批由主机执行。未知价格不得报零或编造估价；预算预留不是供应商扣费上限。',
  '工具失败时简短说明失败，不声称已生成；不得编造图片路径。',
  '密钥、凭据引用和服务地址由主机配置，不能要求模型读取或输出密钥。',
].join('\n');

function promptFor(services) {
  const available = services.flatMap(service => service.modelIds.map(id => ({
    serviceId: service.id, modelId: id, label: catalogModel(id).label, kind: catalogModel(id).kind,
  })));
  return SYSTEM_PROMPT + '\n当前已启用且凭据已配置的媒体模型，仅用于精确匹配：\n'
    + JSON.stringify(available);
}

function under(root, candidate) {
  const rel = relative(root, candidate);
  return rel === '' || (rel !== '..' && !rel.startsWith('..' + sep) && !isAbsolute(rel));
}

/**
 * This is a read-only authorization/mapping adapter, not a binary filesystem API.
 * The core owns all writes and must call this again before billable I/O/publication.
 * Only identity host mappings with a successful provider round trip are accepted.
 */
export function createWorkspaceAuthorizer(ctx, exec, signal) {
  const agent = exec.agent;
  const session = agent?.session;
  const sessionId = session?.id;
  if (!agent || !session || typeof sessionId !== 'string' || !sessionId) {
    throw new MediaError('permission');
  }

  function live() {
    checkAbort(signal);
    if (exec.agent !== agent || agent.session !== session || session.id !== sessionId) {
      throw new MediaError('permission');
    }
    ctx.fiber.assertActive();
    agent.ctx.fiber.assertActive();
  }

  function policy() {
    live();
    const value = ctx.sandboxPolicy.resolve({ session });
    if (!value || !['workspace-write', 'danger-full-access'].includes(value.mode)) {
      throw new MediaError('permission');
    }
    if (typeof value.workspaceRoot !== 'string' || !isAbsolute(value.workspaceRoot)) {
      throw new MediaError('unsupported_backend');
    }
    return { mode: value.mode, workspaceRoot: value.workspaceRoot };
  }

  async function hostDirectory(worldPath, expectedPolicy) {
    const fs = ctx.fs;
    const target = await fs.resolve(worldPath, { signal });
    live();
    const afterResolve = policy();
    if (afterResolve.mode !== expectedPolicy.mode
      || afterResolve.workspaceRoot !== expectedPolicy.workspaceRoot) {
      throw new MediaError('permission');
    }
    const processPath = fs.processPath(target);
    if (typeof processPath !== 'string' || !isAbsolute(processPath)) {
      throw new MediaError('unsupported_backend');
    }
    const canonical = await realpath(processPath);
    live();
    // The provider's execution path must already be the same host path.
    if (resolve(processPath) !== canonical) throw new MediaError('unsupported_backend');
    const info = await stat(canonical);
    live();
    if (!info.isDirectory()) throw new MediaError('unsupported_backend');
    const mapped = fs.processPathFromHostPath(canonical);
    if (typeof mapped !== 'string' || !isAbsolute(mapped)) {
      throw new MediaError('unsupported_backend');
    }
    const roundTrip = await fs.resolve(mapped, { signal });
    live();
    const afterRoundTrip = policy();
    if (afterRoundTrip.mode !== expectedPolicy.mode
      || afterRoundTrip.workspaceRoot !== expectedPolicy.workspaceRoot
      || roundTrip.targetKey !== target.targetKey
      || fs.processPath(roundTrip) !== canonical) {
      throw new MediaError('unsupported_backend');
    }
    return canonical;
  }

  return async function authorizeWorkspace() {
    try {
      const before = policy();
      const cwdWorld = await ctx.workingDirectory.ensure(agent, signal);
      live();
      const currentPolicy = policy();
      if (currentPolicy.mode !== before.mode
        || currentPolicy.workspaceRoot !== before.workspaceRoot) throw new MediaError('permission');
      const cwd = await hostDirectory(cwdWorld, currentPolicy);
      live();
      const workspaceRoot = await hostDirectory(currentPolicy.workspaceRoot, currentPolicy);
      live();
      const after = policy();
      if (after.mode !== currentPolicy.mode
        || after.workspaceRoot !== currentPolicy.workspaceRoot
        || ctx.workingDirectory.get(session) !== cwdWorld) throw new MediaError('permission');
      if (after.mode === 'workspace-write' && !under(workspaceRoot, cwd)) {
        throw new MediaError('permission');
      }
      return { cwd, mode: after.mode, workspaceRoot };
    } catch (error) {
      if (error instanceof MediaError) throw error;
      if (signal.aborted) throw safeFailure(error, signal);
      throw new MediaError('unsupported_backend');
    }
  };
}

const ALLOWED_ARGS = new Set(['prompt', 'n', 'serviceId', 'modelId', 'aspect', 'size', 'quality', 'seconds', 'resolution', 'refs']);

function supports(model, toolName) {
  return toolName === 'generate_video' ? model.kind === 'video'
    : model.kind === 'image' && (toolName === 'edit_image' ? model.edit === true : !model.editOnly);
}
export function selectedRequest(args, snapshot, readyServices, toolName = 'generate_image') {
  if (!args || typeof args !== 'object' || Array.isArray(args)
    || Object.keys(args).some(key => !ALLOWED_ARGS.has(key))
    || typeof args.prompt !== 'string' || !args.prompt.trim()
    || Buffer.byteLength(args.prompt, 'utf8') > 4096) throw new MediaError('invalid_request');
  const candidates = readyServices.filter(service => service.modelIds.some(id => supports(catalogModel(id), toolName)));
  const video = toolName === 'generate_video';
  const kindServiceId = (video ? snapshot.defaults.videoServiceId : snapshot.defaults.imageServiceId) ?? '';
  const kindModelId = (video ? snapshot.defaults.videoModelId : snapshot.defaults.imageModelId) ?? '';
  const legacyServiceId = snapshot.defaults.serviceId ?? '';
  const legacyModelId = snapshot.defaults.modelId ?? '';
  const legacyService = readyServices.find(s => s.id === legacyServiceId);
  let serviceId = args.serviceId;
  if (serviceId === undefined) {
    // New per-kind defaults win only when they point at a service that can
    // serve this tool; otherwise fall back to the legacy pair (whose missing
    // target still fails closed) and finally to the first candidate.
    if (kindServiceId && candidates.some(s => s.id === kindServiceId)) serviceId = kindServiceId;
    else {
      if (legacyServiceId && !legacyService) throw new MediaError('not_configured');
      serviceId = candidates.some(s => s.id === legacyService?.id) ? legacyService.id : candidates[0]?.id;
    }
  }
  const service = candidates.find(item => item.id === serviceId);
  if (!service) throw new MediaError('not_configured');
  const allowedModels = service.modelIds.filter(id => supports(catalogModel(id), toolName));
  // Explicit argument, then the kind pair, then the legacy pair, then the
  // service's first supported model. Empty new fields preserve old behavior.
  const modelId = args.modelId
    ?? (kindModelId && allowedModels.includes(kindModelId) ? kindModelId
      : (legacyModelId && allowedModels.includes(legacyModelId) ? legacyModelId : allowedModels[0]));
  if (!allowedModels.includes(modelId)) throw new MediaError('invalid_request');
  const model = catalogModel(modelId);
  if (!model || model.profile !== service.profile) throw new MediaError('invalid_request');
  const n = args.n ?? 1;
  if (!Number.isSafeInteger(n) || n < 1 || n > Math.min(snapshot.limits.maxImages, model.maxN)) throw new MediaError('invalid_request');
  for (const field of ['aspect', 'size', 'quality', 'resolution']) {
    if (args[field] !== undefined && (typeof args[field] !== 'string' || !args[field])) throw new MediaError('invalid_request');
  }
  if (args.aspect !== undefined && !model.ratios.includes(args.aspect)) throw new MediaError('invalid_request');
  if (args.size !== undefined && !model.sizes.includes(args.size)) throw new MediaError('invalid_request');
  if (args.quality !== undefined && !model.qualities.includes(args.quality)) throw new MediaError('invalid_request');
  if (args.seconds !== undefined && !model.durations?.includes(args.seconds)) throw new MediaError('invalid_request');
  if (args.resolution !== undefined && !model.resolutions?.includes(args.resolution)) throw new MediaError('invalid_request');
  if (args.aspect !== undefined && args.size !== undefined && model.aspectSizes[args.aspect] !== args.size) throw new MediaError('invalid_request');
  const refs = args.refs ?? [];
  if (!Array.isArray(refs) || refs.length > model.maxRefs || refs.some(path => typeof path !== 'string' || !isAbsolute(path) || path.length > 2048)
    || (toolName === 'edit_image' && refs.length !== 1) || (toolName === 'generate_image' && refs.length)
    || (model.requiresRef && refs.length !== 1)
    || (model.profile === 'ark-video' && refs.length && args.aspect !== undefined)) throw new MediaError('invalid_request');
  return {
    request: { prompt: args.prompt, n, refs,
      ...Object.fromEntries(['aspect', 'size', 'quality', 'seconds', 'resolution'].filter(field => args[field] !== undefined).map(field => [field, args[field]])),
      service: { id: service.id, provider: service.provider, baseUrl: service.baseUrl, profile: service.profile,
        ...(service.responseFormat === undefined ? {} : { responseFormat: service.responseFormat }) },
      model: { ...model },
    }, keyRef: service.keyRef,
  };
}

/**
 * The dependency argument is an in-process unit-test seam, not a config or tool field.
 * Real startup always calls this with the imported core.
 */
export function installMedia(ctx, config, { generate, admit = admitGeneration, engineOptions = {} } = {}) {
  const production = generate === undefined;
  generate ??= (request, context) => generateMedia(request, { ...context, ...engineOptions });
  const results = new Map();
  // Jobs emits removed only after owner teardown has awaited producer settlement.
  // Retain cards while their jobs are queryable, not the Session after removal.
  const stopResults = ctx.jobs.events.subscribe({ owners: 'all' }, event => {
    if (event.type === 'removed') results.delete(event.job.id);
  });
  const hostStateDir = join(resolveDshHome(config.dshHome), 'media', 'dsh-media');
  const lifetime = new AbortController();
  const operations = new Set();
  let closed = false;
  let epoch = 0;
  let registration;
  let pending = Promise.resolve();

  function retire() {
    const old = registration;
    registration = undefined;
    if (!old) return;
    old.abort.abort(new MediaError('cancelled'));
    for (const dispose of old.disposers.reverse()) dispose();
  }

  const output = {
    schema: { type: 'object', additionalProperties: false, properties: { meta: { type: 'json', required: true }, text: { type: 'string', required: true } } },
    render: (_args, value) => [{ type: 'text', text: value.text }],
    presentationMeta: (_args, value) => ({ 'dsh-go/media': value.meta }),
  };
  function validateResult(value) {
    if (!value || typeof value.text !== 'string' || !value.meta
      || Buffer.byteLength(JSON.stringify({ 'dsh-go/media': value.meta }), 'utf8') > 8192) throw new MediaError('metadata');
    return value;
  }
  function track(operation) {
    operations.add(operation);
    void operation.then(() => operations.delete(operation), () => operations.delete(operation));
    return operation;
  }
  function capability(toolName, snapshot, readyServices, lease) {
    const services = readyServices.map(service => ({ ...service, modelIds: service.modelIds.filter(id => supports(catalogModel(id), toolName)) })).filter(s => s.modelIds.length);
    if (!services.length) return undefined;
    const ids = [...new Set(services.flatMap(service => service.modelIds))], models = ids.map(catalogModel);
    const optional = {};
    for (const [field, values] of [['aspect', models.flatMap(m => m.ratios)], ['size', models.flatMap(m => m.sizes)],
      ['quality', models.flatMap(m => m.qualities)], ['seconds', models.flatMap(m => m.durations ?? [])], ['resolution', models.flatMap(m => m.resolutions ?? [])]]) {
      const supported = [...new Set(values)];
      if (supported.length) optional[field] = { type: field === 'seconds' ? 'integer' : 'string', enum: supported };
    }
    if (toolName !== 'generate_image' && models.some(m => m.maxRefs)) optional.refs = { type: 'array', items: { type: 'string' }, ...(toolName === 'edit_image' ? { required: true } : {}), description: '用户指定的工作区参考图绝对路径，最多一张。图生视频不要指定 aspect。' };
    const tool = defineTool({
      name: toolName,
      description: (toolName === 'generate_video' ? '按用户要求在后台生成视频；返回 job 后等待完成通知，调用 get_media_result 获取最终结果。' : toolName === 'edit_image' ? '按用户要求编辑工作区参考图片并保存。' : '按用户要求生成图片并保存到工作区。')
        + '可用服务：' + services.map(s => s.id + ' (' + s.modelIds.join(', ') + ')').join('; '),
      parameters: { prompt: { type: 'string', required: true, description: '完整描述，UTF-8 最多 4096 字节。' },
        n: { type: 'integer', enum: Array.from({ length: Math.min(snapshot.limits.maxImages, Math.max(...models.map(m => m.maxN))) }, (_, i) => i + 1) },
        serviceId: { type: 'string', enum: services.map(s => s.id) }, modelId: { type: 'string', enum: ids }, ...optional },
      timeoutMs: 180000, isConcurrencySafe: () => false, output,
      execute(args, exec) {
        const signal = AbortSignal.any([exec.signal, lifetime.signal, lease.signal]);
        return track((async () => {
          let admission;
          try {
            checkAbort(signal);
            if (closed || registration?.abort !== lease) throw new MediaError('cancelled');
            const selected = selectedRequest(args, snapshot, readyServices, toolName);
            const agent = exec.agent, session = agent?.session;
            if (!session || typeof session.id !== 'string') throw new MediaError('permission');
            const background = toolName === 'generate_video';
            const controller = new AbortController();
            // A completed tool call's signal must not kill the background producer.
            const workSignal = background ? AbortSignal.any([controller.signal, lifetime.signal, lease.signal]) : signal;
            const context = {
              signal: workSignal, limits: { ...snapshot.limits }, hostStateDir, sessionId: session.id,
              keyRef: selected.keyRef, budget: snapshot.budget,
              approve: reason => ctx.approval?.request({ agent, toolName, callId: exec.callId, reason, signal }),
              authorizeWorkspace: createWorkspaceAuthorizer(ctx, exec, workSignal),
              resolveCredential: async () => {
                checkAbort(workSignal); ctx.fiber.assertActive(); agent.ctx.fiber.assertActive();
                if (agent.session !== session) throw new MediaError('permission');
                const value = await ctx.credentials.resolve(credentialRef(selected.keyRef));
                checkAbort(workSignal); ctx.fiber.assertActive(); agent.ctx.fiber.assertActive();
                if (agent.session !== session) throw new MediaError('permission');
                if (!value || typeof value.value !== 'string' || !value.value) throw new MediaError('credential');
                return value.value;
              },
            };
            if (production) {
              const pins = [];
              const sources = await readReferences(selected.request.refs, { ...context, captureReference: pin => pins.push(pin) });
              context.references = { pins, sources };
              context.admission = admission = await admit(selected.request, context);
              await validateReferencePins(pins);
            }
            checkAbort(signal);
            if (!background) return validateResult(await generate(selected.request, context));
            if (!ctx.jobs) throw new MediaError('not_configured');
            return startVideo(selected.request, context, session, exec, controller);
          } catch (error) {
            try { await admission?.releaseUnsent(); }
            finally {
              if (error instanceof MediaError && error.code === 'cleanup_failed') throw error;
            }
            if (error instanceof MediaError && error.code === 'submission_unknown') throw error;
            throw safeFailure(error, signal);
          }
        })());
      },
    });
    tool.parameters.additionalProperties = false;
    return tool;
  }
  function startVideo(request, context, session, exec, controller) {
    const rid = context.admission?.rid;
    const jobId = ctx.jobs.start({ kind: 'media', label: request.model.label, owner: session.id,
      toolCall: { callId: exec.callId, rootCallId: exec.rootCallId ?? exec.callId }, outputLimitBytes: 4096,
      run(job) {
        const initial = { meta: mediaMeta(request, rid, 'running', job.id), text: `视频已进入后台任务 ${job.id}；恢复标识 ${rid}。完成通知后调用 get_media_result；Host 重启后用 resume_media(rid) 续查，不重复生成。` };
        results.set(job.id, { session, value: initial });
        const done = track(Promise.resolve().then(async () => {
          try {
            const value = validateResult(await generate(request, { ...context, job }));
            results.set(job.id, { session, value });
            return { status: 'completed', result: value.text + `\n请调用 get_media_result(job_id="${job.id}") 展示最终媒体卡片。` };
          } catch (error) {
            const safe = error instanceof MediaError ? error : new MediaError('provider');
            const value = { meta: { ...initial.meta, status: 'failed', error: { code: safe.code, text: safe.message } }, text: safe.message };
            results.set(job.id, { session, value });
            return { status: controller.signal.aborted ? 'killed' : 'failed', detail: safe.message, result: `${safe.message}\n请调用 get_media_result(job_id="${job.id}") 获取状态。` };
          }
        }));
        return { cancel() { controller.abort(new MediaError('cancelled')); }, done };
      },
    });
    return results.get(jobId).value;
  }
  function resultCapability() {
    const tool = defineTool({ name: 'get_media_result', description: '读取本会话媒体后台任务的最终文件与卡片；不会重新生成或再次收费。',
      parameters: { job_id: { type: 'string', required: true } }, output,
      isConcurrencySafe: () => true,
      execute(args, exec) {
        checkAbort(exec.signal);
        if (!args || Object.keys(args).some(k => k !== 'job_id')) throw new MediaError('invalid_request');
        const entry = results.get(args.job_id);
        if (!entry || entry.session !== exec.agent?.session) throw new MediaError('permission');
        ctx.jobs.get(args.job_id, exec.agent.session.id);
        return structuredClone(entry.value);
      },
    });
    tool.parameters.additionalProperties = false;
    return tool;
  }

  function recoveryCapability(snapshot, services, lease) {
    const tool = defineTool({ name: 'resume_media', description: 'Host 重启后续查原会话中已提交的视频任务。必须提供原恢复标识 rid；绝不再次创建供应商任务。',
      parameters: { rid: { type: 'string', required: true } }, output, isConcurrencySafe: () => false,
      execute(args, exec) {
        return track((async () => {
          const controller = new AbortController();
          const signal = AbortSignal.any([lifetime.signal, lease.signal, controller.signal]);
          checkAbort(exec.signal); checkAbort(signal);
          if (!args || Object.keys(args).some(k => k !== 'rid')) throw new MediaError('invalid_request');
          const session = exec.agent?.session;
          if (!session) throw new MediaError('permission');
          for (const entry of results.values()) {
            if (entry.session === session && entry.value.meta.rid === args.rid && entry.value.meta.status === 'running') return entry.value;
          }
          const context = { signal, hostStateDir, sessionId: session.id, limits: { ...snapshot.limits },
            authorizeWorkspace: createWorkspaceAuthorizer(ctx, exec, signal) };
          const saved = await recoverAdmission(args.rid, context);
          const service = services.find(s => s.id === saved.request.service.id);
          if (!service || service.keyRef !== saved.keyRef || service.baseUrl !== saved.request.service.baseUrl
            || service.profile !== saved.request.service.profile || service.provider !== saved.request.service.provider
            || !service.modelIds.includes(saved.request.model.id)) throw new MediaError('permission');
          const selected = selectedRequest({ prompt: saved.request.prompt, serviceId: service.id, modelId: saved.request.model.id,
            ...Object.fromEntries(['n', 'refs', 'aspect', 'size', 'quality', 'seconds', 'resolution'].filter(k => saved.request[k] !== undefined).map(k => [k, saved.request[k]])),
          }, snapshot, services, 'generate_video');
          // A catalog upgrade may change the provider payload; do not silently resume with a new identity.
          if (JSON.stringify(selected.request) !== JSON.stringify(saved.request)) throw new MediaError('permission');
          checkAbort(exec.signal);
          if (saved.completed) return validateResult(saved.completed);
          context.admission = saved.admission;
          context.resumeTaskId = saved.providerTaskId;
          context.resolveCredential = async () => {
            checkAbort(signal); ctx.fiber.assertActive(); exec.agent.ctx.fiber.assertActive();
            if (exec.agent.session !== session) throw new MediaError('permission');
            const key = await ctx.credentials.resolve(credentialRef(saved.keyRef));
            checkAbort(signal);
            if (!key?.value || exec.agent.session !== session) throw new MediaError('credential');
            return key.value;
          };
          return startVideo(saved.request, context, session, exec, controller);
        })());
      },
    });
    tool.parameters.additionalProperties = false;
    return tool;
  }

  async function refresh() {
    const mine = ++epoch;
    retire();
    if (closed) return;
    let snapshot;
    try { snapshot = runtimeSnapshot(config); } catch { return; }
    const descriptions = await Promise.allSettled(snapshot.services.map(async service => ({
      service,
      info: await ctx.credentials.describe(credentialRef(service.keyRef)),
    })));
    if (closed || mine !== epoch) return;
    const services = descriptions.flatMap(result => result.status === 'fulfilled'
      && result.value.info.configured === true ? [result.value.service] : []);
    if (!services.length) return;
    const abort = new AbortController();
    const next = { abort, disposers: [] };
    registration = next;
    try {
      ctx.fiber.assertActive();
      for (const toolName of ['generate_image', 'edit_image', 'generate_video']) {
        const tool = capability(toolName, snapshot, services, abort);
        if (tool) next.disposers.push(ctx.tools.register(tool));
      }
      if (services.some(s => s.modelIds.some(id => catalogModel(id).kind === 'video'))) {
        next.disposers.push(ctx.tools.register(resultCapability()));
        next.disposers.push(ctx.tools.register(recoveryCapability(snapshot, services, abort)));
      }
      next.disposers.push(ctx.systemPrompt.section({
        name: 'dsh-media', order: 520, text: promptFor(services), interpolate: false,
      }));
    } catch {
      retire();
    }
  }

  function scheduleRefresh() {
    pending = refresh();
    // Event dispatch never receives an unhandled rejection or secret-bearing error.
    void pending.catch(() => { retire(); });
    return pending;
  }

  async function dispose() {
    if (closed) return;
    closed = true;
    epoch += 1;
    lifetime.abort(new MediaError('cancelled'));
    retire();
    await Promise.allSettled([...operations]);
    results.clear();
    await stopResults();
  }

  ctx.effect(() => dispose);
  ctx.on('loader/volatile-update', paths => {
    if (paths.some(path => ['services', 'defaults', 'limits', 'budget'].includes(path[0]))) {
      void scheduleRefresh();
    }
  });
  ctx.on('credentials/reference-updated', ref => {
    let relevant = true;
    try { relevant = runtimeSnapshot(config).services.some(service => service.keyRef === String(ref)); }
    catch { /* Fail closed if the current configuration cannot be read. */ }
    if (relevant) void scheduleRefresh();
  });
  const ready = scheduleRefresh();
  return { ready, settled: () => pending, dispose };
}

export async function apply(ctx, config) {
  // The single-Host startup contract excludes live producers; refreshes do not.
  await createBudgetLedger(join(resolveDshHome(config.dshHome), 'media', 'dsh-media', 'budget')).releaseReserved();
  ctx.fiber.assertActive();
  const installed = installMedia(ctx, config);
  await installed.ready;
}
