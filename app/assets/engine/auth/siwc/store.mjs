// SPDX-License-Identifier: MIT
//
// Android's guest reports process.platform === 'linux'. The app-only launch variable
// plus a live, authenticated abstract socket identifies the native endpoint.
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto'
import { createConnection } from 'node:net'

const MAX_GRANT_BYTES = 64 * 1024
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
const ENDPOINT = new RegExp('^(dsh-app\\.siwc\\.' + UUID + '):([0-9a-f]{64})$')
const HOST_ID = new RegExp('^' + UUID + '$')
const [IDENTIFY, LOAD, SAVE, CLEAR] = [1, 2, 3, 4]

// Keep the launch descriptor in this module for llm re-injection, not in the
// environment of later children. This does not isolate untrusted same-UID
// code (which may inspect /proc) or code running in the same Node engine.
const launchEndpoint = (() => {
  const value = process.env.DSH_APP_SIWC_SOCKET_SECRET
  delete process.env.DSH_APP_SIWC_SOCKET_SECRET
  const match = ENDPOINT.exec(value ?? '')
  return match && { address: match[1], secret: Buffer.from(match[2], 'hex') }
})()

function storeError() {
  return Object.assign(new Error('Android SIWC secure storage failed'), { code: 'siwcStoreFailed' })
}

// challenge[32] -> HMAC-SHA256[32] -> op[1] (SAVE also length[4] BE + JSON)
// -> status[1] + payload, terminated by the server closing the socket.
function request(address, secret, op, payload) {
  const challenge = randomBytes(32)
  const expect = createHmac('sha256', secret).update(challenge).digest()
  const proof = Buffer.alloc(expect.length)
  let proofSize = 0
  let responseSize = 0
  const response = []
  return new Promise((resolve, reject) => {
    const socket = createConnection({ path: '\0' + address })
    const timeout = setTimeout(fail, 5000)
    function fail() {
      clearTimeout(timeout)
      socket.destroy()
      reject(storeError())
    }
    socket.once('connect', () => socket.write(challenge))
    socket.once('error', fail)
    socket.once('close', fail)
    socket.on('data', chunk => {
      if (proofSize < proof.length) {
        // The legitimate peer sends nothing else until it receives the operation.
        if (chunk.length > proof.length - proofSize) return fail()
        chunk.copy(proof, proofSize)
        proofSize += chunk.length
        if (proofSize !== proof.length) return
        if (!timingSafeEqual(proof, expect)) return fail()
        const header = Buffer.alloc(payload ? 5 : 1)
        header[0] = op
        if (payload) header.writeUInt32BE(payload.length, 1)
        socket.write(header)
        if (payload) socket.write(payload)
        return
      }
      responseSize += chunk.length
      if (responseSize > MAX_GRANT_BYTES + 1) return fail()
      response.push(chunk)
    })
    socket.once('end', () => {
      const result = Buffer.concat(response, responseSize)
      if (result[0] !== 0) return fail()
      clearTimeout(timeout)
      resolve(result.subarray(1))
    })
  })
}

const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value)

export async function openSiwcStore() {
  if (process.platform !== 'linux' && process.platform !== 'android') return null
  if (!launchEndpoint) return null
  const { address, secret } = launchEndpoint
  const call = (op, payload) => request(address, secret, op, payload)
  let hostId
  try {
    hostId = (await call(IDENTIFY)).toString('ascii')
    if (!HOST_ID.test(hostId)) return null
  } catch {
    return null
  }
  return {
    getHostId: async () => 'urn:uuid:' + hostId,
    store: {
      async load() {
        const bytes = await call(LOAD)
        if (!bytes.length) return null
        try {
          const grant = JSON.parse(bytes.toString('utf8'))
          if (!isRecord(grant)) throw storeError()
          return grant
        } catch {
          // JSON syntax errors can quote the input; never propagate them.
          throw storeError()
        } finally {
          bytes.fill(0)
        }
      },
      async save(grant) {
        if (!isRecord(grant)) throw storeError()
        let bytes
        try {
          bytes = Buffer.from(JSON.stringify(grant), 'utf8')
        } catch {
          throw storeError()
        }
        try {
          if (bytes.length > MAX_GRANT_BYTES) throw storeError()
          await call(SAVE, bytes)
        } finally {
          bytes.fill(0)
        }
      },
      async clear() { await call(CLEAR) },
    },
  }
}
