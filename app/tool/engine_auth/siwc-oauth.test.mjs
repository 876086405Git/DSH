// SPDX-License-Identifier: MIT

import assert from 'node:assert/strict'
import { createHash, generateKeyPairSync, sign } from 'node:crypto'
import { request } from 'node:http'
import { test } from 'node:test'

import { createSiwcOAuth } from '../../assets/engine/auth/siwc/oauth.mjs'

const ISSUER = 'https://auth.openai.com'
const AUTHORIZE = ISSUER + '/api/accounts/authorize'
const TOKEN = ISSUER + '/api/accounts/oauth/token'
const DISCOVERY = ISSUER + '/.well-known/openid-configuration'
const REVOKE = ISSUER + '/api/accounts/oauth/revoke'
const JWKS = ISSUER + '/.well-known/jwks.json'
const RESOURCE = 'https://api.openai.com/v1'
const HOST = 'urn:uuid:983a2a22-265a-4a73-923a-c0b76bb15273'
const CLIENT = 'oaiapp_mock'
const PLAN = 'chatgpt.tokens.use.direct'
const SCOPE = 'openid profile email offline_access resource.invoke ' + PLAN
const ACCOUNT = { subject: 'mock-subject', email: 'mock@example.invalid' }
const OUT = { signedIn: false, planEnabled: false }
const IN = { signedIn: true, planEnabled: true, account: ACCOUNT }
const META = { ...ACCOUNT, clientId: CLIENT, scopes: [] }
const RECONNECT = { ...OUT, reconnectAvailable: true }
const key = generateKeyPairSync('rsa', { modulusLength: 2048 })
const jwk = { ...key.publicKey.export({ format: 'jwk' }), kid: 'mock-kid', alg: 'RS256', use: 'sig' }

const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')
const digest = (value) => createHash('sha256').update(value).digest('base64url')

function tokens(nonce, { claims = {}, forged = false, fields = {} } = {}) {
  const now = Math.floor(Date.now() / 1000)
  const signed = encode({ alg: 'RS256', kid: jwk.kid }) + '.' + encode({
    iss: ISSUER, aud: [CLIENT], sub: ACCOUNT.subject, email: ACCOUNT.email,
    exp: now + 3600, iat: now, nonce, ...claims,
  })
  const signature = forged ? Buffer.alloc(256) : sign('RSA-SHA256', Buffer.from(signed), key.privateKey)
  return {
    access_token: 'mock-access', refresh_token: 'mock-refresh', token_type: 'Bearer',
    id_token: signed + '.' + signature.toString('base64url'), expires_in: 3600, scope: SCOPE, ...fields,
  }
}

const expired = () => ({
  ...ACCOUNT, clientId: CLIENT, accessToken: 'old-access', refreshToken: 'old-refresh',
  idToken: tokens('old-nonce').id_token, nonce: 'old-nonce', scopes: SCOPE.split(' '), expiresAt: Date.now() - 1,
})
const rotation = (fields = {}) => Response.json({
  access_token: 'rotated-access', refresh_token: 'rotated-refresh', token_type: 'Bearer', expires_in: 3600, ...fields,
})

function fixture({ exchange, revoke = () => new Response(null), keys = () => Response.json({ keys: [jwk] }), initial = null, discovery, save, onLoad, onClear, onGrantLost } = {}) {
  let record = initial
  const saves = [], calls = []
  const store = {
    async load() {
      await onLoad?.()
      return structuredClone(record)
    },
    async save(value) {
      await save?.(value)
      saves.push(structuredClone(value))
      record = structuredClone(value)
    },
    async clear() {
      await onClear?.()
      record = null
    },
  }
  async function fetch(url, options) {
    const form = options.body && Object.fromEntries(options.body)
    calls.push({ url, form })
    assert.equal(options.redirect, 'error')
    if (url === JWKS && options.method === 'GET') return keys()
    if (url === DISCOVERY && options.method === 'GET') {
      return Response.json(discovery ?? { issuer: ISSUER, revocation_endpoint: REVOKE })
    }
    assert.equal(options.method, 'POST')
    assert.equal(options.headers['content-type'], 'application/x-www-form-urlencoded')
    if (url === REVOKE) return revoke(form)
    assert.equal(url, TOKEN)
    return exchange(form)
  }
  const open = () => createSiwcOAuth({ fetch, store, getHostId: async () => HOST, onGrantLost })
  return { oauth: open(), open, calls, saves, record: () => record }
}

// Only the 127.0.0.1 browser callback uses a socket. OpenAI requests are injected.
function hit(url, options) {
  return new Promise((resolve, reject) => {
    const req = request(url, { agent: false, ...options }, (res) => {
      res.setEncoding('utf8')
      let text = ''
      res.on('data', (chunk) => { text += chunk })
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text }))
      res.on('error', reject)
    })
    req.setTimeout(1_000, () => req.destroy(new Error('Mock callback timed out')))
    req.on('error', reject)
    req.end()
  })
}

function callbackOf(auth, fields = {}) {
  const redirect = new URL(auth.searchParams.get('redirect_uri'))
  const query = { code: 'mock-code', state: auth.searchParams.get('state'), ...fields }
  for (const [key, value] of Object.entries(query)) if (value !== null) redirect.searchParams.set(key, value)
  return redirect
}

function signInAs(oauth, inspect, fields = { client_id: CLIENT }, newAccount = false) {
  return oauth.signIn({ newAccount, notify: async (url) => {
    const auth = new URL(url)
    await inspect(auth)
    await hit(callbackOf(auth, fields))
  } })
}

test('dynamic signup sends exact callback/PKCE and rejects unrelated callbacks', async () => {
  let auth
  const f = fixture({ exchange: (form) => {
    assert.deepEqual(form, {
      client_id: CLIENT, code: 'mock-code', code_verifier: form.code_verifier,
      grant_type: 'authorization_code', redirect_uri: auth.searchParams.get('redirect_uri'), resource: RESOURCE,
    })
    assert.match(form.code_verifier, /^[A-Za-z0-9_-]{43}$/)
    assert.equal(digest(form.code_verifier), auth.searchParams.get('code_challenge'))
    return Response.json(tokens(auth.searchParams.get('nonce')))
  } })
  assert.deepEqual(await f.oauth.status(), OUT)
  assert.deepEqual(await f.oauth.signIn({ notify: async (url) => {
    auth = new URL(url)
    const q = auth.searchParams
    assert.equal(auth.origin + auth.pathname, AUTHORIZE)
    assert.equal(q.get('client_id'), 'dynamic_agent_client')
    assert.equal(q.get('agent_name_hint'), 'dsh-Go')
    assert.equal(q.get('ext_agent_host_id'), HOST)
    assert.equal(q.get('scope'), SCOPE)
    assert.equal(q.get('resource'), RESOURCE)
    assert.equal(q.get('response_type'), 'code')
    assert.equal(q.get('code_challenge_method'), 'S256')
    assert.match(q.get('state'), /^[A-Za-z0-9_-]{43}$/)
    assert.match(q.get('nonce'), /^[A-Za-z0-9_-]{43}$/)
    assert.notEqual(q.get('state'), q.get('nonce'))
    assert.match(q.get('redirect_uri'), /^http:\/\/127\.0\.0\.1:[1-9][0-9]*\/auth\/callback$/)
    const callback = callbackOf(auth, { client_id: CLIENT, scope: 'openid' })
    assert.equal((await hit(callback, { headers: { Host: 'other.invalid' } })).status, 404)
    assert.equal((await hit(callback, { method: 'POST' })).status, 404)
    const wrongPath = new URL(callback)
    wrongPath.pathname = '/callback'
    assert.equal((await hit(wrongPath)).status, 404)
    assert.equal((await hit(callbackOf(auth, { state: 'wrong', error: 'access_denied', code: null }))).status, 400)
    const duplicate = new URL(callback)
    duplicate.searchParams.append('state', q.get('state'))
    assert.equal((await hit(duplicate)).status, 400)
    assert.equal(f.calls.length, 0)
    const reply = await hit(callback)
    assert.equal(reply.status, 200)
    assert.equal(reply.headers['cache-control'], 'no-store')
    assert.equal(reply.headers['referrer-policy'], 'no-referrer')
    assert.doesNotMatch(reply.text, /mock-code|mock-refresh/)
  } }), IN)
  assert.deepEqual(await f.open().status(), IN)
  assert.equal(await f.oauth.token(), 'mock-access')
  assert.deepEqual(f.record().scopes, SCOPE.split(' '))
  assert.deepEqual(f.calls.map(({ url }) => url), [TOKEN, JWKS])
})

test('validated existing client can be reused; swapped client and subject never overwrite it', async () => {
  let nonce, wrongSubject = true
  const f = fixture({ initial: expired(), exchange: () => Response.json(tokens(nonce, {
    claims: wrongSubject ? { sub: 'other-subject' } : { email: 'new@example.invalid' },
  })) })
  const auths = []
  const inspect = (auth) => {
    auths.push(auth)
    assert.equal(auth.searchParams.get('client_id'), CLIENT)
    assert.equal(auth.searchParams.get('ext_agent_host_id'), HOST)
    assert.equal(auth.searchParams.has('agent_name_hint'), false)
    assert.equal(auth.searchParams.has('id_token_hint'), false)
    nonce = auth.searchParams.get('nonce')
  }
  await assert.rejects(signInAs(f.oauth, inspect, { client_id: 'oaiapp_other' }), { code: 'siwc_invalid_callback' })
  assert.equal(f.calls.length, 0)
  await assert.rejects(signInAs(f.oauth, inspect, {}), { code: 'siwc_invalid_identity' })
  assert.equal(f.record().accessToken, 'old-access')
  assert.equal(f.saves.length, 0)
  wrongSubject = false
  assert.deepEqual(await signInAs(f.oauth, inspect, {}), { ...IN, account: { ...ACCOUNT, email: 'new@example.invalid' } })
  for (const key of ['state', 'nonce', 'code_challenge']) {
    assert.equal(new Set(auths.map((url) => url.searchParams.get(key))).size, 3)
  }
})

test('reconnect reuses the saved client, and switching requires explicit intent after sign-out', async () => {
  const otherClient = 'oaiapp_other'
  const otherAccount = { subject: 'other-subject', email: 'other@example.invalid' }
  let nonce, offline = false
  const f = fixture({ initial: { ...META, signedOut: true }, exchange: (form) => {
    if (offline) throw new Error('mock network failure')
    const claims = form.client_id === otherClient ? { aud: otherClient, sub: otherAccount.subject, email: otherAccount.email } : {}
    return Response.json(tokens(nonce, { claims }))
  } })
  const inspect = (clientId) => (auth) => {
    assert.equal(auth.searchParams.get('client_id'), clientId)
    assert.equal(auth.searchParams.get('ext_agent_host_id'), HOST)
    nonce = auth.searchParams.get('nonce')
  }
  assert.deepEqual(await f.oauth.status(), RECONNECT)
  assert.deepEqual(await signInAs(f.oauth, inspect(CLIENT), {}), IN)
  await assert.rejects(f.oauth.signIn({ newAccount: true, notify: () => assert.fail('must not notify') }), { code: 'siwc_sign_out_required' })
  await f.oauth.signOut()
  assert.deepEqual(await f.oauth.status(), RECONNECT)
  const dynamic = inspect('dynamic_agent_client')
  await assert.rejects(signInAs(f.oauth, dynamic, { code: null, error: 'access_denied' }, true), { code: 'siwc_access_denied' })
  offline = true
  await assert.rejects(signInAs(f.oauth, dynamic, { client_id: otherClient }, true), { code: 'siwc_network' })
  assert.deepEqual(f.record(), META)
  assert.deepEqual(await f.open().status(), RECONNECT)
  offline = false
  assert.deepEqual(await signInAs(f.oauth, dynamic, { client_id: otherClient }, true), { ...IN, account: otherAccount })
  assert.equal(f.record().clientId, otherClient)
  assert.deepEqual(await f.open().status(), { ...IN, account: otherAccount })
})

test('only retrying a denied verified registration requests consent', async () => {
  let nonce
  const f = fixture({ initial: META, exchange: () => Response.json(tokens(nonce)) })
  const denied = { code: null, error: 'access_denied' }
  const inspect = (client, prompt) => (auth) => {
    assert.equal(auth.searchParams.get('client_id'), client)
    assert.equal(auth.searchParams.get('prompt'), prompt)
    nonce = auth.searchParams.get('nonce')
  }
  await assert.rejects(signInAs(f.oauth, inspect('dynamic_agent_client', null), denied, true), { code: 'siwc_access_denied' })
  await assert.rejects(signInAs(f.oauth, inspect(CLIENT, null), denied), { code: 'siwc_access_denied' })
  assert.deepEqual(f.record(), META)
  assert.equal(f.calls.length, 0)
  assert.deepEqual(await signInAs(f.oauth, inspect(CLIENT, 'consent'), {}), IN)
  assert.deepEqual(await signInAs(f.oauth, inspect(CLIENT, null), {}), IN)
})

test('invalid_grant restarts only once with the issued client and a new verifier', async () => {
  const auths = []
  const f = fixture({ exchange: () => Response.json({ error: 'invalid_grant' }, { status: 400 }) })
  await assert.rejects(f.oauth.signIn({ notify: async (url) => {
    const auth = new URL(url)
    auths.push(auth)
    await hit(callbackOf(auth, auths.length === 1 ? { client_id: CLIENT } : {}))
  } }), { code: 'siwc_invalid_grant' })
  assert.deepEqual(auths.map((url) => url.searchParams.get('client_id')), ['dynamic_agent_client', CLIENT])
  const exchanges = f.calls.map(({ form }) => form)
  assert.equal(exchanges.length, 2)
  assert.notEqual(exchanges[0].code_verifier, exchanges[1].code_verifier)
  assert.deepEqual(exchanges.map((form) => form.client_id), [CLIENT, CLIENT])
  assert.equal(f.saves.length, 0)
})

test('incomplete or denied registration never exchanges a code or echoes provider data', async (t) => {
  for (const [name, fields, code] of [
    ['missing client', {}, 'siwc_invalid_callback'],
    ['dynamic sentinel', { client_id: 'dynamic_agent_client' }, 'siwc_invalid_callback'],
    ['denied', { code: null, error: 'access_denied', error_description: 'mock-private-detail' }, 'siwc_access_denied'],
  ]) await t.test(name, async () => {
    const f = fixture()
    await assert.rejects(signInAs(f.oauth, () => {}, fields), (cause) => {
      assert.equal(cause.code, code)
      assert.doesNotMatch(cause.message, /mock-private-detail|mock-code/)
      return true
    })
    assert.equal(f.calls.length, 0)
    assert.deepEqual(await f.oauth.status(), OUT)
  })
})

test('rejects invalid signed identity before saving any token', async (t) => {
  for (const [name, input] of [
    ['signature', { forged: true }],
    ['issuer', { claims: { iss: 'https://mock.invalid' } }],
    ['audience', { claims: { aud: 'oaiapp_other' } }],
    ['nonce', { claims: { nonce: 'previous-nonce' } }],
    ['expiration', { claims: { exp: 1 } }],
    ['missing subject', { claims: { sub: undefined } }],
    ['access token hash', { claims: { at_hash: 'mismatched' } }],
  ]) await t.test(name, async () => {
    let nonce
    const f = fixture({ exchange: () => Response.json(tokens(nonce, input)) })
    await assert.rejects(signInAs(f.oauth, (auth) => { nonce = auth.searchParams.get('nonce') }), { code: 'siwc_invalid_identity' })
    assert.deepEqual(await f.oauth.status(), OUT)
    assert.equal(f.saves.length, 0)
  })
})

test('missing plan scope retains the identity but never supplies an inference token', async () => {
  let nonce
  const f = fixture({ exchange: () => Response.json(tokens(nonce, { fields: { scope: 'openid profile email', refresh_token: undefined } })) })
  const status = await signInAs(f.oauth, (auth) => { nonce = auth.searchParams.get('nonce') })
  assert.deepEqual(status, { ...IN, planEnabled: false })
  await assert.rejects(f.oauth.token(), { code: 'siwc_plan_permission_missing' })
  await signInAs(f.oauth, (auth) => {
    nonce = auth.searchParams.get('nonce')
    assert.equal(auth.searchParams.get('prompt'), 'consent')
    assert.equal(auth.searchParams.get('scope'), SCOPE)
  }, {})
  assert.deepEqual(await f.oauth.status(), status)
})

test('cancel closes loopback and never leaks a caller-supplied cancellation reason', async () => {
  const f = fixture()
  const browser = Promise.withResolvers()
  const controller = new AbortController()
  const attempt = f.oauth.signIn({ signal: controller.signal, notify: browser.resolve })
  const auth = new URL(await browser.promise)
  await assert.rejects(f.oauth.signIn({ notify: () => assert.fail('must not notify') }), { code: 'siwc_busy' })
  controller.abort(new Error('mock-private-abort'))
  await assert.rejects(attempt, (cause) => {
    assert.equal(cause.code, 'siwc_cancelled')
    assert.doesNotMatch(cause.message, /mock-private-abort/)
    return true
  })
  await assert.rejects(hit(callbackOf(auth)))
  assert.deepEqual(await f.oauth.status(), OUT)
})

test('only rejection of the current access token forces a shared refresh on the next request', async () => {
  let attempts = 0
  const f = fixture({ initial: { ...expired(), expiresAt: Date.now() + 3_600_000 }, exchange: (form) => {
    assert.equal(form.refresh_token, 'old-refresh')
    if (++attempts === 1) throw new Error('mock network failure')
    return rotation()
  } })
  f.oauth.rejectAccess('old-access') // Not loaded yet: do not affect the saved grant.
  assert.equal(await f.oauth.token(), 'old-access')
  f.oauth.rejectAccess('unrelated-access')
  assert.equal(await f.oauth.token(), 'old-access')
  f.oauth.rejectAccess('old-access')
  assert.equal(f.calls.length, 0)
  await assert.rejects(f.oauth.token(), { code: 'siwc_network' })
  assert.equal(f.record().refreshToken, 'old-refresh')
  assert.deepEqual(await f.oauth.status(), IN)
  assert.deepEqual(await Promise.all([f.oauth.token(), f.oauth.token()]), ['rotated-access', 'rotated-access'])
  f.oauth.rejectAccess('old-access') // Late response from the original request.
  assert.equal(await f.oauth.token(), 'rotated-access')
  assert.equal(attempts, 2)
})

test('rejects an unchanged access token after refresh and clears only when refresh is terminal', async () => {
  let attempts = 0
  const f = fixture({ initial: { ...expired(), expiresAt: Date.now() + 3_600_000 }, exchange: (form) => {
    if (++attempts === 1) return rotation({ access_token: 'old-access' })
    assert.equal(form.refresh_token, 'rotated-refresh')
    return Response.json({ error: 'invalid_grant' }, { status: 400 })
  } })
  f.oauth.rejectAccess(await f.oauth.token())
  await assert.rejects(f.oauth.token(), { code: 'siwc_access_rejected' })
  assert.equal(attempts, 1)
  assert.equal(f.record().refreshToken, 'rotated-refresh')
  await assert.rejects(f.oauth.token(), { code: 'siwc_session_expired' })
  assert.deepEqual(f.record(), META)
})

test('one refresh for concurrent readers; one cancellation does not cancel rotation', async () => {
  const started = Promise.withResolvers(), ready = Promise.withResolvers()
  const f = fixture({ initial: expired(), exchange: async (form) => {
    assert.deepEqual(form, { grant_type: 'refresh_token', refresh_token: 'old-refresh', client_id: CLIENT, resource: RESOURCE })
    started.resolve()
    await ready.promise
    return rotation()
  } })
  const controller = new AbortController()
  const abandoned = assert.rejects(f.oauth.token(controller.signal), { code: 'siwc_cancelled' })
  const b = f.oauth.token(), c = f.oauth.token()
  await started.promise
  controller.abort()
  await abandoned
  ready.resolve()
  assert.deepEqual(await Promise.all([b, c]), ['rotated-access', 'rotated-access'])
  assert.equal(f.calls.length, 1)
  assert.equal(f.saves.length, 1)
  assert.equal(f.record().refreshToken, 'rotated-refresh')
  assert.deepEqual(f.record().scopes, SCOPE.split(' '))
  assert.equal(await f.open().token(), 'rotated-access')
})

test('refresh scope loss invalidates once after save, while keeping the account signed in', async () => {
  const scope = 'openid profile email offline_access resource.invoke'
  let failSave = true
  const notices = []
  const f = fixture({
    initial: expired(),
    exchange: () => rotation({ scope }),
    save: () => { if (failSave) throw new Error('mock storage error') },
    onGrantLost: () => notices.push(f.record().scopes),
  })
  await assert.rejects(f.oauth.token(), { code: 'siwc_store_failed' })
  assert.deepEqual(notices, [])
  assert.deepEqual(f.record().scopes, SCOPE.split(' '))
  failSave = false
  await assert.rejects(f.oauth.token(), { code: 'siwc_plan_permission_missing' })
  await assert.rejects(f.oauth.token(), { code: 'siwc_plan_permission_missing' })
  const signedInWithoutPlan = { ...IN, planEnabled: false }
  assert.deepEqual(await f.oauth.status(), signedInWithoutPlan)
  assert.deepEqual(await f.open().status(), signedInWithoutPlan)
  assert.deepEqual(notices, [scope.split(' ')])
  assert.equal(f.record().refreshToken, 'rotated-refresh')
  assert.equal(f.calls.filter(({ url }) => url === TOKEN).length, 1)
})

test('JWKS-pending scope loss invalidates once; saving verified identity does not repeat it', async () => {
  const scope = 'openid profile email offline_access resource.invoke'
  let available = false
  const notices = []
  const f = fixture({
    initial: expired(),
    exchange: () => rotation({ scope, id_token: tokens('old-nonce').id_token }),
    keys: () => available ? Response.json({ keys: [jwk] }) : new Response(null, { status: 503 }),
    onGrantLost: () => notices.push(f.record().scopes),
  })
  await assert.rejects(f.oauth.token(), { code: 'siwc_unavailable' })
  assert.equal(f.record().pendingIdentity, true)
  assert.deepEqual(await f.oauth.status(), { ...IN, planEnabled: false })
  assert.deepEqual(notices, [scope.split(' ')])
  await assert.rejects(f.oauth.token(), { code: 'siwc_unavailable' })
  assert.deepEqual(notices, [scope.split(' ')])
  available = true
  await assert.rejects(f.oauth.token(), { code: 'siwc_plan_permission_missing' })
  await assert.rejects(f.open().token(), { code: 'siwc_plan_permission_missing' })
  assert.equal(f.record().pendingIdentity, undefined)
  assert.deepEqual(notices, [scope.split(' ')])
  assert.equal(f.calls.filter(({ url }) => url === TOKEN).length, 1)
})

test('temporary JWKS failure persists rotation without returning an unverified access token', async (t) => {
  for (const action of ['retry', 'sign out', 'reject']) await t.test(action, async () => {
    let unavailable = true, lost = 0
    const f = fixture({
      initial: expired(),
      onGrantLost: () => lost++,
      exchange: () => rotation({ id_token: tokens('old-nonce', { forged: action === 'reject' }).id_token }),
      keys: () => unavailable ? new Response(null, { status: 503 }) : Response.json({ keys: [jwk] }),
    })
    await assert.rejects(f.oauth.token(), { code: 'siwc_unavailable' })
    assert.equal(f.record().pendingIdentity, true)
    assert.equal(f.record().refreshToken, 'rotated-refresh')
    const restarted = f.open()
    if (action === 'sign out') {
      await restarted.signOut()
      assert.equal(f.calls.at(-1).form.token, 'rotated-refresh')
      assert.deepEqual(f.record(), META)
    } else {
      unavailable = false
      if (action === 'retry') {
        assert.equal(await restarted.token(), 'rotated-access')
        assert.equal(f.record().pendingIdentity, undefined)
      } else {
        await assert.rejects(restarted.token(), { code: 'siwc_invalid_identity' })
        assert.deepEqual(f.record(), META)
      }
    }
    assert.equal(f.calls.filter(({ url }) => url === TOKEN).length, 1)
    assert.equal(lost, action === 'reject' ? 1 : 0)
  })
})

test('sign-out hides account immediately, revokes the rotated token, and persists no credentials', async () => {
  const started = Promise.withResolvers(), ready = Promise.withResolvers()
  const f = fixture({ initial: expired(), exchange: async () => {
    started.resolve()
    await ready.promise
    return rotation()
  } })
  const inFlight = assert.rejects(f.oauth.token(), { code: 'siwc_sign_in_required' })
  await started.promise
  const out = f.oauth.signOut()
  assert.deepEqual(await f.oauth.status(), RECONNECT)
  await assert.rejects(f.oauth.token(), { code: 'siwc_sign_in_required' })
  ready.resolve()
  await Promise.all([out, inFlight])
  assert.deepEqual(f.calls.at(-1), {
    url: REVOKE, form: { token: 'rotated-refresh', token_type_hint: 'refresh_token', client_id: CLIENT },
  })
  assert.deepEqual(f.saves, [META])
  assert.deepEqual(await f.open().status(), RECONNECT)
  await assert.rejects(signInAs(f.open(), (auth) => {
    assert.equal(auth.searchParams.get('client_id'), CLIENT)
    assert.equal(auth.searchParams.get('ext_agent_host_id'), HOST)
    assert.equal(auth.searchParams.has('id_token_hint'), false)
  }, { code: null, error: 'access_denied' }), { code: 'siwc_access_denied' })
})

test('sign-out aborts reauthorization and does not allow its delayed token response to save', async () => {
  const started = Promise.withResolvers(), ready = Promise.withResolvers()
  const f = fixture({ initial: expired(), exchange: async () => {
    started.resolve()
    return ready.promise
  } })
  let nonce
  const attempt = assert.rejects(signInAs(f.oauth, (auth) => { nonce = auth.searchParams.get('nonce') }, {}), { code: 'siwc_cancelled' })
  await started.promise
  await f.oauth.signOut()
  ready.resolve(Response.json(tokens(nonce)))
  await attempt
  assert.deepEqual(f.saves, [META])
  assert.equal(f.calls.at(-1).form.token, 'old-refresh')
  assert.deepEqual(await f.oauth.status(), RECONNECT)
})

test('sign-out waits for an already-started sign-in save and removes the committed tokens', async () => {
  const saving = Promise.withResolvers(), ready = Promise.withResolvers()
  let nonce
  const f = fixture({
    exchange: () => Response.json(tokens(nonce)),
    save: async (value) => {
      if (!value.accessToken) return
      saving.resolve()
      await ready.promise
    },
  })
  const attempt = assert.rejects(signInAs(f.oauth, (auth) => { nonce = auth.searchParams.get('nonce') }), { code: 'siwc_cancelled' })
  await saving.promise
  const out = f.oauth.signOut()
  assert.deepEqual(await f.oauth.status(), OUT)
  ready.resolve()
  await Promise.all([out, attempt])
  assert.equal(f.calls.at(-1).form.token, 'mock-refresh')
  assert.deepEqual(f.record(), META)
  assert.deepEqual(await f.open().status(), RECONNECT)
})

test('terminal refresh clears credentials; transient refresh and its secret text do not', async () => {
  let calls = 0, lost = 0
  const f = fixture({ initial: expired(), onGrantLost: () => lost++, exchange: () => {
    if (++calls === 1) throw new Error('mock-private-error: old-refresh')
    return Response.json({ error: 'refresh_token_reused', error_description: 'mock-private-error' }, { status: 400 })
  } })
  await assert.rejects(f.oauth.token(), (cause) => {
    assert.equal(cause.code, 'siwc_network')
    assert.doesNotMatch(cause.message, /old-refresh|mock-private-error/)
    return true
  })
  assert.deepEqual(await f.oauth.status(), IN)
  assert.equal(f.record().refreshToken, 'old-refresh')
  assert.equal(lost, 0)
  await assert.rejects(f.oauth.token(), { code: 'siwc_session_expired' })
  await assert.rejects(f.oauth.token(), { code: 'siwc_sign_in_required' })
  assert.equal(lost, 1)
  assert.equal(calls, 2)
  assert.deepEqual(f.record(), META)
  await assert.rejects(signInAs(f.open(), (auth) => {
    assert.equal(auth.searchParams.get('client_id'), CLIENT)
  }, { code: null, error: 'access_denied' }), { code: 'siwc_access_denied' })
})

test('terminal refresh with failed local cleanup publishes pending sign-out until explicit retry', async () => {
  let blocked = true
  const savingMetadata = Promise.withResolvers(), releaseSave = Promise.withResolvers()
  const notices = []
  const f = fixture({
    initial: expired(),
    exchange: () => Response.json({ error: 'invalid_grant' }, { status: 400 }),
    save: async () => {
      if (!blocked) return
      savingMetadata.resolve()
      await releaseSave.promise
      throw new Error('mock metadata failure')
    },
    onClear: () => { if (blocked) throw new Error('mock clear failure') },
    onGrantLost: () => notices.push(f.oauth.status()),
  })
  const refresh = assert.rejects(f.oauth.token(), { code: 'siwc_sign_out_incomplete' })
  await savingMetadata.promise
  const switchAccount = () => f.oauth.signIn({ newAccount: true, notify: () => assert.fail('must not notify') })
  const queuedSwitch = assert.rejects(switchAccount(), { code: 'siwc_sign_out_incomplete' })
  releaseSave.resolve()
  await Promise.all([refresh, queuedSwitch])
  const pending = { ...RECONNECT, signOutPending: true }
  assert.deepEqual(await Promise.all(notices), [pending])
  assert.deepEqual(await f.oauth.status(), pending)
  assert.equal(f.record().refreshToken, 'old-refresh')
  await assert.rejects(f.oauth.token(), { code: 'siwc_sign_out_incomplete' })
  await assert.rejects(switchAccount(), { code: 'siwc_sign_out_incomplete' })
  blocked = false
  await f.oauth.signOut()
  assert.deepEqual(f.record(), META)
  assert.deepEqual(await f.oauth.status(), RECONNECT)
  assert.deepEqual(f.calls.map(({ url }) => url), [TOKEN])
})

test('failed metadata save falls back to clear and preserves the revocation outcome', async (t) => {
  for (const status of [200, 400]) await t.test(String(status), async () => {
    const f = fixture({
      initial: expired(),
      revoke: () => new Response(null, { status }),
      save: () => { throw new Error('mock metadata failure') },
    })
    if (status === 200) await f.oauth.signOut()
    else await assert.rejects(f.oauth.signOut(), { code: 'siwc_revocation_unconfirmed' })
    assert.equal(f.record(), null)
    assert.deepEqual(await f.oauth.status(), RECONNECT)
    assert.deepEqual(await f.open().status(), OUT)
  })
})

test('failed local sign-out is visible and a retry can revoke without re-enabling inference', async () => {
  let fail = true
  const f = fixture({
    initial: expired(),
    revoke: () => new Response(null, { status: fail ? 400 : 200 }),
    save: () => { if (fail) throw new Error('mock metadata failure') },
    onClear: () => { if (fail) throw new Error('mock clear failure') },
  })
  await assert.rejects(f.oauth.signOut(), { code: 'siwc_sign_out_incomplete' })
  assert.deepEqual(await f.oauth.status(), { ...RECONNECT, signOutPending: true })
  assert.equal(f.record().refreshToken, 'old-refresh')
  await assert.rejects(f.oauth.token(), { code: 'siwc_sign_out_incomplete' })
  await assert.rejects(f.oauth.signIn({ notify: () => assert.fail('must not notify') }), { code: 'siwc_sign_out_incomplete' })
  fail = false
  await f.oauth.signOut()
  assert.deepEqual(f.calls.filter(({ url }) => url === REVOKE).map(({ form }) => form.token), ['old-refresh', 'old-refresh'])
  assert.deepEqual(f.record(), META)
  assert.deepEqual(await f.oauth.status(), RECONNECT)
  await assert.rejects(f.oauth.token(), { code: 'siwc_sign_in_required' })
})

test('only explicit sign-out clears an unreadable vault and warns that revocation is unknown', async () => {
  const initial = expired()
  const f = fixture({ initial, onLoad: () => { throw new Error('mock vault unreadable') } })
  await assert.rejects(f.oauth.status(), { code: 'siwc_store_failed' })
  assert.deepEqual(f.record(), initial)
  await assert.rejects(f.oauth.signOut(), { code: 'siwc_revocation_unconfirmed' })
  assert.equal(f.record(), null)
  assert.deepEqual(f.calls, [])
  assert.deepEqual(await f.oauth.status(), OUT)
})

test('failed clearing of an unreadable vault can be retried once it is readable', async () => {
  let blocked = true
  const checkVault = () => { if (blocked) throw new Error('mock vault blocked') }
  const f = fixture({ initial: expired(), onLoad: checkVault, onClear: checkVault })
  await assert.rejects(f.oauth.signOut(), { code: 'siwc_sign_out_incomplete' })
  assert.deepEqual(await f.oauth.status(), { ...OUT, signOutPending: true })
  await assert.rejects(f.oauth.token(), { code: 'siwc_sign_out_incomplete' })
  blocked = false
  await f.oauth.signOut()
  assert.equal(f.calls.at(-1).form.token, 'old-refresh')
  assert.deepEqual(f.record(), META)
})

test('unconfirmed revocation still clears tokens and refuses an untrusted discovered endpoint', async () => {
  const f = fixture({ initial: expired(), discovery: { issuer: ISSUER, revocation_endpoint: 'https://mock.invalid/revoke' } })
  await assert.rejects(f.oauth.signOut(), { code: 'siwc_revocation_unconfirmed' })
  assert.deepEqual(f.calls, [{ url: DISCOVERY, form: undefined }])
  assert.deepEqual(await f.oauth.status(), RECONNECT)
  assert.deepEqual(f.record(), META)
})
