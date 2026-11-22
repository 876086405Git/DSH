// SPDX-License-Identifier: MIT
// Protocol: https://developers.openai.com/siwc/token-sharing-open-source

import { createHash, createPublicKey, randomBytes, timingSafeEqual, verify } from 'node:crypto'
import { createServer } from 'node:http'
import { setTimeout as delay } from 'node:timers/promises'

const ISSUER = 'https://auth.openai.com'
const AUTHORIZE = ISSUER + '/api/accounts/authorize'
const TOKEN = ISSUER + '/api/accounts/oauth/token'
const DISCOVERY = ISSUER + '/.well-known/openid-configuration'
const JWKS = ISSUER + '/.well-known/jwks.json'
const RESOURCE = 'https://api.openai.com/v1'
const DYNAMIC_CLIENT = 'dynamic_agent_client'
const PLAN_SCOPE = 'chatgpt.tokens.use.direct'
const SCOPE = 'openid profile email offline_access resource.invoke ' + PLAN_SCOPE
const LOOPBACK = '127.0.0.1'
const CALLBACK = '/auth/callback'
const RENEW_BEFORE_MS = 60_000
const UNUSABLE_REFRESH = new Set([
  'invalid_grant', 'invalid_refresh_token', 'token_expired', 'refresh_token_expired',
  'refresh_token_invalidated', 'refresh_token_reused',
])

// Do not attach causes or copy upstream messages, URL parameters, or body fields.
const error = (code, message) => Object.assign(new Error(message), { code: 'siwc_' + code })
const cancelled = () => error('cancelled', 'OpenAI authorization request was cancelled.')
const timeout = () => error('timeout', 'OpenAI authorization timed out. Try signing in again.')
const invalidIdentity = () => error('invalid_identity', 'OpenAI identity could not be verified.')
const invalidResponse = () => error('invalid_response', 'OpenAI returned an invalid authorization response.')
const signInRequired = () => error('sign_in_required', 'Sign in with ChatGPT first.')
const sessionExpired = () => error('session_expired', 'The OpenAI session expired. Sign in with ChatGPT again.')
const planMissing = () => error('plan_permission_missing', 'This login does not allow direct use of your ChatGPT plan.')
const storeFailed = () => error('store_failed', 'The OpenAI credential store could not be updated or read.')
const signOutIncomplete = () => error('sign_out_incomplete', 'Local OpenAI credentials could not be removed. Retry signing out.')
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value)
const nonEmpty = (value) => typeof value === 'string' && value.trim().length > 0
const b64url = /^[A-Za-z0-9_-]+$/
const issuedClient = (value) => nonEmpty(value) && /^[A-Za-z0-9._~-]+$/.test(value) && value !== DYNAMIC_CLIENT
const randomValue = () => randomBytes(32).toString('base64url')
const sha256 = (value) => createHash('sha256').update(value).digest()

function sameString(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string' || left.length !== right.length) return false
  const a = Buffer.from(left)
  const b = Buffer.from(right)
  return a.length === b.length && timingSafeEqual(a, b)
}

function checkSignal(signal, failure = cancelled) {
  if (signal?.aborted) throw failure()
}

async function waitFor(promise, signal, failure = cancelled) {
  if (!signal) return promise
  let abort
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      abort = () => reject(failure())
      if (signal.aborted) abort()
      else signal.addEventListener('abort', abort, { once: true })
    })])
  } finally {
    signal.removeEventListener('abort', abort)
  }
}

function reply(res, status, text) {
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    Connection: 'close',
  })
  res.end(text)
}

async function browserCode({ hostId, selected, state, nonce, verifier, notify, signal, reconsent }) {
  const deadline = AbortSignal.timeout(5 * 60_000)
  const attempt = AbortSignal.any([signal, deadline])
  const failure = () => signal.aborted ? cancelled() : timeout()
  const { promise: callback, resolve: received, reject: failed } = Promise.withResolvers()
  // The listener can fail before the browser has been notified.
  callback.catch(() => {})
  let redirect, consumed = false
  const server = createServer((req, res) => {
    if (req.method !== 'GET' || req.socket.remoteAddress !== LOOPBACK || req.headers.host !== redirect?.host ||
        req.url?.split('?', 1)[0] !== CALLBACK || req.url.includes('#')) {
      reply(res, 404, 'Not found.')
      return
    }
    const params = new URL(req.url, redirect).searchParams
    if (attempt.aborted || consumed || params.getAll('state').length !== 1 || !sameString(params.get('state'), state)) {
      // Unrelated requests cannot consume the pending browser attempt.
      reply(res, 400, 'Invalid authorization callback.')
      return
    }
    consumed = true
    const code = params.get('code')
    const providerError = params.get('error')
    const client = params.get('client_id')
    if (params.getAll('error').length > 1 || params.getAll('code').length > 1 || params.getAll('client_id').length > 1 ||
        (params.has('error') && (!providerError || params.has('code')))) {
      reply(res, 400, 'Invalid authorization callback.')
      failed(error('invalid_callback', 'OpenAI returned a malformed authorization callback.'))
    } else if (providerError) {
      reply(res, 400, 'Authorization was not completed. Return to the app.')
      failed(providerError === 'access_denied'
        ? error('access_denied', 'ChatGPT authorization was declined.')
        : error('authorization_rejected', 'OpenAI declined the authorization request.'))
    } else if (!nonEmpty(code) || (selected
      ? params.has('client_id') && client !== selected.clientId
      : !issuedClient(client))) {
      reply(res, 400, 'Invalid authorization callback.')
      failed(error('invalid_callback', 'OpenAI returned a malformed authorization callback.'))
    } else {
      reply(res, 200, 'Authorization response received. Return to the app.')
      received({ code, clientId: selected ? selected.clientId : client, redirectUri: redirect.href })
    }
  })
  server.setTimeout(10_000, (socket) => socket.destroy())
  try {
    checkSignal(attempt, failure)
    await waitFor(new Promise((resolve, reject) => {
      server.on('error', () => {
        const cause = error('callback_unavailable', 'The local OpenAI callback listener failed.')
        reject(cause)
        failed(cause)
      })
      server.listen({ host: LOOPBACK, port: 0, signal: attempt }, () => {
        redirect = new URL('http://' + LOOPBACK + ':' + server.address().port + CALLBACK)
        resolve()
      })
    }), attempt, failure)
    checkSignal(attempt, failure)
    const url = new URL(AUTHORIZE)
    url.search = new URLSearchParams({
      client_id: selected?.clientId ?? DYNAMIC_CLIENT,
      ext_agent_host_id: hostId,
      response_type: 'code',
      redirect_uri: redirect.href,
      scope: SCOPE,
      resource: RESOURCE,
      state,
      nonce,
      code_challenge_method: 'S256',
      code_challenge: sha256(verifier).toString('base64url'),
    }).toString()
    if (!selected) url.searchParams.set('agent_name_hint', 'dsh-Go')
    if (reconsent) url.searchParams.set('prompt', 'consent')
    // Keep tokens out of the browser URL; returning users select their account.
    const notified = (async () => {
      try { await notify(url.href) } catch {
        throw error('notification_failed', 'The OpenAI sign-in URL could not be delivered.')
      }
    })()
    return (await waitFor(Promise.all([callback, notified]), attempt, failure))[0]
  } finally {
    server.close()
  }
}

function decodePart(part) {
  const value = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'))
  if (!isObject(value)) throw invalidIdentity()
  return value
}

function parseTokenSet(body, previous) {
  if (!isObject(body) || !nonEmpty(body.access_token) || !/^[A-Za-z0-9._~+/-]+=*$/.test(body.access_token) ||
      typeof body.token_type !== 'string' || body.token_type.toLowerCase() !== 'bearer' ||
      !Number.isSafeInteger(body.expires_in) || body.expires_in <= 0 ||
      (body.refresh_token !== undefined && !nonEmpty(body.refresh_token)) ||
      (body.id_token !== undefined && !nonEmpty(body.id_token))) throw invalidResponse()
  const scopes = typeof body.scope === 'string'
    ? [...new Set(body.scope.split(' ').filter(Boolean))]
    : body.scope === undefined ? previous?.scopes : undefined
  // This endpoint rotates every successful refresh; the prior token cannot be reused.
  if (!scopes || (previous && (!body.refresh_token || body.refresh_token === previous.refreshToken)) ||
      (scopes.includes('offline_access') && !body.refresh_token) || (!previous && !body.id_token)) throw invalidResponse()
  const expiresAt = Date.now() + body.expires_in * 1000
  if (!Number.isSafeInteger(expiresAt)) throw invalidResponse()
  return { accessToken: body.access_token, refreshToken: body.refresh_token ?? null, scopes, expiresAt }
}

const registrationOf = ({ clientId, subject, email }) => ({ clientId, subject, email })
const hasPlanPermission = (scopes) => scopes.includes(PLAN_SCOPE) && scopes.includes('resource.invoke')
const accountStatus = (grant, registration) => grant
  ? { signedIn: true, planEnabled: hasPlanPermission(grant.scopes), account: { subject: grant.subject, email: grant.email } }
  : { signedIn: false, planEnabled: false, ...(registration && { reconnectAvailable: true }) }

export function createSiwcOAuth({ fetch = globalThis.fetch, store, getHostId, onGrantLost = () => {} }) {
  let grant, registration, loading, pendingSave = false, pendingPlanLoss = false
  let tail = Promise.resolve(), signInController, tokenFlight, signingOut, epoch = 0
  let pendingSignOut, jwks, jwksExpiresAt = 0

  // Refresh, authorization and sign-out share one writer. In-flight refresh is
  // allowed to finish rotation so sign-out can revoke the replacement token.
  function serialize(operation) {
    const result = tail.then(operation)
    tail = result.then(() => {}, () => {})
    return result
  }

  async function storage(fn) {
    try { return await fn() } catch { throw storeFailed() }
  }

  async function load() {
    if (grant === undefined) {
      loading ??= storage(() => store.load()).then((stored) => {
        if (stored === null) {
          grant = null
          return
        }
        if (!isObject(stored) || !issuedClient(stored.clientId) || !nonEmpty(stored.subject) ||
            (stored.email !== null && !nonEmpty(stored.email)) || !Array.isArray(stored.scopes)) throw storeFailed()
        const hasTokens = stored.accessToken !== undefined || stored.refreshToken !== undefined || stored.idToken !== undefined
        if (hasTokens && (!nonEmpty(stored.accessToken) || !nonEmpty(stored.idToken) || !Number.isFinite(stored.expiresAt) ||
            (stored.refreshToken !== null && !nonEmpty(stored.refreshToken)))) throw storeFailed()
        registration = registrationOf(stored)
        grant = hasTokens ? stored : null
      }).finally(() => { loading = undefined })
      await loading
    }
  }

  async function http(url, { form, signal, revocation = false, tokenGrant } = {}) {
    checkSignal(signal)
    const deadline = AbortSignal.timeout(15_000)
    const requestSignal = signal ? AbortSignal.any([signal, deadline]) : deadline
    const network = () => error('network', 'Could not reach OpenAI. Try again.')
    const failure = () => signal?.aborted ? cancelled() : network()
    let response
    try {
      response = await waitFor(fetch(url, {
        redirect: 'error', signal: requestSignal,
        method: form ? 'POST' : 'GET',
        headers: form
          ? { accept: 'application/json', 'content-type': 'application/x-www-form-urlencoded' }
          : { accept: 'application/json' },
        body: form ? new URLSearchParams(form) : undefined,
      }), requestSignal, failure)
    } catch { throw failure() }
    if (response.status === 200 && revocation) return
    if (response.status >= 500) {
      void response.body?.cancel().catch(() => {})
      throw error('unavailable', 'OpenAI authorization is temporarily unavailable.')
    }
    let body
    if (response.status === 200 || tokenGrant) {
      try { body = await waitFor(response.json(), requestSignal, failure) } catch {
        checkSignal(requestSignal, failure)
        if (response.status === 200) throw invalidResponse()
      }
    }
    if (response.status === 200) return body
    if (!tokenGrant) void response.body?.cancel().catch(() => {})
    if (tokenGrant && body?.error === 'invalid_client') {
      throw error('invalid_client', 'OpenAI rejected the registered client.')
    }
    if (tokenGrant === 'refresh_token' && UNUSABLE_REFRESH.has(body?.error)) throw sessionExpired()
    if (tokenGrant === 'authorization_code' && body?.error === 'invalid_grant') {
      throw error('invalid_grant', 'The OpenAI authorization code is no longer valid.')
    }
    throw error('authorization_rejected', 'OpenAI rejected the authorization request.')
  }

  function exchange(form, signal) {
    return http(TOKEN, { form: { ...form, resource: RESOURCE }, signal, tokenGrant: form.grant_type })
  }

  async function identity(idToken, { clientId, nonce, previous, accessToken, signal }) {
    let parts, header, claims
    try {
      parts = idToken.split('.')
      if (parts.length !== 3 || !parts.every((part) => b64url.test(part))) throw invalidIdentity()
      header = decodePart(parts[0])
      claims = decodePart(parts[1])
    } catch { throw invalidIdentity() }
    if (header.alg !== 'RS256' || !nonEmpty(header.kid) || header.crit !== undefined || header.b64 !== undefined) {
      throw invalidIdentity()
    }
    if (Date.now() >= jwksExpiresAt || !jwks?.some((key) => key?.kid === header.kid)) {
      const published = await http(JWKS, { signal })
      if (!Array.isArray(published?.keys)) throw invalidIdentity()
      jwks = published.keys
      jwksExpiresAt = Date.now() + 5 * 60_000
    }
    const keys = jwks.filter((key) => key?.kid === header.kid && key.kty === 'RSA' &&
      (key.alg === undefined || key.alg === 'RS256') && (key.use === undefined || key.use === 'sig') &&
      (key.key_ops === undefined || (Array.isArray(key.key_ops) && key.key_ops.includes('verify'))))
    try {
      if (keys.length !== 1 || !verify('RSA-SHA256', Buffer.from(parts[0] + '.' + parts[1]),
        createPublicKey({ format: 'jwk', key: keys[0] }), Buffer.from(parts[2], 'base64url'))) throw invalidIdentity()
    } catch { throw invalidIdentity() }
    const now = Date.now() / 1000
    const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud]
    if (claims.iss !== ISSUER || !audiences.every(nonEmpty) || !audiences.includes(clientId) ||
        ((audiences.length > 1 || claims.azp !== undefined) && claims.azp !== clientId) ||
        !Number.isFinite(claims.exp) || claims.exp <= now || !Number.isFinite(claims.iat) || claims.iat > now + 5 ||
        (claims.nbf !== undefined && (!Number.isFinite(claims.nbf) || claims.nbf > now + 5)) ||
        ((nonce !== undefined || claims.nonce !== undefined) && !sameString(claims.nonce, nonce ?? previous?.nonce)) ||
        !nonEmpty(claims.sub) || (previous?.subject && claims.sub !== previous.subject) ||
        (claims.at_hash !== undefined && !sameString(claims.at_hash, sha256(accessToken).subarray(0, 16).toString('base64url')))) {
      throw invalidIdentity()
    }
    return { subject: claims.sub, email: nonEmpty(claims.email) ? claims.email : previous?.email ?? null }
  }

  async function authorize(notify, signal, newAccount) {
    checkSignal(signal)
    await waitFor(load(), signal)
    if (newAccount && grant) throw error('sign_out_required', 'Sign out before connecting another ChatGPT account.')
    const hostId = await waitFor(storage(getHostId), signal)
    if (typeof hostId !== 'string' || !/^(urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|urn:ietf:params:oauth:jwk-thumbprint:[a-z0-9-]+:[A-Za-z0-9_-]+|did:key:[A-Za-z0-9]+)$/i.test(hostId)) {
      throw error('invalid_host_id', 'The OpenAI host identifier is not configured correctly.')
    }
    // Reconnect keeps the issued client and its usage settings. Replace the
    // saved binding only after an explicit switch has verified the new grant.
    let selected = newAccount ? undefined : registration
    const reconsent = grant !== null && !hasPlanPermission(grant.scopes)
    for (let attempt = 0; ; attempt++) {
      const state = randomValue(), nonce = randomValue(), verifier = randomValue()
      const { code, clientId, redirectUri } = await browserCode({
        hostId, selected, state, nonce, verifier, notify, signal, reconsent,
      })
      let body
      try {
        body = await exchange({
          grant_type: 'authorization_code', client_id: clientId, code, code_verifier: verifier, redirect_uri: redirectUri,
        }, signal)
      } catch (cause) {
        if (cause.code !== 'siwc_invalid_grant' || attempt !== 0) throw cause
        // Discard the code, not the newly issued client ID. No identity is saved yet.
        selected ??= { clientId }
        continue
      }
      const tokens = parseTokenSet(body)
      const verified = await identity(body.id_token, { clientId, nonce, previous: selected, accessToken: tokens.accessToken, signal })
      const next = { ...tokens, ...verified, clientId, idToken: body.id_token, nonce }
      checkSignal(signal)
      // Atomic save is the commit point. A concurrent sign-out is queued after
      // it and immediately hides the account, even while this write is pending.
      await storage(() => store.save(next))
      grant = next
      registration = registrationOf(next)
      pendingSave = pendingPlanLoss = false
      if (signingOut) throw cancelled()
      return accountStatus(grant)
    }
  }

  async function saveRotation() {
    await storage(() => store.save(grant))
    pendingSave = false
    // A saved JWKS-pending rotation has already lost these scopes. Finishing
    // its identity check later must not announce the same loss again.
    const lost = pendingPlanLoss
    pendingPlanLoss = false
    if (lost && !signingOut) onGrantLost()
  }

  async function finishRotation() {
    if (grant.pendingIdentity) {
      let verified
      try {
        verified = await identity(grant.idToken, { clientId: grant.clientId, previous: grant, accessToken: grant.accessToken })
      } catch (cause) {
        if (!signingOut) {
          if (cause.code === 'siwc_network' || cause.code === 'siwc_unavailable') {
            // Preserve the replacement in protected storage, never use it
            // until verification succeeds, and never replay the consumed token.
            if (pendingSave) await saveRotation()
          } else {
            await clear()
          }
        }
        throw cause
      }
      const { pendingIdentity, ...verifiedGrant } = grant
      grant = { ...verifiedGrant, ...verified }
      registration = registrationOf(grant)
      pendingSave = true
    }
    if (pendingSave && !signingOut) await saveRotation()
  }

  async function clear({ signedOut = false } = {}) {
    const lost = grant != null && !signedOut
    grant = null
    pendingSave = pendingPlanLoss = false
    if (lost) onGrantLost()
    if (!registration) {
      await storage(() => store.clear())
      return
    }
    try {
      // Atomically drop every token but preserve the verified client binding.
      await storage(() => store.save({ ...registration, scopes: [] }))
    } catch {
      // Losing the reconnect metadata is preferable to retaining credentials.
      await storage(() => store.clear())
    }
  }

  async function access() {
    if (signingOut) throw signInRequired()
    await load()
    if (signingOut || !grant) throw signInRequired()
    if (grant.pendingIdentity || pendingSave) await finishRotation()
    if (signingOut) throw signInRequired()
    if (!hasPlanPermission(grant.scopes)) throw planMissing()
    if (grant.expiresAt > Date.now() + (grant.refreshToken ? RENEW_BEFORE_MS : 0)) return grant.accessToken
    if (!grant.refreshToken) {
      await clear()
      throw sessionExpired()
    }
    const previous = grant
    let body
    try {
      body = await exchange({ grant_type: 'refresh_token', client_id: previous.clientId, refresh_token: previous.refreshToken })
    } catch (cause) {
      if (cause.code === 'siwc_session_expired' || cause.code === 'siwc_invalid_response') await clear()
      throw cause
    }
    try {
      const next = parseTokenSet(body, previous)
      grant = { ...previous, ...next, idToken: body.id_token ?? previous.idToken, ...(body.id_token && { pendingIdentity: true }) }
      pendingSave = true
      pendingPlanLoss = !hasPlanPermission(next.scopes)
    } catch (cause) {
      // A successful HTTP refresh may already have consumed the old token.
      // Do not retry it if the replacement fails validation.
      await clear()
      throw cause
    }
    if (signingOut) throw signInRequired()
    await finishRotation()
    if (signingOut) throw signInRequired()
    if (!hasPlanPermission(grant.scopes)) throw planMissing()
    return grant.accessToken
  }

  async function revoke({ clientId, refreshToken }) {
    for (let retry = 0; ; retry++) {
      try {
        const metadata = await http(DISCOVERY)
        let endpoint
        try { endpoint = new URL(metadata?.revocation_endpoint) } catch { throw invalidResponse() }
        if (metadata.issuer !== ISSUER || endpoint.origin !== ISSUER || endpoint.username || endpoint.password || endpoint.hash) {
          throw invalidResponse()
        }
        await http(endpoint.href, { revocation: true, form: {
          client_id: clientId, token: refreshToken, token_type_hint: 'refresh_token',
        } })
        return
      } catch (cause) {
        if (retry === 2 || (cause.code !== 'siwc_network' && cause.code !== 'siwc_unavailable')) {
          throw error('revocation_unconfirmed', 'Signed out locally, but OpenAI revocation could not be confirmed. Disconnect the app in ChatGPT Settings.')
        }
        await delay(250 * 2 ** retry)
      }
    }
  }

  return {
    async signIn({ notify, signal, newAccount = false }) {
      checkSignal(signal)
      if (pendingSignOut) throw signOutIncomplete()
      if (signInController || signingOut) throw error('busy', 'Another OpenAI authorization operation is in progress.')
      const controller = new AbortController()
      signInController = controller
      const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal
      try {
        return await serialize(() => authorize(notify, combined, newAccount === true))
      } finally {
        signInController = undefined
      }
    },
    async token(signal) {
      checkSignal(signal)
      if (pendingSignOut) throw signOutIncomplete()
      if (signingOut) throw signInRequired()
      const requestedEpoch = epoch
      tokenFlight ??= serialize(access).finally(() => { tokenFlight = undefined })
      const token = await waitFor(tokenFlight, signal)
      checkSignal(signal)
      if (requestedEpoch !== epoch) throw signInRequired()
      return token
    },
    async status() {
      if (pendingSignOut) return { ...accountStatus(null, registration), signOutPending: true }
      if (signingOut) return accountStatus(null, registration)
      await load()
      return accountStatus(signingOut ? null : grant, registration)
    },
    signOut() {
      if (signingOut) return signingOut
      epoch++
      signingOut = serialize(async () => {
        let revocation = pendingSignOut?.revocation
        try {
          await load()
          if (grant?.refreshToken) revocation = { clientId: grant.clientId, refreshToken: grant.refreshToken }
          if (revocation) {
            await revoke(revocation)
            revocation = undefined
          }
        } finally {
          try {
            await clear({ signedOut: true })
          } catch {
            // Keep only an unconfirmed revocation for retry, never a grant
            // capable of inference. Suspend sign-ins until local cleanup works.
            pendingSignOut = { revocation }
            throw signOutIncomplete()
          }
          pendingSignOut = undefined
        }
      }).finally(() => { signingOut = undefined })
      signInController?.abort()
      return signingOut
    },
  }
}
