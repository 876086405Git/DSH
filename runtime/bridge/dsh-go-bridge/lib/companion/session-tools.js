// A paired phone offers its current turn's actual Dart bindings. The agent's
// normal tool loop owns every call. Neither URL input nor a model argument
// chooses an Android method or confers companion identity.
import { randomUUID } from 'node:crypto';
import { CompanionError, invalid } from './schema.js';
import { contextId, FULL_PRESET } from './prompt-context.js';

const ROOT = '/dsh-go/v1/companion/session-tools';
const allowed = new Set(['remember', 'forget', 'revise', 'related', 'merge', 'person',
  'diary', 'relationship', 'impression', 'quiet', 'cancel', 'postpone', 'ask_later', 'recall', 'task_status',
  'reminder', 'map_open', 'photos_recent', 'photo_view', 'recent_notices', 'notify_user',
  'notes_to_todo', 'find_draft', 'compare_drafts', 'receipts_to_sheet']);
const webChanges = new Set(['forget', 'revise', 'quiet', 'cancel', 'postpone', 'merge', 'person', 'impression', 'diary', 'relationship']);
const unavailable = message => new CompanionError(409, 'device-unavailable', message);
const isMap = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const asFrame = frame => JSON.stringify(frame) + '\n';

export function createSessionToolRoutes({ ctx, readJson, send }) {
  const channels = new Map();
  const claimed = new WeakMap();
  const resolving = new Map();

  function retire(channel) {
    if (channel.closed) return;
    channel.closed = true;
    if (channels.get(channel.agent.id) === channel) channels.delete(channel.agent.id);
    for (const pending of channel.calls.values()) pending.reject(unavailable('手机结果未知；请勿自动重复操作'));
    channel.calls.clear();
    channel.res.end();
    if (channel.fiber) return channel.fiber.dispose();
  }

  function live(channel) {
    return !channel.closed && channels.get(channel.agent.id) === channel &&
      ctx.get('agents')?.get(channel.agent.id) === channel.agent &&
      ctx.get('agentPresets')?.presetForSession(channel.agent.session) === FULL_PRESET;
  }

  function execute(channel, tool, args, exec) {
    if (exec.agent !== channel.agent || !live(channel) || claimed.get(exec.agent)?.requestId !== channel.requestId) {
      throw unavailable('这次工具调用没有对应的伙伴手机回合');
    }
    if (channel.externalWeb && (webChanges.has(tool) || tool === 'remember' && args.card !== undefined)) {
      throw unavailable('这轮读过外部网页，修改现有记忆需要下一条本人消息');
    }
    exec.signal.throwIfAborted();
    if (channel.seen.has(exec.callId)) throw unavailable('这次调用已经交给手机，请读取原回执');
    channel.seen.add(exec.callId);
    return new Promise((resolve, reject) => {
      const abort = () => {
        channel.calls.delete(exec.callId);
        if (!channel.closed) channel.res.write(asFrame({ type: 'cancel', callId: exec.callId }));
        reject(exec.signal.reason);
      };
      exec.signal.addEventListener('abort', abort, { once: true });
      const done = settle => value => {
        exec.signal.removeEventListener('abort', abort);
        channel.calls.delete(exec.callId);
        settle(value);
      };
      channel.calls.set(exec.callId, { resolve: done(resolve), reject: done(reject) });
      channel.res.write(asFrame({ type: 'call', callId: exec.callId, name: tool, input: args }));
    });
  }

  async function open(body, res) {
    const { sessionId, requestId, tools } = body;
    if (!contextId(sessionId) || !contextId(requestId) || !Array.isArray(tools)) throw invalid();
    const names = new Set();
    for (const item of tools) {
      if (!isMap(item) || typeof item.name !== 'string' ||
          !allowed.has(item.name) ||
          names.has(item.name) || typeof item.description !== 'string' ||
          !isMap(item.input_schema) || item.input_schema.type !== 'object') throw invalid();
      names.add(item.name);
    }
    const attempt = Symbol();
    resolving.set(sessionId, attempt);
    let agent;
    try {
      const found = await ctx.get('sessionController')?.resolveAgent(sessionId);
      if (resolving.get(sessionId) !== attempt) throw new CompanionError(409, 'device-connection-replaced', '更新的手机连接正在使用这个会话');
      agent = found?.agent;
    } finally {
      if (resolving.get(sessionId) === attempt) resolving.delete(sessionId);
    }
    if (!agent || ctx.get('agents')?.get(sessionId) !== agent ||
        ctx.get('agentPresets')?.presetForSession(agent.session) !== FULL_PRESET) {
      throw new CompanionError(409, 'device-session-unavailable', '当前伙伴会话已不可用或预设已改变');
    }
    if (res.destroyed) return;
    const previous = channels.get(sessionId);
    // A lost HTTP response does not bestow a second device owner. In
    // particular it must never reset seen callIds or a web-derived restriction.
    if (previous?.requestId === requestId || claimed.get(agent)?.requestId === requestId) {
      throw new CompanionError(409, 'device-request-in-use', '这条消息已在原会话处理中');
    }
    const closing = previous && retire(previous);
    const channel = { agent, requestId, res, token: randomUUID(), calls: new Map(), seen: new Set(),
      closed: false, externalWeb: false };
    channels.set(sessionId, channel);
    const onClose = () => { Promise.resolve(retire(channel)).catch(error => ctx.logger?.warn?.(error)); };
    res.once('close', onClose);
    try {
      await closing;
      if (!live(channel)) return onClose();
      channel.fiber = agent.ctx.plugin({
        name: 'dsh-go-companion-session-tools',
        apply(scope) {
          for (const tool of tools) {
            scope.tools.register({
              name: 'companion_' + tool.name,
              description: tool.description, parameters: tool.input_schema,
              output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
              isConcurrencySafe: () => false,
              execute: (args, exec) => execute(channel, tool.name, args, exec),
            });
          }
        },
      });
      await channel.fiber.await();
      if (!live(channel) || res.destroyed) return onClose();
      res.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' });
      res.write(asFrame({ type: 'ready', token: channel.token }));
    } catch (error) {
      res.off('close', onClose);
      if (channels.get(sessionId) === channel) channels.delete(sessionId);
      channel.closed = true;
      if (channel.fiber) await channel.fiber.dispose();
      throw error;
    }
  }

  function result(body) {
    const channel = channels.get(body.sessionId);
    if (!channel || !live(channel) || channel.requestId !== body.requestId || channel.token !== body.token) {
      throw unavailable('原来的手机连接已结束');
    }
    const pending = channel.calls.get(body.callId);
    if (!pending) throw unavailable('原工具调用已结束');
    if (typeof body.content !== 'string' || typeof body.isError !== 'boolean') throw invalid();
    if (body.isError) pending.reject(new Error(body.content));
    else pending.resolve(body.content);
  }

  const offClaim = ctx.on('agent/inbox/claimed', ({ agent, message, turn }) => {
    if (message?.source?.kind !== 'user') return;
    const previous = claimed.get(agent);
    const requestId = message.source.principal === undefined ? message.source.rpcId : null;
    claimed.set(agent, { requestId, turn });
    const channel = channels.get(agent.id);
    if (channel?.agent === agent && channel.requestId === previous?.requestId && channel.requestId !== requestId) {
      return retire(channel);
    }
  });
  const offEvent = ctx.on('session/event', (session, event) => {
    const channel = channels.get(session.id);
    if (channel?.agent.session !== session) return;
    const owner = claimed.get(channel.agent);
    if (owner?.requestId !== channel.requestId || event.data?.turn !== owner.turn) return;
    if (event.type === 'tool/call' && ['web_fetch', 'web_search'].includes(event.data.name)) channel.externalWeb = true;
    if (event.type === 'turn/end') { claimed.delete(channel.agent); return retire(channel); }
  });
  const offDispose = ctx.on('agent/disposed', ({ agent }) => {
    const channel = channels.get(agent.id);
    if (channel?.agent === agent) return retire(channel);
  });

  return {
    async handle(req, res, path) {
      if (path !== ROOT + '/open' && path !== ROOT + '/result') return false;
      try {
        const admission = ctx.get('connection')?.admit(req);
        if (admission?.peer?.principal?.kind !== 'owner') {
          throw new CompanionError(admission?.rejection ?? 403, 'forbidden', 'Only the paired owner may attach a phone');
        }
        if (req.method !== 'POST') throw new CompanionError(405, 'invalid-request', 'Use POST');
        const body = await readJson(req, 512 * 1024);
        if (!isMap(body)) throw invalid();
        if (path.endsWith('/open')) await open(body, res);
        else { result(body); send(res, 200, { accepted: true }); }
      } catch (error) {
        req.resume();
        if (!res.destroyed && !res.headersSent) {
          send(res, error.status ?? 503, { error: { code: error.code ?? 'companion/device-unavailable',
            message: error.message ?? '手机工具未连接' } });
        }
      }
      return true;
    },
    dispose() {
      offClaim(); offEvent(); offDispose(); resolving.clear();
      return Promise.all([...channels.values()].map(retire));
    },
  };
}
