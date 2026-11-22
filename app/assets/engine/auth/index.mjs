// SPDX-License-Identifier: MIT
//
// dsh-app auth bridge: DSH plugin that exposes subscription sign-in (ChatGPT,
// Claude) to the app as the `appAuth` Remote service:
//
//   appAuth/list                  → {providers: [{id, signedIn, account?}]}
//   appAuth/usage {provider}      → {provider, status, windows, plan?}
//   appAuth/begin  {provider, newAccount?} → {attemptId}
//   appAuth/poll   {attemptId}    → {phase, url?, userCode?, message?, placeholder?, error?}
//   appAuth/answer {attemptId, value} → {}
//   appAuth/cancel {attemptId}    → {}
//   appAuth/signOut {provider}    → {}
//
// The app writes this directory into the guest (/opt/dsh-app/auth/) at every
// engine start and mounts it with an extra `--patch` overlay that inserts this
// file by absolute path; the logic lives in bridge.mjs.
//
// Wiring notes (DSH 0.2.1-rc.2):
// - The Gateway serves a service without a generated Typert descriptor through
//   its source-mode fallback: it finds the `typertRemote` binding of a
//   TypertRemoteService, reads the methods marked with `Remote`, and takes the
//   wire argument names from the method signatures. So the methods below take
//   plain identifier parameters whose names are the wire names.
// - Node has no decorator syntax, so `Remote` is applied the way compiled
//   decorators apply it: once per method, with its initializer run in the
//   constructor.
// - This file lives outside DSH's install and profiles, so bare imports would
//   not resolve; the host's own copy of the protocol package is loaded from the
//   running DSH install instead (same file, same module instance).

import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

import { AuthBridge } from './bridge.mjs'

/** Where the dsh-app rootfs installs DSH (the `dsh` shim runs this file). */
const GUEST_DSH_BIN = '/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js'

/** Imports a package from the running DSH install. */
async function hostImport(specifier) {
  const anchors = [process.argv[1], GUEST_DSH_BIN].filter((anchor) => typeof anchor === 'string' && anchor.length > 0)
  const failures = []
  for (const anchor of anchors) {
    try {
      return await import(pathToFileURL(createRequire(anchor).resolve(specifier)).href)
    } catch (error) {
      failures.push(`${anchor}: ${error?.code ?? error?.message ?? error}`)
    }
  }
  try {
    return await import(specifier)
  } catch (error) {
    failures.push(`bare: ${error?.code ?? error?.message ?? error}`)
  }
  throw new Error(`dsh-app auth: cannot load ${specifier} from the DSH install (${failures.join('; ')})`)
}

const { TypertRemoteService, Remote, RemoteError } = await hostImport('@deepseek-ai/dsh-typert-protocol')

/** The Remote methods, by implementation name (= wire method name). */
const REMOTE_METHODS = ['list', 'usage', 'begin', 'poll', 'answer', 'cancel', 'signOut']
const markRemoteMethods = []

export default class AppAuth extends TypertRemoteService {
  // credentials: grants are read and deleted here. authorization: the flows
  // llm-pi-ai registers. settings is optional and looked up per call.
  static inject = ['credentials', 'authorization']
  #siwc

  /** @param ctx - plugin context. */
  constructor(ctx) {
    super(ctx, 'appAuth')
    for (const mark of markRemoteMethods) mark.call(this)
    this.bridge = new AuthBridge({ get: (name) => ctx.get(name), RemoteError, siwc: () => this.#siwc })
    ctx.effect(() => () => this.bridge.dispose(), 'appAuth: sign-in attempts')
    // The same authorization writer survives replacement of the LLM owner.
    let oauthReady
    const openOAuth = async () => {
      const { openSiwcStore } = await import('./siwc/store.mjs')
      const storage = await openSiwcStore()
      if (!storage) return null
      const { createSiwcOAuth } = await import('./siwc/oauth.mjs')
      return createSiwcOAuth({
        ...storage, fetch: globalThis.fetch,
        onGrantLost: () => this.#siwc?.invalidate({ stopRequests: false }),
      })
    }
    ctx.inject(['llm'], async (owner) => {
      let active = true
      let registration
      owner.effect(() => () => {
        active = false
        if (registration && this.#siwc?.invalidate === registration.invalidate) {
          this.#siwc = undefined
          this.bridge.withdrawOpenAiAttempt()
        }
        registration?.dispose()
      }, 'appAuth: OpenAI channel')
      try {
        const oauth = await (oauthReady ??= openOAuth())
        if (!oauth || !active) return
        const { registerSiwcProvider } = await import('./siwc/provider.mjs')
        if (!active) return
        registration = registerSiwcProvider({ llm: owner.llm, oauth })
        this.#siwc = { oauth, invalidate: registration.invalidate }
      } catch {
        if (active) console.error('[dsh-app auth] OpenAI channel initialization failed')
      }
    })
  }

  list() {
    return this.bridge.list()
  }

  usage(provider) {
    return this.bridge.usage(provider)
  }

  begin(provider, newAccount) {
    return this.bridge.begin(provider, newAccount)
  }

  poll(attemptId) {
    return this.bridge.poll(attemptId)
  }

  answer(attemptId, value) {
    return this.bridge.answer(attemptId, value)
  }

  cancel(attemptId) {
    return this.bridge.cancel(attemptId)
  }

  signOut(provider) {
    return this.bridge.signOut(provider)
  }
}

for (const name of REMOTE_METHODS) {
  Remote(AppAuth.prototype[name], {
    kind: 'method',
    name,
    static: false,
    private: false,
    addInitializer: (initializer) => markRemoteMethods.push(initializer),
  })
}
