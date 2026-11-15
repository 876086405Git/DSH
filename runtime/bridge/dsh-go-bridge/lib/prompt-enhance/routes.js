// dsh-go 提示词增强 · Host 半侧之四：两条路由。
//
//   GET  /dsh-go/v1/prompt-enhance/status  诊断：版本、默认模型、上限
//   POST /dsh-go/v1/prompt-enhance         把草稿原文交给模型改写，返回成品与元数据
//
// 与桌面插件的差别：模型可以随请求指定（App 用当前会话选中的模型），缺省才回落到
// profile 的默认模型；上下文由 App 传上来，Host 只裁剪不读事件流。

import { randomUUID } from 'node:crypto';
import {
  buildCompressMessage,
  buildCompressPrompt,
  buildSystemPrompt,
  buildUserMessage,
  buildUserMessageWithContext,
  sanitizeOutput,
} from './prompt.js';
import { buildContextBlock } from './context.js';
import { MAX_OUTPUT_TOKENS, charLength, hardTrim, outputLimit, tokenBudget } from './limits.js';

export const PROMPT_ENHANCE_PATH = '/dsh-go/v1/prompt-enhance';
export const PROMPT_ENHANCE_VERSION = '1.0.0';

/** 输入字符上限（两端一致）。 */
const MAX_INPUT_CHARS = 20000;
/** 请求体上限。 */
const MAX_BODY_BYTES = 256 * 1024;
/** 一次增强的总时限。 */
const TIMEOUT_MS = 120000;
/** 同时在跑的增强请求上限。 */
const MAX_CONCURRENT = 3;

const STATUS_OF_CODE = {
  TIMEOUT: 504,
  NO_MODEL: 503,
  BUSY: 429,
  TOO_LONG: 413,
  INVALID_BODY: 400,
  INVALID_JSON: 400,
  INVALID_TEXT: 400,
  EMPTY_INPUT: 400,
  INVALID_CONTEXT: 400,
  METHOD_NOT_ALLOWED: 405,
};

function coded(code, message, extra) {
  const error = new Error(message);
  error.code = code;
  if (extra !== undefined) error.extra = extra;
  return error;
}

function sameModel(value) {
  if (value === null || typeof value !== 'object') return undefined;
  const provider = typeof value.provider === 'string' ? value.provider.trim() : '';
  const model = typeof value.model === 'string' ? value.model.trim() : '';
  if (provider === '' || model === '') return undefined;
  return { provider, model };
}

export function createPromptEnhanceRoutes(webCtx, { readBody }) {
  let active = 0;

  function json(res, status, payload) {
    if (res.writableEnded) return;
    const body = Buffer.from(JSON.stringify(payload), 'utf8');
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'Content-Length': String(body.length),
    });
    res.end(body);
  }

  function fail(res, status, code, message) {
    json(res, status, { ok: false, error: { code, message } });
  }

  /** 请求里指定的模型优先，其次 profile 默认模型。 */
  function resolveModel(requested) {
    const explicit = sameModel(requested);
    if (explicit !== undefined) return { ...explicit, source: 'request' };
    try {
      const service = webCtx.get('agentDefaultModel');
      const selection = service && typeof service.currentSelection === 'function' ? service.currentSelection() : undefined;
      const fallback = sameModel(selection);
      if (fallback !== undefined) return { ...fallback, source: 'default' };
    } catch {
      /* 取不到由调用方报 NO_MODEL */
    }
    return null;
  }

  function llmOf() {
    const llm = webCtx.get('llm');
    return llm && typeof llm.stream === 'function' ? llm : null;
  }

  /** 一次流式调用，拼出可见正文；任何终止失败都抛带 code 的错误。 */
  async function streamOnce(llm, route, { system, user, maxTokens, signal }) {
    const stream = llm.stream({
      provider: route.provider,
      model: route.model,
      maxTokens,
      system,
      messages: [{ role: 'user', content: [{ type: 'text', text: user }] }],
      signal,
    });

    let output = '';
    let finishKind = 'stop';
    let sawFinish = false;
    for await (const chunk of stream) {
      if (chunk === null || typeof chunk !== 'object') continue;
      if (chunk.type === 'text-delta' && typeof chunk.text === 'string') {
        output += chunk.text;
        continue;
      }
      if (chunk.type === 'finish') {
        sawFinish = true;
        const reason = chunk.reason !== null && typeof chunk.reason === 'object' ? chunk.reason : chunk;
        finishKind = typeof reason.kind === 'string' ? reason.kind : 'stop';
        if (finishKind === 'error' || finishKind === 'aborted') {
          const failure = (reason.failure && typeof reason.failure === 'object' ? reason.failure : chunk.failure) || {};
          throw coded(
            String(failure.code || (finishKind === 'aborted' ? 'ABORTED' : 'LLM_ERROR')),
            String(failure.message || (finishKind === 'aborted' ? '模型请求已取消' : '模型请求失败')),
          );
        }
      }
    }

    if (!sawFinish) throw coded('STREAM_CLOSED', '模型流意外中断，结果不完整；请重试');
    if (finishKind === 'max-tokens') {
      throw coded('OUTPUT_TRUNCATED', '模型输出达到长度上限，结果不完整；请缩短输入后重试');
    }
    if (finishKind !== 'stop') {
      throw coded('UNEXPECTED_FINISH', '模型提前结束（' + finishKind + '），本次结果不完整，未填入');
    }
    return output;
  }

  async function readJsonBody(req) {
    const raw = await readBody(req, MAX_BODY_BYTES);
    if (raw === null || raw === undefined || raw.length === 0) throw coded('INVALID_BODY', '请求体为空或超过大小上限');
    try {
      return JSON.parse(Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw));
    } catch {
      throw coded('INVALID_JSON', '请求体不是合法 JSON');
    }
  }

  async function enhance(req, res) {
    const startedAt = Date.now();
    let controller;
    let timer;
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      active = Math.max(0, active - 1);
      if (timer !== undefined) clearTimeout(timer);
    };

    try {
      const payload = await readJsonBody(req);
      if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
        throw coded('INVALID_TEXT', '请求体必须是对象');
      }
      const text = typeof payload.text === 'string' ? payload.text : undefined;
      if (text === undefined) throw coded('INVALID_TEXT', '缺少字符串字段 text');
      if (text.trim() === '') throw coded('EMPTY_INPUT', '输入内容为空');
      const inputLength = charLength(text);
      if (inputLength > MAX_INPUT_CHARS) {
        throw coded('TOO_LONG', '输入 ' + inputLength + ' 字符，超过上限 ' + MAX_INPUT_CHARS + ' 字符');
      }
      if (payload.context !== undefined && payload.context !== null && !Array.isArray(payload.context)) {
        throw coded('INVALID_CONTEXT', 'context 必须是数组');
      }

      const route = resolveModel(payload.model);
      const llm = llmOf();
      if (route === null || llm === null) {
        throw coded('NO_MODEL', '宿主没有可用的模型路由（agentDefaultModel 未配置或 llm 服务不可用）');
      }
      if (active >= MAX_CONCURRENT) throw coded('BUSY', '同时进行的增强请求过多，请稍后再试');

      active += 1;
      controller = new AbortController();
      timer = setTimeout(() => controller.abort(coded('TIMEOUT', '生成超时')), TIMEOUT_MS);
      const signal = controller.signal;
      const onClose = () => {
        if (!res.writableEnded && !signal.aborted) controller.abort(coded('CLIENT_GONE', '客户端已断开'));
      };
      res.on('close', onClose);

      const limit = outputLimit(inputLength);
      const context = buildContextBlock(payload.context);
      const marker = 'ORIGINAL_' + randomUUID().replace(/-/g, '');
      const userMessage = context.used
        ? buildUserMessageWithContext(text, marker, context.block)
        : buildUserMessage(text, marker);

      const first = await streamOnce(llm, route, {
        system: buildSystemPrompt(limit),
        user: userMessage,
        maxTokens: tokenBudget(limit),
        signal,
      });
      const cleaned = sanitizeOutput(first, text);
      let result = cleaned.text;
      let compressed = false;
      let trimmed = false;

      // 第二层：超限就压缩重写一次。
      if (charLength(result) > limit) {
        compressed = true;
        const second = await streamOnce(llm, route, {
          system: buildCompressPrompt(limit),
          user: buildCompressMessage(result, limit),
          maxTokens: tokenBudget(limit),
          signal,
        });
        result = sanitizeOutput(second, result).text;
      }
      // 第三层：仍超限则硬截断。
      const trimmedResult = hardTrim(result, limit);
      result = trimmedResult.text;
      trimmed = trimmedResult.trimmed;

      release();
      json(res, 200, {
        ok: true,
        text: result,
        unchanged: cleaned.unchanged,
        limit,
        compressed,
        trimmed,
        inputLength,
        outputLength: charLength(result),
        elapsedMs: Date.now() - startedAt,
        model: { provider: route.provider, model: route.model, source: route.source },
        finish: 'stop',
        context: {
          used: context.used,
          messageCount: context.messageCount,
          blockChars: context.blockChars,
        },
      });
    } catch (error) {
      release();
      const code = typeof error?.code === 'string' ? error.code : 'LLM_ERROR';
      if (code === 'CLIENT_GONE') return; // 对端已经走了，不必再写
      if (code === 'ABORTED' || code === 'TIMEOUT') {
        return fail(res, 504, 'TIMEOUT', '生成超时，请重试');
      }
      const status = STATUS_OF_CODE[code] ?? 502;
      return fail(res, status, code, String(error?.message ?? '模型请求失败'));
    }
  }

  function status(res) {
    const route = resolveModel(undefined);
    json(res, 200, {
      ok: true,
      plugin: 'dsh-go-bridge/prompt-enhance',
      version: PROMPT_ENHANCE_VERSION,
      model: route === null ? null : { provider: route.provider, model: route.model },
      limits: {
        maxInputChars: MAX_INPUT_CHARS,
        maxOutputTokens: MAX_OUTPUT_TOKENS,
        timeoutMs: TIMEOUT_MS,
        maxConcurrent: MAX_CONCURRENT,
      },
    });
  }

  async function handle(req, res, path) {
    if (path !== PROMPT_ENHANCE_PATH && path !== PROMPT_ENHANCE_PATH + '/status') return false;
    const method = (req.method || 'GET').toUpperCase();
    if (path.endsWith('/status')) {
      if (method !== 'GET' && method !== 'HEAD') return fail(res, 405, 'METHOD_NOT_ALLOWED', '只支持 GET'), true;
      status(res);
      return true;
    }
    if (method !== 'POST') return fail(res, 405, 'METHOD_NOT_ALLOWED', '只支持 POST'), true;
    await enhance(req, res);
    return true;
  }

  return { handle };
}
