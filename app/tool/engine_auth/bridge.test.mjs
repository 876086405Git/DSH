// SPDX-License-Identifier: MIT
//
// Unit tests for the engine-side auth bridge (app/assets/engine/auth/), against
// a fake DSH context: an authorization seam that runs scripted flows shaped like
// pi-ai's logins as llm-pi-ai relays them, a credential store and a settings
// service.
//
//   node --test app/tool/engine_auth/bridge.test.mjs      (Node 22+)
//
// The plugin shell test (index.mjs) also needs a DSH install; it is skipped
// when DSH_INSTALL (default: ~/.dsh-runtime's global npm install) is missing.

import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { AuthBridge, BridgeError, COPY, ERRORS, accountOf, describeFailure, redact } from '../../assets/engine/auth/bridge.mjs'

// ── fakes ──────────────────────────────────────────────────────────────────

class FakeCredentials {
  records = new Map()
  async readRecord(key) {
    return this.records.get(key)
  }
  async deleteRecord(key) {
    this.records.delete(key)
  }
}

/** `settings` over one namespace: a base layer plus the user layer mutate() edits. */
class FakeSettings {
  constructor(ns = 'llm-pi-ai', base = {}) {
    this.ns = ns
    this.base = base
    this.user = {}
    this.mutations = []
  }
  describe() {
    const value = { providers: { ...this.base, ...(this.user.providers ?? {}) } }
    return [{ ns: this.ns, value, user: structuredClone(this.user), base: { providers: { ...this.base } }, revision: this.mutations.length }]
  }
  async mutate(ns, ops) {
    assert.equal(ns, this.ns)
    this.mutations.push(structuredClone(ops))
    for (const op of ops) {
      const [head, key] = op.path
      assert.equal(head, 'providers')
      this.user.providers ??= {}
      if (op.op === 'set') this.user.providers[key] = structuredClone(op.value)
      else delete this.user.providers[key]
    }
  }
}

/**
 * The parts of `ctx.authorization` the bridge uses, with the seam's semantics:
 * one flow per key, `begin` resolves `authorized` after the flow committed and
 * `cancelled` when the request signal withdraws it.
 */
class FakeAuthorization {
  constructor(credentials) {
    this.credentials = credentials
    this.flows = new Map()
    this.requests = []
  }
  register(key, run) {
    this.flows.set(key, run)
  }
  describe(key) {
    return this.flows.has(key) ? { key, label: key, methods: [{ id: 'oauth', label: 'OAuth' }], inFlight: false } : undefined
  }
  async begin({ key, method, signal, interaction }) {
    const run = this.flows.get(key)
    if (run === undefined) throw Object.assign(new Error(`no authorization flow is registered for "${key}"`), { code: 'NO_FLOW' })
    this.requests.push({ key, method })
    if (signal?.aborted) return { status: 'cancelled' }
    let committed = false
    const withdrawn = new Promise((resolve) => signal.addEventListener('abort', () => resolve('withdrawn'), { once: true }))
    const running = run({
      signal,
      notify: (notice) => interaction.notify(notice),
      prompt: (prompt) => interaction.prompt(prompt),
      commit: async (record) => {
        signal.throwIfAborted()
        this.credentials.records.set(key, record)
        committed = true
      },
    })
    try {
      if ((await Promise.race([running.then(() => 'ran'), withdrawn])) === 'withdrawn') {
        running.catch(() => {})
        return { status: 'cancelled' }
      }
    } catch (error) {
      if (signal.aborted) return { status: 'cancelled' }
      throw error
    }
    if (!committed) throw Object.assign(new Error('resolved without committing'), { code: 'NOT_COMMITTED' })
    return { status: 'authorized' }
  }
}

const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')
const fakeCodexToken = (claims) => `${b64({ alg: 'none' })}.${b64(claims)}.sig`
const CODEX_TOKEN = fakeCodexToken({
  'https://api.openai.com/profile': { email: 'tester@example.invalid' },
  'https://api.openai.com/auth': { chatgpt_plan_type: 'plus', chatgpt_account_id: 'acct' },
})

/**
 * A pi-ai browser login as llm-pi-ai relays it: pick a method (select), show
 * the authorize page (notice with url), then race the loopback callback
 * against a pasted code / redirect URL (text prompt with its own signal).
 * [callback] resolves with a code, rejects like pi-ai's callback server, or
 * stays pending; null means the server could not start (paste only).
 */
function browserLogin({ provider, state = 'state-1', callback, progress = false }) {
  const calls = { methods: [], pastes: [] }
  const run = async ({ signal, notify, prompt, commit }) => {
    const method = await prompt({
      kind: 'select',
      message: 'Select login method:',
      options: [
        { id: 'browser', label: 'Browser login (default)' },
        { id: provider === 'anthropic' ? 'copy_code' : 'device_code', label: 'Headless' },
      ],
    })
    calls.methods.push(method)
    if (method !== 'browser') throw new Error(`unexpected method ${method}`)
    const host = provider === 'anthropic' ? 'https://claude.ai/oauth/authorize' : 'https://auth.openai.com/oauth/authorize'
    const redirect = provider === 'anthropic' ? 'http://localhost:53692/callback' : 'http://localhost:1455/auth/callback'
    notify({ message: 'A browser window should open. Complete login to finish.', url: `${host}?state=${state}` })
    const manualAbort = new AbortController()
    let manualError
    const manual = prompt({ kind: 'text', message: 'Complete login in your browser, or paste…', placeholder: redirect, signal: manualAbort.signal }).then(
      (input) => ({ input }),
      (error) => {
        manualError = error
        return undefined
      },
    )
    let code
    try {
      const fromCallback = callback === null ? undefined : await Promise.race([callback, manual.then(() => undefined)])
      if (fromCallback !== undefined) code = fromCallback
      else {
        const pasted = await manual
        if (manualError) throw manualError
        calls.pastes.push(pasted.input)
        const url = new URL(pasted.input)
        if (url.searchParams.get('state') !== state) throw new Error('State mismatch')
        code = url.searchParams.get('code')
      }
    } finally {
      manualAbort.abort()
    }
    if (!code) throw new Error('Missing authorization code')
    if (progress) notify({ message: 'Exchanging authorization code for tokens...' })
    signal.throwIfAborted()
    await commit({ kind: 'grant', payload: { type: 'oauth', access: provider === 'anthropic' ? 'sk-ant-oat-fake' : CODEX_TOKEN, refresh: 'r', expires: Date.now() + 3600e3 } })
  }
  return { run, calls }
}

function deferred() {
  let resolve, reject
  const promise = new Promise((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

function setup({ ttlMs, portFree = true, settingsBase, withSettings = true, siwc } = {}) {
  const credentials = new FakeCredentials()
  const authorization = new FakeAuthorization(credentials)
  const settings = withSettings ? new FakeSettings('llm-pi-ai', settingsBase) : undefined
  const logs = []
  const services = { credentials, authorization, settings }
  const bridge = new AuthBridge({
    get: (name) => services[name],
    log: (line) => logs.push(line),
    siwc,
    probePort: async () => portFree,
    ...(ttlMs === undefined ? {} : { ttlMs }),
  })
  return { bridge, credentials, authorization, settings, logs }
}

/** Polls until [predicate] holds for the step (the flow runs on the event loop). */
async function waitFor(bridge, attemptId, predicate, label = 'step') {
  for (let i = 0; i < 200; i++) {
    const step = bridge.poll(attemptId)
    if (predicate(step)) return step
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error(`timed out waiting for ${label}; last ${JSON.stringify(bridge.poll(attemptId))}`)
}

const phase = (name) => (step) => step.phase === name

// ── tests ──────────────────────────────────────────────────────────────────

test('open → done: browser callback, then the route is declared and list shows the account', async () => {
  const { bridge, credentials, authorization, settings } = setup()
  const callback = deferred()
  const login = browserLogin({ provider: 'openai-codex', callback: callback.promise })
  authorization.register('llm-pi-ai/openai-codex', login.run)

  const { attemptId } = await bridge.begin('openai-codex')
  assert.match(attemptId, /^[0-9a-f-]{36}$/)
  const open = await waitFor(bridge, attemptId, phase('open'))
  assert.deepEqual(open, {
    phase: 'open',
    url: 'https://auth.openai.com/oauth/authorize?state=state-1',
    placeholder: 'http://localhost:1455/auth/callback',
    message: COPY.open,
  })
  assert.deepEqual(login.calls.methods, ['browser'], 'the bridge picks browser login')
  assert.deepEqual(authorization.requests, [{ key: 'llm-pi-ai/openai-codex', method: 'oauth' }])
  assert.equal(settings.mutations.length, 0, 'no route before sign-in')

  callback.resolve('code-from-browser')
  const done = await waitFor(bridge, attemptId, phase('done'))
  assert.deepEqual(done, { phase: 'done' })
  assert.equal(credentials.records.get('llm-pi-ai/openai-codex')?.kind, 'grant')
  assert.deepEqual(settings.user, { providers: { 'openai-codex': { displayName: 'ChatGPT' } } })

  assert.deepEqual(await bridge.list(), {
    providers: [
      { id: 'openai-codex', signedIn: true, account: 'tester@example.invalid' },
      { id: 'anthropic', signedIn: false },
    ],
  })
  assert.equal(settings.mutations.length, 1, 'list does not re-declare an existing route')
})

test('the callback withdrawing the paste prompt shows "finishing" until the grant lands', async () => {
  const { bridge, authorization } = setup()
  const callback = deferred()
  const gate = deferred()
  const login = browserLogin({ provider: 'anthropic', callback: callback.promise, progress: true })
  authorization.register('llm-pi-ai/anthropic', async (session) => {
    // Hold the commit so the in-between step is observable.
    await login.run({ ...session, commit: async (record) => (await gate.promise, session.commit(record)) })
  })
  const { attemptId } = await bridge.begin('anthropic')
  await waitFor(bridge, attemptId, phase('open'))
  callback.resolve('code')
  const finishing = await waitFor(bridge, attemptId, phase('starting'))
  assert.deepEqual(finishing, { phase: 'starting', message: COPY.finishing })
  gate.resolve()
  await waitFor(bridge, attemptId, phase('done'))
})

test('prompt → answer → done: callback port taken, the redirect URL is pasted', async () => {
  const { bridge, authorization, credentials, settings } = setup({ portFree: false })
  const login = browserLogin({ provider: 'openai-codex', callback: null })
  authorization.register('llm-pi-ai/openai-codex', login.run)

  const { attemptId } = await bridge.begin('openai-codex')
  const prompt = await waitFor(bridge, attemptId, phase('prompt'))
  assert.deepEqual(prompt, {
    phase: 'prompt',
    url: 'https://auth.openai.com/oauth/authorize?state=state-1',
    placeholder: 'http://localhost:1455/auth/callback',
    message: COPY.prompt,
  })
  assert.deepEqual(bridge.answer(attemptId, '  http://localhost:1455/auth/callback?code=c1&state=state-1  '), {})
  assert.deepEqual(bridge.poll(attemptId), { phase: 'starting', message: COPY.finishing })
  await waitFor(bridge, attemptId, phase('done'))
  assert.deepEqual(login.calls.pastes, ['http://localhost:1455/auth/callback?code=c1&state=state-1'])
  assert.equal(credentials.records.get('llm-pi-ai/openai-codex')?.kind, 'grant')
  assert.ok(settings.user.providers['openai-codex'])
})

test('a paste is accepted while the browser callback is still pending (open phase)', async () => {
  const { bridge, authorization } = setup()
  const login = browserLogin({ provider: 'anthropic', state: 'verifier', callback: new Promise(() => {}) })
  authorization.register('llm-pi-ai/anthropic', login.run)
  const { attemptId } = await bridge.begin('anthropic')
  await waitFor(bridge, attemptId, phase('open'))
  bridge.answer(attemptId, 'http://localhost:53692/callback?code=c&state=verifier')
  await waitFor(bridge, attemptId, phase('done'))
})

test('a wrong paste fails with product copy, not the library message', async () => {
  const { bridge, authorization, logs, settings } = setup({ portFree: false })
  authorization.register('llm-pi-ai/openai-codex', browserLogin({ provider: 'openai-codex', callback: null }).run)
  const { attemptId } = await bridge.begin('openai-codex')
  await waitFor(bridge, attemptId, phase('prompt'))
  bridge.answer(attemptId, 'http://localhost:1455/auth/callback?code=c1&state=other')
  const failed = await waitFor(bridge, attemptId, phase('failed'))
  assert.deepEqual(failed, { phase: 'failed', error: ERRORS.badPaste })
  assert.ok(logs.some((line) => line.includes('State mismatch')), 'details go to the log')
  assert.equal(settings.mutations.length, 0)
})

test('answer: refused without a pending prompt, for an empty value and for an unknown attempt', async () => {
  const { bridge, authorization } = setup()
  const gate = deferred()
  authorization.register('llm-pi-ai/openai-codex', async () => {
    await gate.promise
  })
  const { attemptId } = await bridge.begin('openai-codex')
  assert.throws(() => bridge.answer(attemptId, 'x'), (e) => e instanceof BridgeError && e.code === 'app-auth/not-waiting' && e.isDSHRemoteError)
  assert.throws(() => bridge.answer('nope', 'x'), (e) => e.code === 'app-auth/attempt-over')
  bridge.cancel(attemptId)

  const second = setup({ portFree: false })
  second.authorization.register('llm-pi-ai/openai-codex', browserLogin({ provider: 'openai-codex', callback: null }).run)
  const { attemptId: id2 } = await second.bridge.begin('openai-codex')
  await waitFor(second.bridge, id2, phase('prompt'))
  assert.throws(() => second.bridge.answer(id2, '   '), (e) => e.code === 'app-auth/empty-answer')
  assert.throws(() => second.bridge.answer(id2, 42), (e) => e.code === 'app-auth/empty-answer')
  second.bridge.cancel(id2)
})

test('cancel: the flow is withdrawn, its prompt rejected, and the step reads cancelled', async () => {
  const { bridge, authorization, credentials, settings } = setup()
  let flowSignal
  let promptError
  authorization.register('llm-pi-ai/openai-codex', async ({ signal, notify, prompt }) => {
    flowSignal = signal
    await prompt({ kind: 'select', message: 'm', options: [{ id: 'browser', label: 'b' }] })
    notify({ message: 'open', url: 'https://auth.openai.com/oauth/authorize?state=s' })
    await prompt({ kind: 'text', message: 'paste', placeholder: 'p' }).catch((error) => {
      promptError = error
      throw error
    })
  })
  const { attemptId } = await bridge.begin('openai-codex')
  await waitFor(bridge, attemptId, phase('open'))
  assert.deepEqual(bridge.cancel(attemptId), {})
  const cancelled = await waitFor(bridge, attemptId, phase('cancelled'))
  assert.deepEqual(cancelled, { phase: 'cancelled', error: ERRORS.cancelled })
  assert.equal(flowSignal.aborted, true)
  await new Promise((resolve) => setImmediate(resolve))
  assert.ok(promptError instanceof Error)
  assert.equal(credentials.records.size, 0)
  assert.equal(settings.mutations.length, 0)
  assert.deepEqual(bridge.cancel(attemptId), {}, 'cancel after the end is a no-op')
  assert.deepEqual(bridge.cancel('unknown'), {})
})

test('begin again replaces the attempt in flight', async () => {
  const { bridge, authorization } = setup()
  authorization.register('llm-pi-ai/anthropic', browserLogin({ provider: 'anthropic', callback: new Promise(() => {}) }).run)
  const first = (await bridge.begin('anthropic')).attemptId
  await waitFor(bridge, first, phase('open'))
  const second = (await bridge.begin('anthropic')).attemptId
  assert.notEqual(first, second)
  assert.deepEqual(bridge.poll(first), { phase: 'cancelled', error: ERRORS.cancelled })
  await waitFor(bridge, second, phase('open'))
  bridge.cancel(second)
})

test('an attempt that runs past its lifetime fails as timed out', async () => {
  const { bridge, authorization } = setup({ ttlMs: 40 })
  authorization.register('llm-pi-ai/anthropic', browserLogin({ provider: 'anthropic', callback: new Promise(() => {}) }).run)
  const { attemptId } = await bridge.begin('anthropic')
  const failed = await waitFor(bridge, attemptId, phase('failed'))
  assert.deepEqual(failed, { phase: 'failed', error: ERRORS.timeout })
})

test('failure texts: denied, network, unavailable, generic', async () => {
  const cases = [
    [new Error('OpenAI authorization failed: access_denied'), ERRORS.denied],
    [Object.assign(new TypeError('fetch failed'), { cause: Object.assign(new Error('read ECONNRESET'), { code: 'ECONNRESET' }) }), ERRORS.network],
    [new Error('OpenAI Codex token exchange failed (400): {"error":"invalid_grant"}'), ERRORS.generic],
  ]
  for (const [error, text] of cases) {
    const { bridge, authorization } = setup()
    authorization.register('llm-pi-ai/openai-codex', async ({ prompt }) => {
      await prompt({ kind: 'select', message: 'm', options: [{ id: 'browser', label: 'b' }] })
      throw error
    })
    const { attemptId } = await bridge.begin('openai-codex')
    assert.deepEqual(await waitFor(bridge, attemptId, phase('failed')), { phase: 'failed', error: text }, error.message)
  }
  // No llm-pi-ai flow (adapter not mounted): the attempt fails, begin itself does not throw.
  const { bridge } = setup()
  const { attemptId } = await bridge.begin('anthropic')
  assert.deepEqual(await waitFor(bridge, attemptId, phase('failed')), { phase: 'failed', error: ERRORS.unavailable })
})

test('describeFailure and redact', () => {
  assert.equal(describeFailure(Object.assign(new Error('x'), { code: 'ALREADY_IN_FLIGHT' })), ERRORS.busy)
  assert.equal(describeFailure(new Error('Missing authorization code')), ERRORS.badPaste)
  assert.equal(describeFailure(Object.assign(new Error('x'), { name: 'TimeoutError' })), ERRORS.network)
  const jwt = fakeCodexToken({ a: 1 })
  assert.equal(redact(`token ${jwt}`).includes(jwt), false)
  assert.equal(redact(`x sk-ant-oat01-${'a'.repeat(40)}`).includes('a'.repeat(40)), false)
  assert.equal(redact('/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js'), '/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js')
})

test('device code notices map to the device phase', async () => {
  const { bridge, authorization } = setup()
  authorization.register('llm-pi-ai/openai-codex', async ({ notify }) => {
    notify({ message: 'Enter this code…', url: 'https://auth.openai.com/codex/device', code: 'ABCD-1234' })
    await new Promise(() => {})
  })
  const { attemptId } = await bridge.begin('openai-codex')
  const device = await waitFor(bridge, attemptId, phase('device'))
  assert.deepEqual(device, { phase: 'device', url: 'https://auth.openai.com/codex/device', userCode: 'ABCD-1234', message: COPY.device })
  bridge.cancel(attemptId)
})

test('signOut removes the bridge route and the grant, keeps a user API-key route and api-key records', async () => {
  const { bridge, credentials, settings } = setup()
  credentials.records.set('llm-pi-ai/openai-codex', { kind: 'grant', payload: { type: 'oauth', access: CODEX_TOKEN } })
  settings.user = { providers: { 'openai-codex': { displayName: 'ChatGPT' }, anthropic: { displayName: 'Anthropic', apiKeyEnv: 'ANTHROPIC_API_KEY' } } }
  credentials.records.set('llm-pi-ai/anthropic', { kind: 'api-key', key: 'sk-user-key' })

  assert.deepEqual(await bridge.signOut('openai-codex'), {})
  assert.equal(credentials.records.has('llm-pi-ai/openai-codex'), false)
  assert.equal(settings.user.providers['openai-codex'], undefined)

  assert.deepEqual(await bridge.signOut('anthropic'), {})
  assert.deepEqual(settings.user.providers.anthropic, { displayName: 'Anthropic', apiKeyEnv: 'ANTHROPIC_API_KEY' }, 'API-key route kept')
  assert.equal(credentials.records.get('llm-pi-ai/anthropic')?.kind, 'api-key', 'api-key record kept')

  assert.deepEqual(await bridge.list(), {
    providers: [
      { id: 'openai-codex', signedIn: false },
      { id: 'anthropic', signedIn: false },
    ],
  })
})

test('signOut leaves a route declared by a lower layer, cancels a live attempt, and reports failures as copy', async () => {
  const { bridge, credentials, settings, authorization } = setup({ settingsBase: { anthropic: { displayName: 'Claude (base)' } } })
  authorization.register('llm-pi-ai/anthropic', browserLogin({ provider: 'anthropic', callback: new Promise(() => {}) }).run)
  credentials.records.set('llm-pi-ai/anthropic', { kind: 'grant', payload: { type: 'oauth', access: 'opaque' } })
  const { attemptId } = await bridge.begin('anthropic')
  await waitFor(bridge, attemptId, phase('open'))
  await bridge.signOut('anthropic')
  assert.equal(bridge.poll(attemptId).phase, 'cancelled')
  assert.equal(settings.mutations.length, 0, 'inherited route left alone')
  assert.equal(credentials.records.has('llm-pi-ai/anthropic'), false)

  const broken = setup({ withSettings: false })
  await assert.rejects(broken.bridge.signOut('openai-codex'), (e) => e.code === 'app-auth/sign-out-failed' && e.message === ERRORS.signOut)
})

test('list repairs a missing route for a stored grant and never declares one without it', async () => {
  const { bridge, credentials, settings } = setup()
  assert.deepEqual((await bridge.list()).providers.map((p) => p.signedIn), [false, false])
  assert.equal(settings.mutations.length, 0)
  credentials.records.set('llm-pi-ai/anthropic', { kind: 'grant', payload: { type: 'oauth', access: 'opaque' } })
  const { providers } = await bridge.list()
  assert.deepEqual(providers[1], { id: 'anthropic', signedIn: true })
  assert.deepEqual(settings.user, { providers: { anthropic: { displayName: 'Claude' } } })
  // A user's own route for the provider is never replaced.
  settings.user.providers.anthropic = { displayName: 'Mine', apiKeyEnv: 'K' }
  await bridge.list()
  assert.deepEqual(settings.user.providers.anthropic, { displayName: 'Mine', apiKeyEnv: 'K' })
})

test('a list repair racing a sign-out never leaves a route without a grant', async () => {
  for (const order of ['list-first', 'signOut-first']) {
    const { bridge, credentials, settings } = setup()
    credentials.records.set('llm-pi-ai/openai-codex', { kind: 'grant', payload: { type: 'oauth', access: CODEX_TOKEN } })
    const calls = order === 'list-first' ? [bridge.list(), bridge.signOut('openai-codex')] : [bridge.signOut('openai-codex'), bridge.list()]
    await Promise.all(calls)
    assert.equal(credentials.records.has('llm-pi-ai/openai-codex'), false, order)
    assert.equal(settings.describe()[0].value.providers['openai-codex'], undefined, order)
  }
})

test('unknown provider and unknown attempt', async () => {
  const { bridge } = setup()
  await assert.rejects(bridge.begin('openai'), (e) => e.code === 'app-auth/unknown-provider')
  await assert.rejects(bridge.begin(undefined), (e) => e.code === 'app-auth/unknown-provider')
  await assert.rejects(bridge.signOut('__proto__'), (e) => e.code === 'app-auth/unknown-provider')
  assert.deepEqual(bridge.poll('missing'), { phase: 'failed', error: ERRORS.expired })
})

test('official OpenAI is published only with its own adapter and preserves the old routes', async () => {
  const callback = deferred()
  const revocation = deferred()
  let status = { signedIn: false }
  let invalidations = 0
  let capability
  const { bridge, credentials, settings, logs } = setup({ siwc: () => capability })
  const old = await bridge.list()
  await assert.rejects(bridge.begin('openai-siwc'), { code: 'app-auth/unknown-provider' })

  capability = {
    invalidate: () => invalidations++,
    oauth: {
      status: async () => status,
      signIn: async ({ notify }) => {
        notify('https://auth.openai.com/authorize?state=private-test-state')
        await callback.promise
        status = { signedIn: true, planEnabled: false, account: { email: 'openai@example.invalid', subject: 'private-subject' } }
      },
      signOut: async () => {
        status = { signedIn: false }
        await revocation.promise
        throw Object.assign(new Error('private-upstream-error'), { code: 'siwc_revocation_unconfirmed' })
      },
    },
  }
  assert.deepEqual((await bridge.list()).providers, [...old.providers, { id: 'openai-siwc', signedIn: false, planEnabled: false }])
  const { attemptId } = await bridge.begin('openai-siwc')
  assert.equal(new URL((await waitFor(bridge, attemptId, phase('open'))).url).origin, 'https://auth.openai.com')
  callback.resolve()
  await waitFor(bridge, attemptId, phase('done'))
  assert.deepEqual((await bridge.list()).providers.at(-1), {
    id: 'openai-siwc', signedIn: true, planEnabled: false, account: 'openai@example.invalid',
  })
  assert.deepEqual(await bridge.usage('openai-siwc'), { provider: 'openai-siwc', status: 'unsupported', windows: [] })
  assert.equal(credentials.records.size, 0)
  assert.equal(settings.describe()[0].value.providers?.['openai-siwc'], undefined)

  const signedOut = assert.rejects(bridge.signOut('openai-siwc'), { code: 'app-auth/revocation-unconfirmed' })
  assert.equal(invalidations, 2)
  assert.equal((await bridge.list()).providers.at(-1).signedIn, false)
  revocation.resolve()
  await signedOut
  assert.doesNotMatch(logs.join(' '), /private-test-state|private-subject|private-upstream-error/)
})

test('an unreadable OpenAI vault exposes the existing explicit sign-out recovery', async () => {
  const { bridge } = setup({ siwc: () => ({
    oauth: { status: async () => { throw Object.assign(new Error('private vault detail'), { code: 'siwc_store_failed' }) } },
  }) })
  assert.deepEqual((await bridge.list()).providers.at(-1), {
    id: 'openai-siwc', signedIn: false, planEnabled: false, signOutPending: true,
  })
})

test('only an explicit OpenAI login requests new account registration', async () => {
  const attempts = []
  const { bridge } = setup({ siwc: () => ({
    invalidate() {},
    oauth: {
      status: async () => ({ signedIn: false, reconnectAvailable: true }),
      signIn: async ({ newAccount }) => { attempts.push(newAccount) },
    },
  }) })
  assert.deepEqual((await bridge.list()).providers.at(-1), {
    id: 'openai-siwc', signedIn: false, planEnabled: false, reconnectAvailable: true,
  })
  for (const options of [[], [true]]) {
    const { attemptId } = await bridge.begin('openai-siwc', ...options)
    await waitFor(bridge, attemptId, phase('done'))
  }
  assert.deepEqual(attempts, [false, true])
  await assert.rejects(bridge.begin('openai-codex', true), { code: 'app-auth/unknown-provider' })
})

test('OpenAI withdraws the browser on owner teardown but reports an acknowledged commit as done', async () => {
  const committed = deferred()
  let saving = false
  const { bridge } = setup({ siwc: () => ({
    invalidate() {},
    oauth: {
      signIn: ({ signal, notify }) => {
        notify('https://auth.openai.com/authorize')
        if (saving) return committed.promise
        return new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }))
      },
    },
  }) })
  const browser = await bridge.begin('openai-siwc')
  await waitFor(bridge, browser.attemptId, phase('open'))
  bridge.withdrawOpenAiAttempt()
  await waitFor(bridge, browser.attemptId, phase('cancelled'))

  saving = true
  const persisted = await bridge.begin('openai-siwc')
  await waitFor(bridge, persisted.attemptId, phase('open'))
  bridge.cancel(persisted.attemptId)
  committed.resolve()
  await waitFor(bridge, persisted.attemptId, phase('done'))
})

test('accountOf: email, then plan, never for an opaque token', () => {
  assert.equal(accountOf('openai-codex', { access: CODEX_TOKEN }), 'tester@example.invalid')
  assert.equal(accountOf('openai-codex', { access: fakeCodexToken({ 'https://api.openai.com/auth': { chatgpt_plan_type: 'pro' } }) }), 'ChatGPT Pro')
  assert.equal(accountOf('openai-codex', { access: 'not-a-jwt' }), undefined)
  assert.equal(accountOf('anthropic', { access: CODEX_TOKEN }), undefined)
})

test('dispose withdraws live attempts', async () => {
  const { bridge, authorization } = setup()
  authorization.register('llm-pi-ai/openai-codex', browserLogin({ provider: 'openai-codex', callback: new Promise(() => {}) }).run)
  const { attemptId } = await bridge.begin('openai-codex')
  await waitFor(bridge, attemptId, phase('open'))
  bridge.dispose()
  await waitFor(bridge, attemptId, phase('cancelled'))
})

// ── the plugin shell against a real DSH install ───────────────────────────

const DSH_INSTALL = process.env.DSH_INSTALL ?? join(homedir(), '.dsh-runtime/npm/lib/node_modules/@deepseek-ai/dsh')

test('index.mjs loads the host protocol package and exposes SRC-compatible Remote methods', { skip: !existsSync(join(DSH_INSTALL, 'lib/bin.js')) && `no DSH install at ${DSH_INSTALL}` }, async () => {
  const argv1 = process.argv[1]
  process.argv[1] = join(DSH_INSTALL, 'lib/bin.js') // what the `dsh` launcher runs
  let AppAuth
  try {
    ;({ default: AppAuth } = await import('../../assets/engine/auth/index.mjs'))
  } finally {
    process.argv[1] = argv1
  }
  assert.deepEqual(AppAuth.inject, ['credentials', 'authorization'])
  // The Gateway's source-mode reading of a method's parameter list (dsh-api-gateway `methodParameterNames`).
  const wireNames = (method) => {
    const source = Function.prototype.toString.call(AppAuth.prototype[method])
    const body = source.slice(source.indexOf('(') + 1, source.indexOf(')')).trim()
    return body === '' ? [] : body.split(',').map((part) => part.trim())
  }
  assert.deepEqual(
    Object.fromEntries(['list', 'usage', 'begin', 'poll', 'answer', 'cancel', 'signOut'].map((m) => [m, wireNames(m)])),
    { list: [], usage: ['provider'], begin: ['provider', 'newAccount'], poll: ['attemptId'], answer: ['attemptId', 'value'], cancel: ['attemptId'], signOut: ['provider'] },
  )
})
