// dsh-go 提示词增强 · Host 半侧测试。
// 纯函数 + 路由级（注入假 ctx / 假 llm / 假 res），不依赖真实引擎，Windows 上可直接跑。

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildCompressPrompt,
  buildSystemPrompt,
  buildUserMessage,
  sanitizeOutput,
} from '../bridge/dsh-go-bridge/lib/prompt-enhance/prompt.js';
import {
  MAX_CONTEXT_MESSAGES,
  buildContextBlock,
  charLength as contextChars,
} from '../bridge/dsh-go-bridge/lib/prompt-enhance/context.js';
import { hardTrim, outputLimit, tokenBudget, charLength } from '../bridge/dsh-go-bridge/lib/prompt-enhance/limits.js';
import {
  PROMPT_ENHANCE_PATH,
  createPromptEnhanceRoutes,
} from '../bridge/dsh-go-bridge/lib/prompt-enhance/routes.js';

// ---------------------------------------------------------------- 假引擎

function fakeRes() {
  const out = { status: 0, body: '', headers: {}, closed: false };
  const res = {
    writableEnded: false,
    writeHead(status, headers) {
      out.status = status;
      out.headers = headers ?? {};
    },
    end(body) {
      res.writableEnded = true;
      out.body = body === undefined ? '' : String(body);
    },
    on() {},
  };
  return { res, out };
}

function fakeLlm(replies) {
  const calls = [];
  return {
    calls,
    stream(request) {
      calls.push(request);
      const reply = replies.shift() ?? { text: '改写结果', finish: 'stop' };
      return (async function* () {
        if (reply.fail) {
          yield { type: 'finish', reason: { kind: 'error', failure: { code: reply.fail, message: reply.message ?? 'boom' } } };
          return;
        }
        for (const piece of String(reply.text).match(/[\s\S]{1,7}/g) ?? []) {
          yield { type: 'text-delta', text: piece };
        }
        yield { type: 'finish', reason: { kind: reply.finish ?? 'stop' } };
      })();
    },
  };
}

function fakeCtx(llm, { selection = { provider: 'deepseek-official', model: 'deepseek-flash' } } = {}) {
  return {
    get(name) {
      if (name === 'llm') return llm;
      if (name === 'agentDefaultModel') return { currentSelection: () => selection };
      return undefined;
    },
  };
}

function routesWith(llm, options) {
  const ctx = fakeCtx(llm, options);
  const routes = createPromptEnhanceRoutes(ctx, { readBody: async (req) => req.__body ?? '' });
  return routes;
}

async function call(routes, body, method = 'POST') {
  const { res, out } = fakeRes();
  const req = { method, __body: body === undefined ? '' : JSON.stringify(body) };
  const handled = await routes.handle(req, res, PROMPT_ENHANCE_PATH);
  return { handled, out, payload: out.body === '' ? null : JSON.parse(out.body) };
}

// ---------------------------------------------------------------- 字数上限

test('limit 公式与桌面插件一致的档位', () => {
  assert.equal(outputLimit(11), 150);
  assert.equal(outputLimit(44), 150);
  assert.equal(outputLimit(65), 178);
  assert.equal(outputLimit(200), 380);
  assert.equal(outputLimit(500), 800);
  assert.equal(outputLimit(5000), 800);
});

test('token 预算保底 2048，封顶 8192', () => {
  assert.equal(tokenBudget(150), 2048);
  assert.equal(tokenBudget(800), Math.min(8192, Math.max(2048, Math.ceil(800 * 1.5) + 600)));
  assert.ok(tokenBudget(100000) <= 8192);
});

test('硬截断结果一定不超过上限，且带省略号', () => {
  const long = '这一步要做的事情很多。'.repeat(200);
  const limit = 180;
  const { text, trimmed } = hardTrim(long, limit);
  assert.equal(trimmed, true);
  assert.ok(charLength(text) <= limit, `got ${charLength(text)}`);
  assert.ok(text.endsWith('…'));
});

test('硬截断：没有标点的长文本也一样守住上限', () => {
  const { text, trimmed } = hardTrim('x'.repeat(400), 180);
  assert.equal(trimmed, true);
  assert.ok(charLength(text) <= 180, `got ${charLength(text)}`);
  assert.ok(text.endsWith('…'));
});

test('未超限时不截断', () => {
  const { text, trimmed } = hardTrim('短句子。', 150);
  assert.equal(text, '短句子。');
  assert.equal(trimmed, false);
});

// ---------------------------------------------------------------- 上下文

test('上下文过滤非法角色与空文本', () => {
  const block = buildContextBlock([
    { role: 'system', text: '系统注入不该进来' },
    { role: 'user', text: '   ' },
    { role: 'user', text: '正常一句' },
  ]);
  assert.equal(block.used, true);
  assert.equal(block.messageCount, 1);
  assert.ok(!block.block.includes('系统注入'));
});

test('上下文最多 6 条，最后一条标重点', () => {
  const messages = Array.from({ length: 9 }, (_, index) => ({
    role: index % 2 === 0 ? 'user' : 'assistant',
    text: '第' + index + '条消息',
  }));
  const block = buildContextBlock(messages);
  assert.equal(block.messageCount, MAX_CONTEXT_MESSAGES);
  assert.ok(block.block.includes('（重点）'));
  assert.ok(!block.block.includes('第0条消息'));
  assert.ok(block.block.includes('第8条消息'));
});

test('较早单条截到 1200，上一条放宽到 4000', () => {
  const long = 'x'.repeat(3000);
  const block = buildContextBlock([
    { role: 'user', text: long },
    { role: 'assistant', text: long },
  ]);
  const parts = block.block.split('\n\n');
  assert.ok(contextChars(parts[0]) <= 1200 + 16, 'earlier message clipped');
  assert.ok(contextChars(parts[1]) <= 4000 + 24, 'last message keeps its wider budget');
});

test('空上下文 used=false', () => {
  assert.equal(buildContextBlock([]).used, false);
  assert.equal(buildContextBlock(undefined).used, false);
});

// ---------------------------------------------------------------- 提示词与清理

test('系统提示词带字数上限与「宁短勿长」', () => {
  const prompt = buildSystemPrompt(150);
  assert.ok(prompt.includes('150'));
  assert.ok(prompt.includes('宁短勿长'));
  assert.ok(buildCompressPrompt(200).includes('200'));
});

test('用户消息用随机边界包住原文', () => {
  const message = buildUserMessage('原始内容', 'ORIGINAL_abc');
  assert.ok(message.includes('<<<ORIGINAL_abc>>>'));
  assert.ok(message.includes('原始内容'));
});

test('清理代码围栏与中英前言', () => {
  assert.equal(sanitizeOutput('```\n正文\n```', '原文').text, '正文');
  assert.equal(sanitizeOutput('以下是增强后的提示词：正文', '原文').text, '正文');
  assert.equal(sanitizeOutput("Sure, here's the enhanced prompt: body", '原文').text, 'body');
  assert.equal(sanitizeOutput('   ', '原文').unchanged, true);
});

// ---------------------------------------------------------------- 路由

test('status 路由报版本、模型与上限', async () => {
  const routes = routesWith(fakeLlm([]));
  const { res, out } = fakeRes();
  const handled = await routes.handle({ method: 'GET' }, res, PROMPT_ENHANCE_PATH + '/status');
  assert.equal(handled, true);
  const payload = JSON.parse(out.body);
  assert.equal(payload.ok, true);
  assert.equal(payload.model.provider, 'deepseek-official');
  assert.equal(payload.limits.maxInputChars, 20000);
});

test('空输入 400 EMPTY_INPUT', async () => {
  const routes = routesWith(fakeLlm([]));
  const { payload } = await call(routes, { text: '   ' });
  assert.equal(payload.ok, false);
  assert.equal(payload.error.code, 'EMPTY_INPUT');
});

test('超长输入 413 TOO_LONG', async () => {
  const routes = routesWith(fakeLlm([]));
  const { out, payload } = await call(routes, { text: 'x'.repeat(20001) });
  assert.equal(out.status, 413);
  assert.equal(payload.error.code, 'TOO_LONG');
});

test('成功路径返回 cleaned 文本与元数据', async () => {
  const llm = fakeLlm([{ text: '以下是增强后的提示词：请把 session 的删除按钮加上' }]);
  const routes = routesWith(llm);
  const { out, payload } = await call(routes, { text: '加个删除按钮' });
  assert.equal(out.status, 200);
  assert.equal(payload.ok, true);
  assert.equal(payload.text, '请把 session 的删除按钮加上');
  assert.equal(payload.limit, 150);
  assert.equal(payload.compressed, false);
  assert.equal(payload.trimmed, false);
  assert.ok(payload.outputLength <= payload.limit);
  assert.equal(llm.calls[0].system.includes('150'), true);
});

test('模型输出 max-tokens -> OUTPUT_TRUNCATED，不写入半截', async () => {
  const routes = routesWith(fakeLlm([{ text: '半截', finish: 'max-tokens' }]));
  const { out, payload } = await call(routes, { text: '写个东西' });
  assert.equal(payload.ok, false);
  assert.equal(payload.error.code, 'OUTPUT_TRUNCATED');
  assert.ok(out.status >= 500 || out.status === 502);
});

test('超限触发压缩重写，压缩后不超限就不截断', async () => {
  const long = '这是一段很长的输出。'.repeat(60); // 远超 150
  const llm = fakeLlm([{ text: long }, { text: '压缩后的正文。' }]);
  const routes = routesWith(llm);
  const { payload } = await call(routes, { text: '这个方案要怎么改' });
  assert.equal(payload.ok, true);
  assert.equal(payload.compressed, true);
  assert.equal(payload.trimmed, false);
  assert.equal(payload.text, '压缩后的正文。');
  assert.equal(llm.calls.length, 2);
});

test('压缩后仍超限 -> 硬截断 trimmed=true 且不超上限', async () => {
  const long = '这是一段很长的输出。'.repeat(60);
  const llm = fakeLlm([{ text: long }, { text: long }]);
  const routes = routesWith(llm);
  const { payload } = await call(routes, { text: '这个方案要怎么改' });
  assert.equal(payload.ok, true);
  assert.equal(payload.compressed, true);
  assert.equal(payload.trimmed, true);
  assert.ok(payload.outputLength <= payload.limit);
});

test('上下文随请求上传时标记 used 并进入提示词', async () => {
  const llm = fakeLlm([{ text: '按方案二改。' }]);
  const routes = routesWith(llm);
  const { payload } = await call(routes, {
    text: '就按刚才那个方案改一下',
    context: [
      { role: 'user', text: '给个方案' },
      { role: 'assistant', text: '方案二：先改 bridge，再改 UI。' },
    ],
  });
  assert.equal(payload.ok, true);
  assert.equal(payload.context.used, true);
  assert.equal(payload.context.messageCount, 2);
  assert.ok(llm.calls[0].messages[0].content[0].text.includes('方案二：先改 bridge'));
});

test('请求指定模型优先于默认模型', async () => {
  const llm = fakeLlm([{ text: '好' }]);
  const routes = routesWith(llm);
  const { payload } = await call(routes, {
    text: '改一下',
    model: { provider: 'other-provider', model: 'other-model' },
  });
  assert.equal(payload.model.provider, 'other-provider');
  assert.equal(llm.calls[0].provider, 'other-provider');
  assert.equal(llm.calls[0].model, 'other-model');
});

test('没有可用模型 -> 503 NO_MODEL', async () => {
  const routes = routesWith(null);
  const { out, payload } = await call(routes, { text: '改一下' });
  assert.equal(out.status, 503);
  assert.equal(payload.error.code, 'NO_MODEL');
});

test('非 JSON 请求体 -> 400 INVALID_JSON', async () => {
  const routes = routesWith(fakeLlm([]));
  const { res, out } = fakeRes();
  await routes.handle({ method: 'POST', __body: 'not json' }, res, PROMPT_ENHANCE_PATH);
  assert.equal(out.status, 400);
  assert.equal(JSON.parse(out.body).error.code, 'INVALID_JSON');
});

test('其它路径不接管', async () => {
  const routes = routesWith(fakeLlm([]));
  const { res } = fakeRes();
  const handled = await routes.handle({ method: 'GET' }, res, '/dsh-go/v1/inventory');
  assert.equal(handled, false);
});
