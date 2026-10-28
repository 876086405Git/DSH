import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { apply, inject, name } from '../lib/index.js'

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
  /* 规则允许改写到 2 倍；输出预算必须覆盖它，截断另由 finish=max-tokens 报错。 */
  assert.ok(captured.maxTokens >= 2048)
  assert.ok(captured.maxTokens <= 8192)
}

// ── 输出预算随输入增长，并覆盖 2 倍改写 ──────────────────────────────────
{
  let captured = null
  const { routes } = buildCtx((options) => {
    captured = options
    return textStream('结果')
  })
  const input = '字'.repeat(2000)
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: input })))
  assert.equal(res.statusCode, 200)
  assert.ok(captured.maxTokens >= 4000, 'budget should cover 2x rewrite, got ' + captured.maxTokens)
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

console.log('host smoke: ok')
