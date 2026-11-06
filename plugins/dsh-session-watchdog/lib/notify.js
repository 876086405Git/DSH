/**
 * 会话哨兵 —— 提醒通道（宿主侧）。
 *
 * 宿主本身不弹窗（Electron main 拿不到通知能力，且 Host 是独立子进程），
 * 这里维护一个「提醒事件流」并通过 webServer 路由下发给浏览器半侧：
 *   GET  /dsh-session-watchdog/config   → 公开配置（只读）
 *   GET  /dsh-session-watchdog/alerts   → 增量提醒（cursor 游标）
 *   POST /dsh-session-watchdog/action   → 手动续跑 / 忽略（同源校验 + 体积上限）
 */

/** 兼容旧客户端的精简配置（系统通知 / 卡片开关 / 停留时长）。 */
export function publicConfig(config) {
  return {
    notifyOs: config.notifyOs === true,
    notifyGui: config.notifyGui === true,
    toastDurationMs: Number.isFinite(config.toastDurationMs) ? config.toastDurationMs : 8000,
  }
}

/** 设置面板用的完整配置载荷（不含任何密钥；字段都可安全展示）。 */
export function configPayload(config, extra = {}) {
  return {
    config: { ...config },
    public: publicConfig(config),
    ...extra,
  }
}

/**
 * 提醒事件流：按 cursor 增量拉取，更新同一条提醒会推进 cursor。
 * @param {{max?: number}} [options]
 */
export function createFeed(options = {}) {
  const max = Number.isFinite(options.max) ? options.max : 200
  let cursor = 0
  /** @type {Map<string, any>} */
  const alerts = new Map()

  function touch(alert) {
    cursor += 1
    alert.cursor = cursor
    alerts.set(alert.id, alert)
    if (alerts.size > max) {
      const oldest = alerts.keys().next().value
      alerts.delete(oldest)
    }
    return alert
  }

  function push(alert) {
    if (!alert || typeof alert.id !== 'string') return null
    return touch({ ...alert })
  }

  function update(id, patch) {
    const current = alerts.get(id)
    if (!current) return null
    return touch({ ...current, ...patch })
  }

  function since(value) {
    const from = Number.isFinite(value) ? value : 0
    const items = []
    for (const alert of alerts.values()) {
      if (alert.cursor > from) items.push({ ...alert })
    }
    items.sort((a, b) => a.cursor - b.cursor)
    return { cursor, alerts: items }
  }

  function get(id) { return alerts.get(id) || null }
  function list() { return Array.from(alerts.values()) }
  function clear() { alerts.clear() }

  return { push, update, since, get, list, clear, get cursor() { return cursor } }
}

function readJsonBody(request, limit = 64 * 1024) {
  return new Promise((resolve) => {
    let size = 0
    const chunks = []
    let done = false
    const finish = (value) => {
      if (done) return
      done = true
      resolve(value)
    }
    try {
      request.on('data', (chunk) => {
        size += chunk.length
        if (size > limit) { finish(null); try { request.destroy() } catch { /* noop */ } return }
        chunks.push(chunk)
      })
      request.on('end', () => {
        if (chunks.length === 0) return finish({})
        try { finish(JSON.parse(Buffer.concat(chunks).toString('utf8'))) } catch { finish(null) }
      })
      request.on('error', () => finish(null))
    } catch {
      finish(null)
    }
  })
}

/** 同源校验：OPTIONS 之外只接受与 Host 同源的请求，防止跨站触发续跑。 */
function sameOrigin(request) {
  const origin = request.headers && request.headers.origin
  if (typeof origin !== 'string' || origin === '') return true
  try {
    const host = (request.headers.host || '').toLowerCase()
    const originHost = new URL(origin).host.toLowerCase()
    return originHost === host
  } catch {
    return false
  }
}

function writeJson(response, status, payload) {
  try {
    const body = JSON.stringify(payload)
    response.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'content-length': Buffer.byteLength(body),
    })
    response.end(body)
  } catch { /* 连接已关闭 */ }
}

/**
 * 注册四条路由：config 读写、alerts 增量、action 操作。
 * @param {{ctx:any, feed:ReturnType<typeof createFeed>, config:any, onAction:(id:string, action:string)=>Promise<any>, logger?:any}} options
 */
export function registerRoutes(options) {
  const { ctx, feed, config, onAction, logger, getConfig, updateConfig, resetConfig } = options
  const register = (scope) => {
    const webServer = scope && scope.webServer
    if (!webServer || typeof webServer.register !== 'function') return
    scope.effect(() => {
      const disposers = []
      disposers.push(webServer.register({
        kind: 'exact',
        path: '/dsh-session-watchdog/alerts',
        handler: (request, response) => {
          try {
            if (request.method !== 'GET' && request.method !== 'HEAD') { response.writeHead(405, { allow: 'GET, HEAD, OPTIONS' }); response.end(); return }
            let since = 0
            try { since = Number(new URL(request.url || '/', 'http://localhost').searchParams.get('since') || 0) } catch { since = 0 }
            const snapshot = feed.since(Number.isFinite(since) ? since : 0)
            writeJson(response, 200, { ok: true, cursor: snapshot.cursor, alerts: snapshot.alerts })
          } catch (error) { writeJson(response, 500, { ok: false, error: String(error && error.message ? error.message : error) }) }
        },
      }))
      disposers.push(webServer.register({
        kind: 'exact',
        path: '/dsh-session-watchdog/config',
        handler: async (request, response) => {
          try {
            if (request.method === 'GET' || request.method === 'HEAD') {
              const payload = typeof getConfig === 'function' ? getConfig() : { config: { ...config }, public: publicConfig(config) }
              writeJson(response, 200, { ok: true, ...payload })
              return
            }
            if (request.method === 'OPTIONS') { response.writeHead(204, { allow: 'GET, HEAD, POST, OPTIONS' }); response.end(); return }
            if (request.method !== 'POST') { response.writeHead(405, { allow: 'GET, HEAD, POST, OPTIONS' }); response.end(); return }
            if (!sameOrigin(request)) { writeJson(response, 403, { ok: false, error: 'cross-origin' }); return }
            const body = await readJsonBody(request)
            if (!body || typeof body !== 'object') { writeJson(response, 400, { ok: false, error: 'bad-request' }); return }
            let result
            if (body.reset === true) result = typeof resetConfig === 'function' ? resetConfig() : { ok: false, error: 'reset-unsupported' }
            else result = typeof updateConfig === 'function' ? updateConfig(body.patch || body.config || body) : { ok: false, error: 'update-unsupported' }
            if (!result || result.ok !== true) { writeJson(response, 400, { ok: false, error: (result && result.error) || 'update-failed' }); return }
            const payload = typeof getConfig === 'function' ? getConfig() : { config: { ...config }, public: publicConfig(config) }
            writeJson(response, 200, { ok: true, ...payload })
          } catch (error) {
            try { logger?.warn?.('session-watchdog: 配置路由异常 ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
            writeJson(response, 500, { ok: false, error: String(error && error.message ? error.message : error) })
          }
        },
      }))
      disposers.push(webServer.register({
        kind: 'exact',
        path: '/dsh-session-watchdog/action',
        handler: async (request, response) => {
          try {
            if (request.method === 'OPTIONS') { response.writeHead(204, { allow: 'POST, OPTIONS' }); response.end(); return }
            if (request.method !== 'POST') { response.writeHead(405, { allow: 'POST, OPTIONS' }); response.end(); return }
            if (!sameOrigin(request)) { writeJson(response, 403, { ok: false, error: 'cross-origin' }); return }
            const body = await readJsonBody(request)
            if (!body || typeof body.id !== 'string' || typeof body.action !== 'string') { writeJson(response, 400, { ok: false, error: 'bad-request' }); return }
            const result = await onAction(body.id, body.action)
            writeJson(response, 200, { ok: true, result })
          } catch (error) {
            try { logger?.warn?.('session-watchdog: action 失败 ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
            writeJson(response, 500, { ok: false, error: String(error && error.message ? error.message : error) })
          }
        },
      }))
      return () => {
        for (const dispose of disposers) {
          try { if (typeof dispose === 'function') dispose() } catch { /* noop */ }
        }
      }
    }, 'session-watchdog: routes')
  }
  if (typeof ctx.inject !== 'function') return
  ctx.inject(['webServer'], (scope) => {
    try { register(scope) } catch (error) {
      try { logger?.warn?.('session-watchdog: 路由注册失败 ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
    }
  })
}
