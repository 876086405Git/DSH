import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { apply, computeOutputLimit, hardTrimToLimit, inject, name } from '../lib/index.js'

assert.equal(name, 'dsh-prompt-enhance')
assert.deepEqual(inject, ['webServer', 'llm', 'connection'])

function makeRes() {
  return {
    writableEnded: false,
    statusCode: 0,
    headers: null,
    writeHead(code, headers) { this.statusCode = code; this.headers = headers },
    end(body) {
      if (body !== undefined) this.payload = Buffer.isBuffer(body) ? body.toString('utf8') : String(body)
      this.writableEnded = true
    },
    on() {},
    off() {},
    json() { return JSON.parse(this.payload || '{}') },
  }
}

function makeReq(method, body) {
  const req = new EventEmitter()
  req.method = method
  req.url = '/dsh-prompt-enhance/enhance'
  req.destroy = () => {}
  process.nextTick(() => {
    if (body !== undefined) req.emit('data', Buffer.from(body))
    req.emit('end')
  })
  return req
}

async function invoke(route, req) {
  const res = makeRes()
  await route.handler(req, res)
  return res
}

function buildCtx(streamImpl) {
  const routes = new Map()
  const webServer = {
    register(route) {
      assert.ok(!routes.has(route.path), 'duplicate route ' + route.path)
      routes.set(route.path, route)
      return () => routes.delete(route.path)
    },
  }
  const ctx = {
    get(service) {
      if (service === 'webServer') return webServer
      if (service === 'agentDefaultModel') return { currentSelection: () => ({ provider: 'deepseek-account', model: 'deepseek-flash' }) }
      if (service === 'connection') return undefined
      return undefined
    },
    logger: { warn() {}, info() {} },
    effect(fn) { this.disposed = fn },
    llm: { stream: streamImpl },
  }
  apply(ctx)
  return { ctx, routes }
}

/** 宿主真实协议：finish 块是 { type, reason: { kind, failure? } }。 */
function finishChunk(reason) {
  return { type: 'finish', reason }
}

function textStream(text) {
  return (async function* () {
    yield { type: 'block-start', index: 0, blockType: 'text' }
    yield { type: 'text-delta', index: 0, text }
    yield finishChunk({ kind: 'stop' })
  })()
}

function errorStream(code, message) {
  return (async function* () {
    yield finishChunk({ kind: 'error', failure: { code, message } })
  })()
}

// ── status ────────────────────────────────────────────────────────────────
{
  const { routes } = buildCtx(textStream)
  assert.ok(routes.has('/dsh-prompt-enhance/status'))
  const res = await invoke(routes.get('/dsh-prompt-enhance/status'), makeReq('GET'))
  assert.equal(res.statusCode, 200)
  assert.equal(res.json().ok, true)
  assert.equal(res.json().model.model, 'deepseek-flash')
}

// ── method limits ─────────────────────────────────────────────────────────
{
  const { routes } = buildCtx(textStream)
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('GET'))
  assert.equal(res.statusCode, 405)
  assert.equal(res.json().error.code, 'METHOD_NOT_ALLOWED')
}
{
  const { routes } = buildCtx(textStream)
  const res = await invoke(routes.get('/dsh-prompt-enhance/status'), makeReq('POST', '{}'))
  assert.equal(res.statusCode, 405)
  assert.equal(res.json().error.code, 'METHOD_NOT_ALLOWED')
}

// ── empty input ───────────────────────────────────────────────────────────
{
  const { routes } = buildCtx(textStream)
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '   ' })))
  assert.equal(res.statusCode, 400)
  assert.equal(res.json().error.code, 'EMPTY_INPUT')
}

// ── too long ──────────────────────────────────────────────────────────────
{
  const { routes } = buildCtx(textStream)
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: 'x'.repeat(20001) })))
  assert.equal(res.statusCode, 413)
  assert.equal(res.json().error.code, 'TOO_LONG')
}

// ── invalid json ──────────────────────────────────────────────────────────
{
  const { routes } = buildCtx(textStream)
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', '{nope'))
  assert.equal(res.statusCode, 400)
  assert.equal(res.json().error.code, 'INVALID_JSON')
}

// ── happy path, special chars survive ─────────────────────────────────────
{
  let captured = null
  const fenced = '\u0060\u0060\u0060markdown\n增强后的提示词：\n请修复 @@BT@@a<b && c>d@@BT@@ 的解析。\n\u0060\u0060\u0060'.replaceAll('@@BT@@', String.fromCharCode(96))
  const { routes } = buildCtx((options) => {
    captured = options
    return textStream(fenced)
  })
  const input = '修一下 a<b && c>d，路径 C:\\Temp\\x.txt'
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: input })))
  const json = res.json()
  assert.equal(res.statusCode, 200, JSON.stringify(json))
  assert.equal(json.ok, true)
  assert.equal(json.finish, 'stop')
  assert.equal(json.text, '请修复 @@BT@@a<b && c>d@@BT@@ 的解析。'.replaceAll('@@BT@@', String.fromCharCode(96)))
  assert.equal(captured.provider, 'deepseek-account')
  assert.equal(captured.model, 'deepseek-flash')
  assert.ok(Array.isArray(captured.messages))
  assert.deepEqual(captured.messages[0].content[0].type, 'text')
  assert.ok(captured.messages[0].content[0].text.includes(input), 'raw input reached the model intact')
  assert.ok(typeof captured.system === 'string' && captured.system.length > 50)
  /* 字数硬上限随输入长度计算，token 预算按上限推算。 */
  assert.ok(captured.messages[0].content[0].text.includes('硬性要求：输出不得超过'), '提示词里带硬性字数上限')
  assert.equal(json.limit, 150, '短输入的字数上限是 150')
  assert.ok([...json.text].length <= json.limit, '输出不超过上限')
  assert.ok(captured.maxTokens >= 256)
  assert.ok(captured.maxTokens <= 8192)
}

// ── 输出 token 预算随字数上限增长，且不超过模型上限 ──────────────────────
{
  let captured = null
  const { routes } = buildCtx((options) => {
    captured = options
    return textStream('结果')
  })
  const input = '字'.repeat(2000)
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: input })))
  assert.equal(res.statusCode, 200)
  /* 2000 字输入 → 上限封顶 800 字 → token 预算按上限给，不再按 2 倍给预算。 */
  assert.equal(res.json().limit, 800, '长输入的字数上限封顶 800')
  assert.ok(captured.maxTokens >= 600, 'token 预算要覆盖 800 字上限，实际 ' + captured.maxTokens)
  assert.ok(captured.maxTokens <= 8192)
}

// ── 前言清理：中英文两种常见写法 ──────────────────────────────────────────
{
  const cases = [
    '好的，以下是增强后的提示词：\n\n请修复登录页的报错。',
    '当然可以。以下是优化后的提示词：\n\n请修复登录页的报错。',
    'Sure, here\'s the enhanced prompt:\n\nPlease fix the login page error.',
    '~~~markdown\n提示词：请修复登录页的报错。\n~~~',
  ]
  for (const raw of cases) {
    const { routes } = buildCtx(() => textStream(raw))
    const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '修登录页' })))
    const text = res.json().text
    assert.ok(!/增强后的提示词|优化后的提示词|enhanced prompt|^提示词：/i.test(text), 'preamble must be stripped: ' + JSON.stringify(text))
    assert.ok(text.includes('修复登录页') || text.includes('fix the login page'), 'body must survive: ' + JSON.stringify(text))
  }
}

// ── 真实协议下的模型失败映射到 502（旧实现会误报“原文已足够清晰”）────────
{
  const { routes } = buildCtx(() => errorStream('RATE_LIMIT', 'rate limited'))
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '你好' })))
  assert.equal(res.statusCode, 502)
  assert.equal(res.json().error.code, 'RATE_LIMIT')
  assert.equal(res.json().error.message, 'rate limited')
}

// ── 输出截断不得静默填入半截结果 ──────────────────────────────────────────
{
  let called = 0
  const { routes } = buildCtx(() => {
    called += 1
    return (async function* () {
      yield { type: 'text-delta', index: 0, text: '请帮我把这段文字' }
      yield finishChunk({ kind: 'max-tokens' })
    })()
  })
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '帮我改一下' })))
  assert.equal(called, 1)
  assert.equal(res.statusCode, 502, JSON.stringify(res.json()))
  assert.equal(res.json().error.code, 'OUTPUT_TRUNCATED')
  assert.ok(!('text' in res.json()), 'truncated text must not be returned')
}

// ── 非 stop 的异常结束同样报错 ────────────────────────────────────────────
{
  const { routes } = buildCtx(() => (async function* () {
    yield { type: 'text-delta', index: 0, text: '半截' }
    yield finishChunk({ kind: 'tool-calls' })
  })())
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '你好' })))
  assert.equal(res.statusCode, 502)
  assert.equal(res.json().error.code, 'UNEXPECTED_FINISH')
}

// ── aborted finish 映射到 504 ─────────────────────────────────────────────
{
  const { routes } = buildCtx(() => (async function* () {
    yield finishChunk({ kind: 'aborted', failure: { code: 'ABORTED', message: 'cancelled' } })
  })())
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '你好' })))
  assert.equal(res.statusCode, 504)
  assert.equal(res.json().error.code, 'TIMEOUT')
}

// ── 流没有 finish 收尾时不得静默返回半截内容 ─────────────────────────────
{
  const { routes } = buildCtx(() => (async function* () {
    yield { type: 'text-delta', index: 0, text: '半截' }
  })())
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '你好' })))
  assert.equal(res.statusCode, 502)
  assert.equal(res.json().error.code, 'STREAM_CLOSED')
  assert.ok(!('text' in res.json()))
}

// ── unchanged passthrough ─────────────────────────────────────────────────
{
  const { routes } = buildCtx(() => textStream('   '))
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '原样' })))
  assert.equal(res.statusCode, 200)
  assert.equal(res.json().text, '原样')
  assert.equal(res.json().unchanged, true)
}

// ── route disposal ────────────────────────────────────────────────────────
{
  const { ctx } = buildCtx(textStream)
  ctx.disposed()
}

// ── 会话上下文 ─────────────────────────────────────────────────────────────
/** 构造一条真人 user/message 事件。 */
function humanUserEvent(seq, text) {
  return {
    type: 'user/message',
    seq,
    data: { content: [{ type: 'text', text }], source: { kind: 'user' }, role: 'user' },
  }
}

/** 构造一条 assistant/message 事件（只留可见正文）。 */
function assistantEvent(seq, text) {
  return {
    type: 'assistant/message',
    seq,
    data: { message: { role: 'assistant', content: [{ type: 'text', text }] } },
  }
}

/** 带 sessionQuery 的上下文桩。 */
function buildCtxWithContext(streamImpl, events, options = {}) {
  const base = buildCtx(streamImpl)
  const observed = []
  base.ctx.get = (service) => {
    if (service === 'webServer') return base.ctx.get('webServer')
    if (service === 'agentDefaultModel') return { currentSelection: () => ({ provider: 'deepseek-account', model: 'deepseek-flash' }) }
    if (service === 'sessionQuery') {
      return {
        observeSession(sessionId, opts) {
          observed.push({ sessionId, opts })
          if (options.throwOnObserve) throw new Error('observe 失败')
          return Promise.resolve({
            events,
            async [Symbol.asyncDispose]() {},
          })
        },
      }
    }
    return undefined
  }
  return { ...base, observed }
}

// 上下文会进入 user 消息，且 system 切到带上下文版本
{
  let captured = null
  const { routes, observed } = buildCtxWithContext((options) => {
    captured = options
    return textStream('基于上一条方案的改写结果')
  }, [humanUserEvent(1, '帮我写个登录页'), assistantEvent(2, '好的，方案如下')])

  const res = await invoke(
    routes.get('/dsh-prompt-enhance/enhance'),
    makeReq('POST', JSON.stringify({ text: '就按刚才那个方案改一下', sessionId: 'session-abc' })),
  )
  const json = res.json()
  assert.equal(res.statusCode, 200, JSON.stringify(json))
  assert.equal(observed.length, 1)
  assert.equal(observed[0].sessionId, 'session-abc')

  const prompt = captured.messages[0].content[0].text
  assert.ok(prompt.includes('就按刚才那个方案改一下'), '原始输入完整送达')
  assert.ok(prompt.includes('帮我写个登录页'), '上文里的用户消息进入提示词')
  assert.ok(prompt.includes('方案如下'), '上文里的助手回复进入提示词')
  assert.ok(prompt.includes('[上一条消息·助手（重点）]'), '上一条消息带重点标记进入提示词')
  assert.ok(prompt.includes('必须优先深度理解'), '提示词要求先深度理解上一条消息')
  assert.ok(captured.system.includes('先解析上一条消息的具体内容'), 'system 要求先解析上一条消息内容')
  assert.ok(captured.system.includes('不得改变原始内容的主要表达意思'), 'system 明确不改主意思')
  assert.ok(captured.system.includes('若与上一条消息无关'), 'system 处理无关话题的情况')
  assert.ok(captured.system.includes('不得因为「要展开」而突破上限'), 'system 强调展开也不能突破上限')

  assert.equal(json.context.used, true)
  assert.equal(json.context.previousRole, 'assistant')
  assert.ok(json.context.previousText.includes('方案如下'))
  assert.ok(json.context.previousLength > 0, '回报上一条消息字数')
  assert.ok(json.context.blockChars > 0, '回报上下文块字数')
}

// 没有 sessionId 时不读会话，走无上下文路径
{
  let captured = null
  const { routes, observed } = buildCtxWithContext((options) => {
    captured = options
    return textStream('改写结果')
  }, [humanUserEvent(1, '你好')])
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '原始内容' })))
  assert.equal(res.statusCode, 200)
  assert.equal(observed.length, 0, '没有 sessionId 就不读会话')
  assert.ok(!captured.system.includes('先解析上一条消息的具体内容'), 'system 保持无上下文版本')
  assert.equal(res.json().context.used, false)
}

// sessionQuery 缺失时优雅降级，增强照常工作
{
  let captured = null
  const { routes } = buildCtx((options) => {
    captured = options
    return textStream('降级后的改写结果')
  })
  const res = await invoke(
    routes.get('/dsh-prompt-enhance/enhance'),
    makeReq('POST', JSON.stringify({ text: '原始内容', sessionId: 'session-xyz' })),
  )
  assert.equal(res.statusCode, 200, JSON.stringify(res.json()))
  assert.equal(res.json().context.used, false)
  assert.ok(!captured.system.includes('先解析上一条消息的具体内容'))
}

// 读取会话抛错时优雅降级
{
  const { routes } = buildCtxWithContext(() => textStream('降级后的改写结果'), [], { throwOnObserve: true })
  const res = await invoke(
    routes.get('/dsh-prompt-enhance/enhance'),
    makeReq('POST', JSON.stringify({ text: '原始内容', sessionId: 'session-err' })),
  )
  assert.equal(res.statusCode, 200, JSON.stringify(res.json()))
  assert.equal(res.json().context.used, false)
}

// 系统注入的快照消息不进上下文
{
  let captured = null
  const injected = {
    type: 'user/message',
    seq: 1,
    data: { content: [{ type: 'text', text: 'Current runtime context...' }], source: { kind: 'runtime-context' } },
  }
  const { routes } = buildCtxWithContext((options) => {
    captured = options
    return textStream('改写结果')
  }, [injected, humanUserEvent(2, '真人输入')])
  const res = await invoke(
    routes.get('/dsh-prompt-enhance/enhance'),
    makeReq('POST', JSON.stringify({ text: '原始内容', sessionId: 'session-inj' })),
  )
  assert.equal(res.statusCode, 200)
  const prompt = captured.messages[0].content[0].text
  assert.ok(prompt.includes('真人输入'), '真人输入进上下文')
  assert.ok(!prompt.includes('Current runtime context'), '系统注入不进上下文')
}

// ── 字数硬上限：按输入长度计算，最低 150、封顶 800 ────────────────────────
{
  assert.equal(computeOutputLimit(11), 150)
  assert.equal(computeOutputLimit(0), 150)
  assert.equal(computeOutputLimit(200), 380)
  assert.equal(computeOutputLimit(2000), 800)
  assert.equal(computeOutputLimit(-5), 150)
}

// ── 硬截断：超限时切在句末并补省略号，长度不超上限 ────────────────────────
{
  const long = '第一句话讲目标。第二句话讲约束。第三句话说很多很多细节。'.repeat(5)
  const cut = hardTrimToLimit(long, 40)
  assert.equal(cut.trimmed, true)
  assert.ok([...cut.text].length <= 40, '截断后不超上限，实际 ' + [...cut.text].length)
  assert.ok(cut.text.endsWith('…'))
  const short = hardTrimToLimit('短文本', 100)
  assert.equal(short.trimmed, false)
  assert.equal(short.text, '短文本')
}

// ── 超限触发压缩重写：第二次调用用压缩提示词，结果不超上限 ────────────────
{
  let calls = 0
  const seen = []
  const input = '把登录页改一下'
  const limit = computeOutputLimit(input.length)
  const tooLong = '很长的内容。'.repeat(Math.ceil(limit / 3))
  const { routes } = buildCtx((options) => {
    calls += 1
    seen.push(options)
    return textStream(calls === 1 ? tooLong : '压缩后的提示词：改登录页，保留现有结构，补暗色模式。')
  })
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: input })))
  const json = res.json()
  assert.equal(res.statusCode, 200, JSON.stringify(json))
  assert.equal(calls, 2, '超限要再调一次模型做压缩')
  assert.equal(json.compressed, true)
  assert.ok(json.text.length <= json.limit, '压缩后不超上限')
  assert.ok(seen[1].system.includes('提示词压缩器'), '第二次用压缩专用 system')
  assert.ok(seen[1].messages[0].content[0].text.includes('待压缩的提示词'), '第二次请求带上待压缩内容')
}

// ── 压缩后仍超限：硬截断兜底，绝不放超长结果 ──────────────────────────────
{
  let calls = 0
  const input = '把登录页改一下'
  const limit = computeOutputLimit(input.length)
  const stillTooLong = '还是很长的内容。'.repeat(Math.ceil(limit / 3) + 20)
  const { routes } = buildCtx(() => {
    calls += 1
    return textStream(stillTooLong)
  })
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: input })))
  const json = res.json()
  assert.equal(res.statusCode, 200)
  assert.equal(calls, 2)
  assert.equal(json.trimmed, true, '二次仍超限要标记 trimmed')
  assert.ok([...json.text].length <= json.limit, '兜底截断后仍不超上限，实际 ' + [...json.text].length)
}

console.log('host smoke: ok')
