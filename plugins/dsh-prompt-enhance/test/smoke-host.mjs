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

function textStream(text) {
  return (async function* () {
    yield { type: 'block-start', blockType: 'text' }
    yield { type: 'text-delta', text }
    yield { type: 'finish', kind: 'stop' }
  })()
}

function errorStream(code, message) {
  return (async function* () {
    yield { type: 'finish', kind: 'error', failure: { code, message } }
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
  const fenced = '```markdown\n增强后的提示词：\n请修复 @@BT@@a<b && c>d@@BT@@ 的解析。\n```'.replaceAll('@@BT@@', String.fromCharCode(96))
  const { routes } = buildCtx((options) => {
    captured = options
    return textStream(fenced)
  })
  const input = '修一下 a<b && c>d，路径 C:\\Temp\\x.txt'
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: input })))
  const json = res.json()
  assert.equal(res.statusCode, 200, JSON.stringify(json))
  assert.equal(json.ok, true)
  assert.equal(json.text, '请修复 @@BT@@a<b && c>d@@BT@@ 的解析。'.replaceAll('@@BT@@', String.fromCharCode(96)))
  assert.equal(captured.provider, 'deepseek-account')
  assert.equal(captured.model, 'deepseek-flash')
  assert.ok(Array.isArray(captured.messages))
  assert.deepEqual(captured.messages[0].content[0].type, 'text')
  assert.ok(captured.messages[0].content[0].text.includes(input), 'raw input reached the model intact')
  assert.ok(typeof captured.system === 'string' && captured.system.length > 50)
}

// ── model failure maps to 502 ─────────────────────────────────────────────
{
  const { routes } = buildCtx(() => errorStream('RATE_LIMIT', 'rate limited'))
  const res = await invoke(routes.get('/dsh-prompt-enhance/enhance'), makeReq('POST', JSON.stringify({ text: '你好' })))
  assert.equal(res.statusCode, 502)
  assert.equal(res.json().error.code, 'RATE_LIMIT')
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
