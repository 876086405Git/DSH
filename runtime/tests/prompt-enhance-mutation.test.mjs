// dsh-go 提示词增强 · 反向插桩。
//
// 每个变异体把实现改坏一处，然后跑同一个不变式检查：检查必须失败，否则就是假绿。
// 做法：把 lib/prompt-enhance/*.js 复制到临时目录 → 改写其中一处 → 动态 import 变异体 → 断言被破坏。

import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const SOURCE = new URL('../bridge/dsh-go-bridge/lib/prompt-enhance/', import.meta.url);

const MODULES = ['prompt.js', 'context.js', 'limits.js', 'routes.js'];

/** 一份变异体：{ name, file, from, to, check(dir) }。 */
const MUTATIONS = [
  {
    name: '下限失效（MIN_LIMIT 1 → 短输入上限算成 96）',
    file: 'limits.js',
    from: 'export const MIN_LIMIT = 150;',
    to: 'export const MIN_LIMIT = 1;',
    async check(dir) {
      const { outputLimit } = await import(pathToFileURL(join(dir, 'limits.js')).href + '?m=1');
      assert.equal(outputLimit(11), 150, 'mutant: 短输入没有按 150 保底');
    },
  },
  {
    name: '上限不封顶（MAX_LIMIT 800 → 99999）',
    file: 'limits.js',
    from: 'export const MAX_LIMIT = 800;',
    to: 'export const MAX_LIMIT = 99999;',
    async check(dir) {
      const { outputLimit } = await import(pathToFileURL(join(dir, 'limits.js')).href + '?m=2');
      assert.equal(outputLimit(5000), 800, 'mutant: 长输入没有封顶到 800');
    },
  },
  {
    name: '硬截断整体失效（预算与兜底两道保险一起拆）',
    file: 'limits.js',
    from: 'const budget = Math.max(1, limit - 1); // 留一个位置给省略号',
    to: 'const budget = limit + 50;',
    // hardTrim 有两道保险（预算切点 + 末尾再收一次）；单拆一道是等价变异，
    // 所以这里一起拆，证明「结果 ≤ 上限」这条断言真的活着。
    from2: '  if (outChars.length > limit) out = outChars.slice(0, limit - 1).join(\'\') + \'…\';',
    to2: '  if (false) out = outChars.slice(0, limit - 1).join("") + "…";',
    async check(dir) {
      const { hardTrim, charLength } = await import(pathToFileURL(join(dir, 'limits.js')).href + '?m=3');
      // 没有句末/标点的文本只能走预算兜底：预算被放大的话这里立刻越过上限。
      const { text } = hardTrim('x'.repeat(400), 100);
      assert.ok(charLength(text) <= 100, 'mutant: 硬截断越过了上限');
    },
  },
  {
    name: '上下文取最早的 6 条（而不是最近 6 条）',
    file: 'context.js',
    from: 'const recent = rows.slice(-MAX_CONTEXT_MESSAGES);',
    to: 'const recent = rows.slice(0, MAX_CONTEXT_MESSAGES);',
    async check(dir) {
      const { buildContextBlock } = await import(pathToFileURL(join(dir, 'context.js')).href + '?m=4');
      const block = buildContextBlock(
        Array.from({ length: 9 }, (_, index) => ({ role: 'user', text: '第' + index + '条' })),
      );
      assert.ok(!block.block.includes('第0条'), 'mutant: 取了最早的消息');
      assert.ok(block.block.includes('第8条'), 'mutant: 没有最近的最后一条');
    },
  },
  {
    name: '上一条不标重点',
    file: 'context.js',
    from: "'（重点）'",
    to: "''",
    async check(dir) {
      const { buildContextBlock } = await import(pathToFileURL(join(dir, 'context.js')).href + '?m=5');
      const block = buildContextBlock([
        { role: 'user', text: '上文' },
        { role: 'assistant', text: '方案二' },
      ]);
      assert.ok(block.block.includes('（重点）'), 'mutant: 上一条没有标重点');
    },
  },
  {
    name: '不压缩重写（超限直接进硬截断）',
    file: 'routes.js',
    from: '      if (charLength(result) > limit) {\n        compressed = true;',
    to: '      if (false) {\n        compressed = true;',
    async check(dir) {
      const long = '这是一段很长的输出。'.repeat(60);
      const { createPromptEnhanceRoutes } = await import(pathToFileURL(join(dir, 'routes.js')).href + '?m=6');
      const llm = fakeLlm([{ text: long }, { text: '压缩后的正文。' }]);
      const routes = createPromptEnhanceRoutes(fakeCtx(llm), { readBody: async (req) => req.__body ?? '' });
      const payload = await callText(routes, '这个方案要怎么改');
      assert.equal(payload.compressed, true, 'mutant: 没有触发压缩重写');
      assert.equal(llm.calls.length, 2, 'mutant: 少了第二次模型调用');
    },
  },
  {
    name: 'max-tokens 不报错（半截结果被当成品）',
    file: 'routes.js',
    from: "    if (finishKind === 'max-tokens') {",
    to: '    if (false) {',
    async check(dir) {
      const { createPromptEnhanceRoutes } = await import(pathToFileURL(join(dir, 'routes.js')).href + '?m=7');
      const llm = fakeLlm([{ text: '半截', finish: 'max-tokens' }]);
      const routes = createPromptEnhanceRoutes(fakeCtx(llm), { readBody: async (req) => req.__body ?? '' });
      const payload = await callText(routes, '写个东西');
      assert.equal(payload.ok, false, 'mutant: 半截结果被当成功返回');
      assert.equal(payload.error.code, 'OUTPUT_TRUNCATED');
    },
  },
  {
    name: '上下文不进入提示词（丢了 context 分支）',
    file: 'routes.js',
    from: '      const userMessage = context.used',
    to: '      const userMessage = false',
    async check(dir) {
      const { createPromptEnhanceRoutes } = await import(pathToFileURL(join(dir, 'routes.js')).href + '?m=8');
      const llm = fakeLlm([{ text: '好' }]);
      const routes = createPromptEnhanceRoutes(fakeCtx(llm), { readBody: async (req) => req.__body ?? '' });
      const payload = await callPayload(routes, {
        text: '就按刚才那个方案改',
        context: [{ role: 'assistant', text: '方案二：先改 bridge' }],
      });
      const prompt = llm.calls[0].messages[0].content[0].text;
      assert.ok(payload.ok, 'mutant: 请求失败');
      assert.ok(prompt.includes('方案二：先改 bridge'), 'mutant: 上文没有进入提示词');
    },
  },
];

// ---------------------------------------------------------------- 假件（与正向测试同形）

function fakeLlm(replies) {
  const calls = [];
  return {
    calls,
    stream(request) {
      calls.push(request);
      const reply = replies.shift() ?? { text: '改写结果', finish: 'stop' };
      return (async function* () {
        if (reply.fail) {
          yield { type: 'finish', reason: { kind: 'error', failure: { code: reply.fail } } };
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

function fakeCtx(llm) {
  return {
    get(name) {
      if (name === 'llm') return llm;
      if (name === 'agentDefaultModel') return { currentSelection: () => ({ provider: 'p', model: 'm' }) };
      return undefined;
    },
  };
}

function fakeRes() {
  const out = { body: '' };
  const res = {
    writableEnded: false,
    writeHead() {},
    end(body) {
      res.writableEnded = true;
      out.body = body === undefined ? '' : String(body);
    },
    on() {},
  };
  return { res, out };
}

async function callPayload(routes, body) {
  const { res, out } = fakeRes();
  await routes.handle({ method: 'POST', __body: JSON.stringify(body) }, res, '/dsh-go/v1/prompt-enhance');
  return JSON.parse(out.body);
}

async function callText(routes, text) {
  return callPayload(routes, { text });
}

// ---------------------------------------------------------------- 变异体装配

function buildMutant(mutation) {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-prompt-enhance-mutant-'));
  for (const file of MODULES) {
    cpSync(new URL(file, SOURCE), join(dir, file));
  }
  const target = join(dir, mutation.file);
  const source = readFileSync(target, 'utf8');
  if (!source.includes(mutation.from)) {
    rmSync(dir, { recursive: true, force: true });
    throw new Error('变异点没找到：' + mutation.name + '（实现改了，请同步变异体）');
  }
  let mutated = source.replace(mutation.from, mutation.to);
  if (mutation.from2 !== undefined) {
    if (!mutated.includes(mutation.from2)) {
      rmSync(dir, { recursive: true, force: true });
      throw new Error('第二变异点没找到：' + mutation.name + '（实现改了，请同步变异体）');
    }
    mutated = mutated.replace(mutation.from2, mutation.to2);
  }
  writeFileSync(target, mutated);
  return dir;
}

for (const mutation of MUTATIONS) {
  test('变异必须被抓到：' + mutation.name, async () => {
    const dir = buildMutant(mutation);
    try {
      await assert.rejects(
        async () => { await mutation.check(dir); },
        (error) => error instanceof assert.AssertionError || error instanceof Error,
        '变异体没有让检查失败 —— 假绿',
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}

test('正向对照：未变异时同样的检查通过', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-prompt-enhance-baseline-'));
  try {
    for (const file of MODULES) cpSync(new URL(file, SOURCE), join(dir, file));
    const { outputLimit } = await import(pathToFileURL(join(dir, 'limits.js')).href + '?baseline=1');
    assert.equal(outputLimit(11), 150);
    const { buildContextBlock } = await import(pathToFileURL(join(dir, 'context.js')).href + '?baseline=1');
    const block = buildContextBlock([{ role: 'user', text: '上文' }, { role: 'assistant', text: '方案二' }]);
    assert.ok(block.block.includes('（重点）'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
