import { createHash, randomUUID } from 'node:crypto';
import { STATUS_CODES } from 'node:http';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { isMainThread } from 'node:worker_threads';
import { linuxHostPaths } from './host-paths.mjs';
import { deriveLinuxJobDiagnostic } from './job-diagnostics.mjs';
import { LinuxProxyPolicy, withoutInheritedProxy } from './proxy.mjs';

const route = '/dsh-go/v1/linux';
const fail = (code, message, status = 409) => Object.assign(new Error(message), { code, status });
const requestError = message => fail('ERR_OHOS_LINUX_REQUEST', message, 400);
const codeOf = cause => /^[A-Z][A-Z0-9_]{0,127}$/.test(cause?.code ?? '') ? cause.code : 'ERR_OHOS_LINUX_CONTROL';
const plain = value => value && typeof value === 'object' && !Array.isArray(value);
const bounded = (value, limit, nul = false) => typeof value === 'string' && Buffer.byteLength(value) <= limit && (nul || !value.includes('\0'));
// A routed command that cannot run ends with this shell status and message.
const routed = (exitCode, code, message) => Object.assign(new Error(message), { code, exitCode });
const settings = '设置 · 能力 · Linux 环境';
const emptyOutput = () => ({ encoding: 'base64', data: '', totalBytes: 0, retainedBytes: 0, truncated: false });
const output = collector => {
  if (!collector) return emptyOutput();
  const { bytes, totalBytes } = collector.snapshot();
  return { encoding: 'base64', data: bytes.toString('base64'), totalBytes,
    retainedBytes: bytes.length, truncated: totalBytes > bytes.length };
};
const noOwner = () => ({ resourcesRetired: true, filesRemoved: true, dataRetained: false,
  ownerQuarantined: false, native: null, releaseErrorCode: null, guestClose: null, cleanCheckpoint: false });
function nativeRetirement(native) {
  if (!native) return null;
  const result = { joined: native.joined === true, retirementError: native.retirementError, apiResult: native.apiResult };
  for (const key of ['joinAttempted', 'joinError', 'waitError']) if (Object.hasOwn(native, key)) result[key] = native[key];
  if (Object.hasOwn(native, 'stopNotification')) {
    const wake = native.stopNotification;
    result.stopNotification = plain(wake) ? { attempted: wake.attempted === true, notified: wake.notified === true,
      unnecessary: wake.unnecessary === true, errorCode: wake.errorCode } : null;
  }
  if (Object.hasOwn(native, 'fdRetirement')) {
    const fds = native.fdRetirement;
    result.fdRetirement = plain(fds) ? { retired: fds.retired === true, consoleError: fds.consoleError,
      wakeReadError: fds.wakeReadError, wakeWriteError: fds.wakeWriteError } : null;
  }
  if (Object.hasOwn(native, 'ramRetirement')) {
    const ram = native.ramRetirement;
    result.ramRetirement = plain(ram) ? { eligible: ram.eligible === true, attempted: ram.attempted === true,
      trackedBytes: ram.trackedBytes, eligibleBytes: ram.eligibleBytes,
      advisedBytes: ram.advisedBytes, errorCode: ram.errorCode } : null;
  }
  return result;
}
function retirement(value) {
  return { resourcesRetired: value.resourcesRetired === true, filesRemoved: value.filesRemoved === true,
    dataRetained: value.dataRetained === true, ownerQuarantined: value.ownerQuarantined === true,
    native: nativeRetirement(value.native),
    releaseErrorCode: value.releaseError ? codeOf(value.releaseError) : null,
    guestClose: value.guestClose ? { ...value.guestClose } : null, cleanCheckpoint: value.cleanCheckpoint === true };
}
function runRequest(body) {
  if (!Number.isSafeInteger(body.requestId) || body.requestId < 1 || !Array.isArray(body.argv) ||
      body.argv.length < 1 || body.argv.length > 128 || !body.argv[0] ||
      body.argv.some(value => !bounded(value, 8192)) ||
      body.argv.reduce((sum, value) => sum + Buffer.byteLength(value), 0) > 24576 || body.cwd !== '/workspace') {
    throw requestError('Expected bounded argv, requestId and explicit private guest cwd');
  }
  const env = body.env === undefined ? {} : body.env;
  const stdin = body.stdin === undefined ? '' : body.stdin;
  if (!plain(env) || Object.keys(env).length > 64 || Buffer.byteLength(JSON.stringify(env)) > 16384 ||
      Object.entries(env).some(([key, value]) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) || key.length > 128 || !bounded(value, 4096)) ||
      !bounded(stdin, 16384, true)) throw requestError('Expected bounded batch stdin and explicit guest environment');
  // Sort only env keys for duplicate identity. Never log or return this digest
  // or the credentials that may have been explicitly supplied by the caller.
  return { argv: [...body.argv], cwd: body.cwd, env: Object.fromEntries(Object.entries(env).sort(([a], [b]) => a.localeCompare(b))), stdin };
}

/** One explicit App entry, and the owner of agent/plugin commands routed into the guest. */
export class LinuxControl {
  #instanceId = randomUUID(); #attemptId = null; #phase = 'disabled'; #enabled = false;
  #paths; #assets; #loadModule; #owner; #backend; #installAbort; #installPromise; #installSettled = false;
  #disablePromise; #discardPromise; #shutdownPromise; #closing = false; #shutdownComplete = false;
  #failed = false; #unknown = false; #lastError = null; #progress = null; #retirement = null;
  #job; #nextRequestId = 1; #lastRequestDigest; #routed = null; #exports = Object.freeze([]);
  #proxy = new LinuxProxyPolicy();

  constructor({ hostPaths, assetsDirectory } = {}, internals = {}) {
    this.#paths = hostPaths; this.#assets = assetsDirectory;
    // Test-only constructor seam. The production factory below exposes no
    // caller-selected manifest, directory, module, environment or native path.
    this.#loadModule = internals.loadModule ?? (() => import('./owner.mjs'));
  }
  /** App directories every VM of this attempt exports over virtio-9p. */
  get exports() { return this.#exports; }
  exportWorkspaces(roots) {
    if (!Array.isArray(roots) || roots.length > 4 || !roots.every(root => typeof root === 'string' && root.startsWith('/') && !root.includes('\0'))) {
      throw new TypeError('At most four absolute App directories can be exported');
    }
    // The VM learns its exports at boot; a later owner cannot change a started attempt,
    // and its commands outside those directories are refused as not exported.
    if (this.#attemptId === null) this.#exports = Object.freeze(roots.map((path, index) => Object.freeze({ tag: 'dsh' + index, path })));
  }
  /** Retained results and an idle retained VM are not work; uncertain retirement is. */
  hasActiveWork() {
    if (this.#shutdownComplete) return false;
    return this.#unknown || this.#backend?.state === 'quarantined'
      || (this.#job !== undefined && this.#job.state !== 'settled') || this.#routed !== null
      || (this.#installPromise !== undefined && !this.#installSettled)
      || this.#disablePromise !== undefined || this.#discardPromise !== undefined
      || (this.#closing && !this.#shutdownComplete);
  }
  status() {
    const backendState = this.#backend?.state ?? null;
    const unknown = this.#unknown || backendState === 'quarantined' || this.#job?.state === 'unknown';
    const guestOpened = backendState === 'opened' && !this.#backend.closed;
    const admission = this.#enabled && this.#phase === 'enabled' && guestOpened && !unknown && !this.#closing && !this.#disablePromise;
    const job = this.#job;
    return { v: 1, instanceId: this.#instanceId, attemptId: this.#attemptId,
      persistentInstanceId: this.#owner?.persistentInstanceId ?? null, bootMode: this.#owner?.bootMode ?? null,
      nativeMemoryRelease: this.#owner?.nativeOwnerCreated ? 'process-exit' : null,
      proxy: this.#proxy.status(),
      state: unknown ? 'unknown' : this.#phase, enabled: this.#enabled, admission, guestOpened,
      ownerRetained: !!this.#owner, workspaceLease: false,
      restartRequired: this.#failed || this.#closing || unknown, shutdownComplete: this.#shutdownComplete,
      nextRequestId: this.#nextRequestId, ownerState: this.#owner?.state ?? null, backendState,
      progress: this.#progress && { ...this.#progress }, lastErrorCode: unknown ? 'ERR_OHOS_LINUX_UNKNOWN' : this.#lastError,
      job: job ? { id: job.id, proxyRevision: job.proxyRevision, state: unknown && job.state !== 'settled' ? 'unknown' : job.state,
        started: job.started, cancelRequested: job.cancelRequested, outcome: job.outcome && { ...job.outcome },
        errorCode: job.errorCode, diagnostic: job.diagnostic && { ...job.diagnostic },
        stdout: output(job.handle.collected.stdout), stderr: output(job.handle.collected.stderr) } : null,
      retirement: this.#retirement && { ...this.#retirement, native: nativeRetirement(this.#retirement.native),
        guestClose: this.#retirement.guestClose && { ...this.#retirement.guestClose } } };
  }
  command(body) {
    if (!plain(body) || body.v !== 1 || typeof body.instanceId !== 'string' ||
        !(body.attemptId === null || typeof body.attemptId === 'string')) throw requestError('Invalid control identity');
    const fields = { setEnabled: ['enabled'], setProxy: ['proxy'], runPrivateGuest: ['requestId', 'argv', 'cwd', 'env', 'stdin'], shutdown: [], discardRetained: [] };
    if (!Object.hasOwn(fields, body.action) || Object.keys(body).some(key => !['v', 'instanceId', 'attemptId', 'action', ...fields[body.action]].includes(key))) {
      throw requestError('Unknown action or field');
    }
    if (body.instanceId !== this.#instanceId || body.attemptId !== this.#attemptId) throw fail('ERR_OHOS_LINUX_STALE', 'Control identity no longer matches this runtime attempt');
    if (body.action === 'setEnabled') {
      if (typeof body.enabled !== 'boolean') throw requestError('enabled must be boolean');
      this.#setEnabled(body.enabled);
    } else if (body.action === 'setProxy') {
      if (this.#closing) throw fail('ERR_OHOS_LINUX_CLOSED', 'Final shutdown already started');
      this.#proxy.set(body.proxy);
    } else if (body.action === 'runPrivateGuest') this.#run(body);
    // The only action that completes before replying: a promise of the status.
    else if (body.action === 'discardRetained') return this.#discard();
    else this.shutdown();
    return this.status();
  }
  #progressEvent(event) {
    this.#progress = { stage: typeof event.stage === 'string' ? event.stage.slice(0, 64) : 'unknown',
      done: Number.isSafeInteger(event.done) && event.done >= 0 ? event.done : null,
      total: Number.isSafeInteger(event.total) && event.total >= 0 ? event.total : null,
      step: typeof event.step === 'string' ? event.step.slice(0, 32) : null };
  }
  #setEnabled(enabled) {
    if (this.#closing) throw fail('ERR_OHOS_LINUX_CLOSED', 'Final shutdown already started');
    if (enabled) {
      if (this.#disablePromise) throw fail('ERR_OHOS_LINUX_BUSY', 'Disable has not settled');
      if (this.#discardPromise) throw fail('ERR_OHOS_LINUX_BUSY', 'Retained Linux data is being discarded');
      if (this.#failed || this.status().state === 'unknown') throw fail('ERR_OHOS_LINUX_RESTART_REQUIRED', 'This owner cannot be restarted');
      if (!this.#paths) throw fail('ERR_OHOS_LINUX_HOST_PATHS', 'Trusted preload paths are unavailable', 503);
      this.#enabled = true;
      if (this.#installPromise) {
        if (this.#backend?.state === 'opened' && !this.#backend.closed) this.#phase = 'enabled';
        return;
      }
      this.#attemptId = randomUUID(); this.#phase = 'installing'; this.#installAbort = new AbortController();
      this.#installPromise = this.#install(); this.#installPromise.catch(() => {});
      return;
    }
    this.#enabled = false;
    if (this.#disablePromise || this.#discardPromise) return;
    if (!this.#installPromise) { this.#phase = 'disabled'; return; }
    const installing = !this.#backend;
    // A running VM has one native lifetime. Ordinary off uses its final join
    // barrier; discarded RAM pages cannot resume in this App process.
    if (!installing) { this.shutdown(); return; }
    this.#phase = 'disabling';
    if (installing) this.#installAbort.abort(fail('ABORT_ERR', 'Installation cancelled by explicit switch'));
    this.#disablePromise = (async () => {
      await this.#installPromise.catch(() => {});
      try { await this.#drainJob(); } catch (cause) { this.#recordUnknown(cause); }
      if (installing && this.#owner) this.#retirement = retirement(await this.#owner.dispose());
      if (!this.#closing) this.#phase = 'disabled';
    })().catch(cause => this.#recordUnknown(cause)).finally(() => { this.#disablePromise = undefined; });
  }
  async #install() {
    const signal = this.#installAbort.signal;
    try {
      const module = await this.#loadModule(); signal.throwIfAborted();
      let manifest;
      try { manifest = await module.loadLinuxInstallationManifest({ assetsDirectory: this.#assets }); }
      catch (cause) { throw Object.assign(fail('ERR_OHOS_LINUX_ASSETS_UNAVAILABLE', 'Signed Linux assets are unavailable'), { cause }); }
      signal.throwIfAborted();
      this.#owner = module.createLinuxInstallationOwner({ ...this.#paths, manifest, exports: this.#exports,
        onProgress: event => this.#progressEvent(event) });
      const result = await this.#owner.install({ signal });
      this.#backend = result.backend; signal.throwIfAborted();
      if (this.#backend.state !== 'opened' || this.#backend.closed) throw fail('ERR_OHOS_LINUX_UNKNOWN', 'Guest opening did not remain valid');
      if (!this.#closing && this.#enabled) this.#phase = 'enabled';
    } catch (cause) {
      this.#failed = true; this.#lastError = codeOf(cause);
      if (this.#owner) this.#retirement = retirement(await this.#owner.dispose());
      if (cause.code === 'ERR_OHOS_LINUX_UNKNOWN' || this.#owner?.state === 'quarantined') this.#recordUnknown(cause);
      if (!this.#closing && !signal.aborted) this.#phase = cause.code === 'ERR_OHOS_LINUX_ASSETS_UNAVAILABLE' ? 'unavailable' : 'failed';
      throw cause;
    } finally { this.#installSettled = true; }
  }
  /**
   * The explicit 重新安装 Linux: deletes the retained instance, for one that
   * openLinuxInstance refuses to resume. Only while Linux is off (or its
   * install has settled as failed), nothing is in flight, and an owner of
   * this process, if any, never created a VM and is confirmed retired; one
   * that did may still hold the disk until the App process exits. Such a
   * VM-less attempt is then forgotten, so the next switch-on in this same
   * process is a fresh install. The switch stays off; nothing turns it on.
   */
  async #discard() {
    if (this.#closing) throw fail('ERR_OHOS_LINUX_CLOSED', 'Final shutdown already started');
    const failedInstall = this.#installSettled && ['failed', 'unavailable'].includes(this.#phase);
    if (this.#discardPromise || this.#disablePromise || (this.#installPromise && !this.#installSettled) ||
        (this.#enabled && !failedInstall) || (this.#job && this.#job.state !== 'settled') || this.#routed) {
      throw fail('ERR_OHOS_LINUX_BUSY', 'Linux must be off and idle before its data is discarded');
    }
    const owner = this.#owner, attempt = this.#installPromise;
    if (this.status().state === 'unknown' || (owner && (owner.nativeOwnerCreated || this.#retirement?.resourcesRetired !== true))) {
      throw fail('ERR_OHOS_LINUX_RESTART_REQUIRED', 'A Linux owner of this process may still hold the retained data');
    }
    if (!this.#paths) throw fail('ERR_OHOS_LINUX_HOST_PATHS', 'Trusted preload paths are unavailable', 503);
    this.#enabled = false;
    this.#discardPromise = (async () => {
      try {
        const module = await this.#loadModule();
        await module.discardLinuxInstallation({ directory: this.#paths.directory });
      } catch (cause) { this.#lastError = codeOf(cause); throw cause; }
      this.#lastError = null;
      if (attempt) {
        this.#owner = undefined; this.#installPromise = undefined; this.#installAbort = undefined;
        this.#installSettled = false; this.#failed = false; this.#retirement = null; this.#progress = null;
      }
      if (!this.#closing) this.#phase = 'disabled';
    })();
    try { await this.#discardPromise; } finally { this.#discardPromise = undefined; }
    return this.status();
  }
  #run(body) {
    const request = runRequest(body), digest = createHash('sha256').update(JSON.stringify(request)).digest('hex');
    if (this.#job?.id === body.requestId && digest === this.#lastRequestDigest) return;
    if (body.requestId !== this.#nextRequestId) throw fail('ERR_OHOS_LINUX_REQUEST_REUSED', 'Request identity is old, reused or out of order');
    if (!this.status().admission) throw fail('ERR_OHOS_LINUX_DISABLED', 'Private guest admission is closed');
    if ((this.#job && this.#job.state !== 'settled') || this.#routed) throw fail('ERR_OHOS_LINUX_BUSY', 'One private guest job is still live or unknown');
    if (this.#nextRequestId >= Number.MAX_SAFE_INTEGER) throw fail('ERR_OHOS_LINUX_REQUEST_REUSED', 'Request identity space exhausted');
    const proxy = this.#proxy.forRequest(request.env);
    const handle = this.#backend.spawn({ argv: request.argv, cwd: request.cwd, env: proxy.environment, graceMs: 10000,
      stdio: { stdin: { data: request.stdin }, stdout: { maxBytes: 16384 }, stderr: { maxBytes: 16384 } } });
    const job = { id: body.requestId, proxyRevision: proxy.revision, handle, state: 'queued', started: false, cancelRequested: false, outcome: null, errorCode: null, diagnostic: null };
    this.#job = job; this.#lastRequestDigest = digest; this.#nextRequestId++;
    handle.started.then(() => { job.started = true; if (job.state === 'queued') job.state = 'running'; }, () => {});
    job.settled = handle.done.then(outcome => {
      job.outcome = outcome; job.state = 'settled';
      job.diagnostic = deriveLinuxJobDiagnostic({ state: job.state, outcome, stderr: output(handle.collected.stderr) });
    }, cause => {
      job.state = 'unknown'; job.errorCode = codeOf(cause); this.#recordUnknown(cause);
    });
  }
  /**
   * Run an agent or plugin command. It waits for a resuming VM, never installs
   * one. The guest runs one job at a time, shared with runPrivateGuest: a
   * command waits up to waitMs for that lane and then fails as busy, so a
   * long-lived server holding it cannot queue every later command forever.
   */
  async spawnRouted(spec, { signal, label, waitMs = 10000, resumeMs = 120000 } = {}) {
    const resumeBy = performance.now() + resumeMs, busyBy = performance.now() + waitMs;
    for (;;) {
      signal?.throwIfAborted();
      const status = this.status(), busy = (this.#job && this.#job.state !== 'settled') || this.#routed;
      if (status.admission && !busy) break;
      if (!status.enabled && !this.#closing) throw routed(127, 'ERR_OHOS_LINUX_DISABLED', `Linux 环境未开启：请在 ${settings} 中打开后重试。`);
      if (!status.admission) {
        if (status.state === 'installing' && this.#owner?.bootMode === 'install') {
          throw routed(127, 'ERR_OHOS_LINUX_INSTALLING', `Linux 环境正在首次安装，完成后重试；进度见 ${settings}。`);
        }
        if (status.state !== 'installing' || performance.now() >= resumeBy) {
          throw routed(127, 'ERR_OHOS_LINUX_UNAVAILABLE', `Linux 环境当前不可用（${status.state}${status.lastErrorCode ? '，' + status.lastErrorCode : ''}）：请在 ${settings} 查看，必要时重启 App。`);
        }
      } else if (performance.now() >= busyBy) {
        throw routed(126, 'ERR_OHOS_LINUX_BUSY', `Linux 环境同一时间只运行一个命令，现在被 ${this.#routed?.label ?? '另一个命令'} 占用；请等它结束后重试。`);
      }
      await delay(100, undefined, { signal });
    }
    let env;
    try { env = this.#proxy.forRequest(withoutInheritedProxy(spec.env)).environment; }
    catch (cause) { throw routed(126, codeOf(cause), `命令自带的代理变量与 ${settings} 的代理设置冲突；去掉它们，或把代理改回“继承”。`); }
    const handle = this.#backend.spawn({ ...spec, env });
    const job = this.#routed = { handle, label };
    handle.done.catch(() => {}).finally(() => { if (this.#routed === job) this.#routed = null; });
    return handle;
  }
  #recordUnknown(cause) { this.#unknown = true; this.#lastError = codeOf(cause); }
  async #drainJob() {
    const routedJob = this.#routed?.handle;
    if (routedJob) {
      routedJob.terminate('SIGTERM');
      if (await routedJob.waitForExit() !== true) throw fail('ERR_OHOS_LINUX_UNKNOWN', 'Routed job release was not confirmed');
    }
    const job = this.#job;
    if (!job || job.state === 'settled') return;
    if (!job.cancelRequested) { job.cancelRequested = true; job.handle.terminate('SIGTERM'); }
    if (await job.handle.waitForExit() !== true) throw fail('ERR_OHOS_LINUX_UNKNOWN', 'Job release was not confirmed');
    await job.settled;
    if (job.state === 'unknown') throw fail('ERR_OHOS_LINUX_UNKNOWN', 'Job outcome remains unknown');
  }
  shutdown() {
    if (this.#shutdownPromise) return this.#shutdownPromise;
    this.#closing = true; this.#enabled = false; this.#phase = 'stopping';
    this.#installAbort?.abort(fail('ABORT_ERR', 'Final Linux shutdown'));
    this.#shutdownPromise = (async () => {
      // Await the whole chain, including lazy module/manifest reads before an
      // owner exists. No-owner is safe only after those continuations ended.
      await this.#installPromise?.catch(() => {}); await this.#disablePromise;
      // A discard holds the root flock but no VM; let it finish before stopping.
      await this.#discardPromise?.catch(() => {});
      try { await this.#drainJob(); } catch (cause) { this.#recordUnknown(cause); }
      if (this.#backend?.state === 'quarantined') this.#recordUnknown(fail('ERR_OHOS_LINUX_UNKNOWN', 'Guest transport failed'));
      this.#retirement = this.#owner ? retirement(await this.#owner.dispose()) : noOwner();
      this.#shutdownComplete = this.#retirement.resourcesRetired;
      if (!this.#shutdownComplete) this.#recordUnknown(fail('ERR_OHOS_LINUX_UNKNOWN', 'Native resource retirement was not confirmed'));
      this.#phase = 'stopped';
      return this.status();
    })().catch(cause => { this.#recordUnknown(cause); return this.status(); });
    return this.#shutdownPromise;
  }
}

let production;
export function createLinuxControl() {
  if (!isMainThread) throw fail('ERR_OHOS_LINUX_OWNER', 'Only the application main thread owns Linux');
  return production ??= new LinuxControl({ hostPaths: linuxHostPaths(),
    assetsDirectory: fileURLToPath(new URL('./assets/', import.meta.url)) });
}

function readJson(req) {
  if ((req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') throw fail('ERR_OHOS_LINUX_REQUEST', 'Expected application/json', 415);
  return new Promise((resolve, reject) => {
    const chunks = []; let bytes = 0, settled = false;
    const finish = (cause, value) => {
      if (settled) return; settled = true; clearTimeout(timer);
      req.off('data', data); req.off('end', end); req.off('error', broken); req.off('aborted', broken);
      if (cause) { req.resume(); reject(cause); } else resolve(value);
    };
    const data = chunk => { bytes += chunk.length; if (bytes > 65536) finish(fail('ERR_OHOS_LINUX_REQUEST', 'Control body exceeds bound', 413)); else chunks.push(chunk); };
    const end = () => { try { const body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
      if (!plain(body)) throw requestError('Expected object'); finish(undefined, body); } catch { finish(requestError('Invalid JSON object')); } };
    const broken = () => finish(requestError('Request stream failed'));
    const timer = setTimeout(() => finish(fail('ERR_OHOS_LINUX_REQUEST', 'Request body timed out', 408)), 10000);
    req.on('data', data); req.on('end', end); req.on('error', broken); req.on('aborted', broken);
  });
}
export function registerLinuxControlRoutes(ctx, control) {
  const handler = async (req, res) => {
    const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'content-type': 'application/json; charset=utf-8' };
    const reply = (status, body) => { if (status === 408 || status === 413) headers.connection = 'close';
      if (!res.destroyed && !res.writableEnded) { res.writeHead(status, headers); res.end(req.method === 'HEAD' ? undefined : JSON.stringify(body)); } };
    try {
      const connection = ctx.get('connection'), rejection = connection === undefined ? 503 : connection.requestRejection(req);
      if (rejection !== undefined) { reply(rejection, { error: STATUS_CODES[rejection] ?? 'Request rejected' }); return; }
      if (!['GET', 'POST'].includes(req.method)) { headers.allow = 'GET, POST'; reply(405, { error: 'Method Not Allowed' }); return; }
      if (req.url !== route) throw requestError('Control route does not accept query or path arguments');
      if (req.method === 'GET') reply(200, control.status());
      else {
        // 202: accepted, may still be running. 200: discardRetained has finished.
        const body = await readJson(req), status = await control.command(body);
        reply(body.action === 'discardRetained' ? 200 : 202, status);
      }
    } catch (cause) {
      const status = cause.status ?? (cause instanceof TypeError ? 400 : 409);
      reply(status, { v: 1, error: { code: codeOf(cause), message: STATUS_CODES[status] ?? 'Linux control failed' }, status: control.status() });
    }
  };
  ctx.effect(() => ctx.webServer.register({ kind: 'exact', path: route, handler }), 'ohos explicit Linux control');
}
