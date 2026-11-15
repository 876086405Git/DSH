#!/usr/bin/env node
// Host-side measurement client. Only standard Node modules; never runs guest tools on the host.
import { createHash, randomUUID } from 'node:crypto';
import fs, { constants } from 'node:fs/promises';
import { Agent, request } from 'node:http';
import { connect } from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { witnessCommands, validateWitnessResult, compareWitnessResults } from './research/linux-resume/guest-witness.mjs';

const ROUTE = '/dsh-go/v1/linux';
const CAP = 65536;
const STATES = ['disabled', 'installing', 'enabled', 'disabling', 'stopping', 'stopped', 'unavailable', 'failed', 'unknown'];
export const LOCKED_VERSIONS = Object.freeze({ gh: '2.97.0', python: '3.14.10', rg: '15.1.0', git: '2.54.0' });
const fail = (code, category = 'protocol') => Object.assign(new Error(code), { code, category });
const safeCode = error => /^[A-Z][A-Z0-9_]{0,127}$/.test(error?.code ?? '') ? error.code : 'ERR_MEASURE_INTERNAL';
const plain = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const bounded = (value, limit) => typeof value === 'string' && Buffer.byteLength(value) <= limit && !value.includes('\0');
const nonnegative = value => Number.isSafeInteger(value) && value >= 0;
const id = value => typeof value === 'string' && /^[A-Za-z0-9._-]{1,128}$/.test(value);
const code = value => value === null || typeof value === 'string' && /^[A-Z][A-Z0-9_]{0,127}$/.test(value);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const DIAGNOSTICS = Object.freeze({
  dns: '命令输出提示域名解析失败。请检查网络、DNS 或代理设置。',
  connection: '命令输出提示无法建立连接或连接超时。请检查网络以及代理地址和端口。',
  'tls-interrupted': '命令输出提示 TLS 连接被中途断开。请检查网络或代理；仅凭此输出无法判断断开方。',
  'tls-certificate': '命令输出提示 TLS 证书校验失败。请检查设备时间、代理证书和证书配置，不要关闭证书验证。',
  unknown: '命令失败；错误输出不足以确定原因，尚不能归类为 DNS、连接或 TLS 错误。',
});

export function endpoint(value) {
  const matched = /^http:\/\/127\.0\.0\.1:([0-9]{1,5})\/?$/.exec(value ?? '');
  if (!matched || Number(matched[1]) < 1 || Number(matched[1]) > 65535) throw fail('ERR_MEASURE_ENDPOINT');
  return { origin: `http://127.0.0.1:${Number(matched[1])}`, port: Number(matched[1]) };
}

export function cloneUrl(value) {
  if (value === undefined) return null;
  if (!bounded(value, 8192) || /[\u0000-\u0020\u007f]/.test(value) || !value.startsWith('https://') || value.includes('?') || value.includes('#')) throw fail('ERR_MEASURE_CLONE_URL');
  let url;
  try { url = new URL(value); } catch { throw fail('ERR_MEASURE_CLONE_URL'); }
  const authority = value.slice('https://'.length).split('/')[0];
  if (url.protocol !== 'https:' || url.username || url.password || authority.includes('@') || !url.hostname || Buffer.byteLength(url.href) > 8192) throw fail('ERR_MEASURE_CLONE_URL');
  return url.href;
}

async function readBounded(file, limit, privateFile = false) {
  const handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0));
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > limit || privateFile && (stat.mode & 0o077) !== 0) throw fail('ERR_MEASURE_INPUT_FILE');
    const bytes = Buffer.alloc(limit + 1); let length = 0;
    while (length < bytes.length) {
      const result = await handle.read(bytes, length, bytes.length - length, length);
      if (!result.bytesRead) break;
      length += result.bytesRead;
    }
    if (length > limit) throw fail('ERR_MEASURE_INPUT_FILE');
    return bytes.subarray(0, length);
  } finally { await handle.close(); }
}

async function readToken(file) {
  const token = new TextDecoder('utf-8', { fatal: true }).decode(await readBounded(file, 4096)).replace(/\r?\n$/, '');
  if (!token || /[\0\r\n]/.test(token)) throw fail('ERR_MEASURE_TOKEN_FILE');
  return token;
}

async function readGuestEnv(file) {
  if (!file) return null;
  const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await readBounded(file, 16384)));
  if (!plain(value) ||
      Object.entries(value).some(([key, item]) => !/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(key) || !bounded(item, 4096))) {
    throw fail('ERR_MEASURE_ENV_FILE');
  }
  const env = { LC_ALL: 'C', GIT_TERMINAL_PROMPT: '0', GH_PROMPT_DISABLED: '1', ...value };
  if (Object.keys(env).length > 64 || Buffer.byteLength(JSON.stringify(env)) > 16384) throw fail('ERR_MEASURE_ENV_FILE');
  return env;
}

async function readProxy(file) {
  if (!file) return null;
  try {
    const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await readBounded(file, 16384, true)));
    if (!plain(value) || !['inherit', 'direct', 'manual'].includes(value.mode) ||
        Object.keys(value).some(key => !['mode', 'httpProxy', 'httpsProxy', 'noProxy'].includes(key))) throw fail('ERR_MEASURE_PROXY_FILE');
    if (value.mode !== 'manual') {
      if (Object.keys(value).length !== 1) throw fail('ERR_MEASURE_PROXY_FILE');
    } else if (![value.httpProxy, value.httpsProxy].some(item => typeof item === 'string' && item.length > 0) ||
      ['httpProxy', 'httpsProxy', 'noProxy'].some(key => value[key] !== undefined && !bounded(value[key], 4096))) throw fail('ERR_MEASURE_PROXY_FILE');
    // Only the trusted producer normalizes proxy addresses and chooses guest
    // loopback mapping. This private object is never included in evidence.
    return value;
  } catch { throw fail('ERR_MEASURE_PROXY_FILE'); }
}

function closeProof(value) {
  if (value === null || value === undefined) return null;
  if (!plain(value) || typeof value.epoch !== 'string' || !/^[a-f0-9]{64}$/.test(value.epoch) ||
      value.rootfsSync !== true || value.syncMethod !== 'syncfs' || value.syncScope !== 'rootfs') throw fail('ERR_MEASURE_RETIREMENT_PROTOCOL');
  return { epoch: value.epoch, rootfsSync: true, syncMethod: 'syncfs', syncScope: 'rootfs' };
}

function projectRetirement(row, persistentInstanceId) {
  if (!plain(row) || ![row.resourcesRetired, row.filesRemoved, row.dataRetained, row.ownerQuarantined].every(item => typeof item === 'boolean') ||
      !code(row.releaseErrorCode)) throw fail('ERR_MEASURE_RETIREMENT_PROTOCOL');
  let native = null;
  if (row.native !== null) {
    const item = row.native;
    if (!plain(item) || typeof item.joined !== 'boolean' || !(item.retirementError === null || typeof item.retirementError === 'boolean') ||
        !(item.apiResult === null || Number.isSafeInteger(item.apiResult))) throw fail('ERR_MEASURE_RETIREMENT_PROTOCOL');
    native = { joined: item.joined, retirementError: item.retirementError, apiResult: item.apiResult };
  }
  const guestClose = closeProof(row.guestClose), cleanCheckpoint = row.cleanCheckpoint === undefined ? false : row.cleanCheckpoint;
  if (typeof cleanCheckpoint !== 'boolean' || cleanCheckpoint && (!uuid(persistentInstanceId) || !row.resourcesRetired ||
      !row.dataRetained || row.filesRemoved || !guestClose || !native?.joined || native.retirementError !== false ||
      ![-3, -4].includes(native.apiResult))) throw fail('ERR_MEASURE_RETIREMENT_PROTOCOL');
  return { resourcesRetired: row.resourcesRetired, filesRemoved: row.filesRemoved, dataRetained: row.dataRetained,
    ownerQuarantined: row.ownerQuarantined, releaseErrorCode: row.releaseErrorCode, native, guestClose, cleanCheckpoint };
}

function output(value) {
  if (!plain(value) || value.encoding !== 'base64' || typeof value.data !== 'string' || value.data.length > 21848 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.data) ||
      !nonnegative(value.totalBytes) || !nonnegative(value.retainedBytes) || value.retainedBytes > 16384 ||
      value.totalBytes < value.retainedBytes || value.truncated !== (value.totalBytes > value.retainedBytes)) {
    throw fail('ERR_MEASURE_OUTPUT_PROTOCOL');
  }
  const bytes = Buffer.from(value.data, 'base64');
  if (bytes.length !== value.retainedBytes || bytes.toString('base64') !== value.data) throw fail('ERR_MEASURE_OUTPUT_PROTOCOL');
  return { bytes, totalBytes: value.totalBytes, retainedBytes: value.retainedBytes, truncated: value.truncated };
}

export function decodeStatus(value) {
  if (!plain(value) || value.v !== 1 || !id(value.instanceId) || !(value.attemptId === null || id(value.attemptId)) ||
      !STATES.includes(value.state) || ![value.enabled, value.admission, value.guestOpened, value.ownerRetained,
        value.workspaceLease, value.restartRequired, value.shutdownComplete].every(item => typeof item === 'boolean') ||
      value.workspaceLease !== false || !Number.isSafeInteger(value.nextRequestId) || value.nextRequestId < 1 ||
      !code(value.lastErrorCode)) throw fail('ERR_MEASURE_STATUS_PROTOCOL');
  const state = Object.fromEntries(['v', 'instanceId', 'attemptId', 'state', 'enabled', 'admission', 'guestOpened',
    'ownerRetained', 'workspaceLease', 'restartRequired', 'shutdownComplete', 'nextRequestId', 'lastErrorCode'].map(key => [key, value[key]]));
  state.persistentInstanceId = value.persistentInstanceId ?? null; state.bootMode = value.bootMode ?? null;
  state.nativeMemoryRelease = value.nativeMemoryRelease ?? null;
  if (!(state.persistentInstanceId === null || uuid(state.persistentInstanceId)) ||
      !(state.bootMode === null || ['install', 'resume'].includes(state.bootMode)) ||
      (state.persistentInstanceId === null) !== (state.bootMode === null) ||
      ![null, 'process-exit'].includes(state.nativeMemoryRelease)) throw fail('ERR_MEASURE_STATUS_PROTOCOL');
  state.proxy = null;
  if (value.proxy !== undefined) {
    const row = value.proxy;
    if (!plain(row) || Object.keys(row).length !== 4 || Object.keys(row).some(key => !['source', 'revision', 'httpConfigured', 'httpsConfigured'].includes(key)) ||
        !['inherit', 'direct', 'manual'].includes(row.source) || !nonnegative(row.revision) ||
        typeof row.httpConfigured !== 'boolean' || typeof row.httpsConfigured !== 'boolean' ||
        row.source === 'direct' && (row.httpConfigured || row.httpsConfigured) ||
        row.source === 'manual' && !row.httpConfigured && !row.httpsConfigured) throw fail('ERR_MEASURE_PROXY_PROTOCOL');
    state.proxy = { source: row.source, revision: row.revision, httpConfigured: row.httpConfigured, httpsConfigured: row.httpsConfigured };
  }
  for (const key of ['ownerState', 'backendState']) {
    if (!(value[key] === null || typeof value[key] === 'string' && /^[a-z0-9-]{1,64}$/.test(value[key]))) throw fail('ERR_MEASURE_STATUS_PROTOCOL');
    state[key] = value[key];
  }
  state.progress = null;
  if (value.progress !== null) {
    const row = value.progress;
    if (!plain(row) || !bounded(row.stage, 64) || !(row.step === null || bounded(row.step, 32)) ||
        ![row.done, row.total].every(item => item === null || nonnegative(item))) throw fail('ERR_MEASURE_STATUS_PROTOCOL');
    state.progress = Object.fromEntries(['stage', 'step', 'done', 'total'].map(key => [key, row[key]]));
  }
  state.job = null;
  if (value.job !== null) {
    const row = value.job;
    if (!plain(row) || !Number.isSafeInteger(row.id) || row.id < 1 || !['queued', 'running', 'settled', 'unknown'].includes(row.state) ||
        typeof row.started !== 'boolean' || typeof row.cancelRequested !== 'boolean' || !code(row.errorCode)) throw fail('ERR_MEASURE_JOB_PROTOCOL');
    let outcome = null;
    if (row.outcome !== null) {
      const item = row.outcome;
      if (!plain(item) || !(item.exitCode === null || Number.isSafeInteger(item.exitCode)) ||
          !(item.signal === null || typeof item.signal === 'string' && /^SIG[A-Z0-9]{1,20}$/.test(item.signal)) ||
          typeof item.cancelled !== 'boolean') throw fail('ERR_MEASURE_JOB_PROTOCOL');
      outcome = { exitCode: item.exitCode, signal: item.signal, cancelled: item.cancelled };
      if (item.notStarted !== undefined) {
        if (typeof item.notStarted !== 'boolean') throw fail('ERR_MEASURE_JOB_PROTOCOL');
        outcome.notStarted = item.notStarted;
      }
      if (item.requestedSignal !== undefined) {
        if (item.requestedSignal !== 'SIGTERM') throw fail('ERR_MEASURE_JOB_PROTOCOL');
        outcome.requestedSignal = item.requestedSignal;
      }
    }
    if (row.state === 'unknown' && outcome !== null || row.state === 'settled' && outcome === null) throw fail('ERR_MEASURE_JOB_PROTOCOL');
    state.job = { id: row.id, state: row.state, started: row.started, cancelRequested: row.cancelRequested,
      outcome, errorCode: row.errorCode, stdout: output(row.stdout), stderr: output(row.stderr) };
    if (row.proxyRevision !== undefined && !nonnegative(row.proxyRevision)) throw fail('ERR_MEASURE_PROXY_PROTOCOL');
    state.job.proxyRevision = row.proxyRevision === undefined ? null : row.proxyRevision;
    state.job.diagnostic = null;
    if (row.diagnostic !== undefined && row.diagnostic !== null) {
      const hint = row.diagnostic;
      if (!plain(hint) || !Object.hasOwn(DIAGNOSTICS, hint.category) ||
          hint.evidence !== (hint.category === 'unknown' ? 'none' : 'stderr') || typeof hint.message !== 'string' ||
          row.state !== 'settled' || !outcome || outcome.cancelled || outcome.signal !== null || outcome.notStarted ||
          !Number.isInteger(outcome.exitCode) || outcome.exitCode < 1 || outcome.exitCode > 255) throw fail('ERR_MEASURE_DIAGNOSTIC_PROTOCOL');
      // Reconstruct fixed text, never export arbitrary server messages/fields.
      state.job.diagnostic = { category: hint.category, evidence: hint.evidence, message: DIAGNOSTICS[hint.category] };
    }
  }
  state.retirement = null;
  if (value.retirement !== null) {
    state.retirement = projectRetirement(value.retirement, state.persistentInstanceId);
  }
  return state;
}

export function retirementConfirmed(state) {
  const row = state?.retirement;
  return state?.shutdownComplete === true && row?.resourcesRetired === true &&
    (row.native === null ? row.ownerQuarantined === false : row.native.joined === true && row.native.retirementError === false);
}

function cleanCheckpointConfirmed(state) {
  return retirementConfirmed(state) && state.state === 'stopped' && uuid(state.persistentInstanceId) &&
    ['install', 'resume'].includes(state.bootMode) && state.retirement.cleanCheckpoint === true &&
    state.retirement.guestClose !== null && [-3, -4].includes(state.retirement.native?.apiResult);
}

function projectWitness(record, phase) {
  record = validateWitnessResult({ phase, stdout: record });
  const metadata = (value, file = false) => {
    if (!nonnegative(value.bytes)) throw fail('ERR_MEASURE_WITNESS_RECORD');
    return { path: value.path, bytes: value.bytes, uid: value.uid, gid: value.gid, mode: value.mode,
      inode: value.inode, mtimeNs: value.mtimeNs, device: { major: value.device.major, minor: value.device.minor },
      ...(file ? { sha256: value.sha256 } : {}) };
  };
  const mount = record.rootMounts.find(row => row.target === '/' && row.type === 'ext4' &&
    [record.targetDevice.path, '/dev/root'].includes(row.source) && row.options.includes('rw'));
  if (!bounded(record.pythonVersion, 128) || ['system', 'release', 'version', 'machine'].some(key => !bounded(record.uname[key], 2048)) ||
      !bounded(mount.raw, 4096) || mount.options.length > 64 || mount.options.some(value => !bounded(value, 128))) throw fail('ERR_MEASURE_WITNESS_RECORD');
  return { v: 1, phase, uid: record.uid, gid: record.gid, pythonVersion: record.pythonVersion,
    uname: Object.fromEntries(['system', 'release', 'version', 'machine'].map(key => [key, record.uname[key]])),
    root: metadata(record.root), rootMounts: [{ source: mount.source, target: '/', type: 'ext4', options: [...mount.options], raw: mount.raw }],
    targetDevice: { path: record.targetDevice.path, isBlock: true, major: record.targetDevice.major, minor: record.targetDevice.minor },
    workspace: metadata(record.workspace), configDirectory: metadata(record.configDirectory),
    agent: metadata(record.agent, true), init: metadata(record.init, true), data: metadata(record.data, true), config: metadata(record.config, true) };
}

async function readPreviousSummary(file) {
  if (!file) return null;
  try {
    const bytes = await readBounded(file, 262144);
    const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    const final = value.finalStatus;
    if (!plain(value) || value.v !== 1 || !plain(final) || !id(value.instanceId) || value.instanceId !== final.instanceId ||
        !id(value.attemptId) || value.attemptId !== final.attemptId || !uuid(final.persistentInstanceId) ||
        final.bootMode !== 'install' || value.shutdownConfirmed !== true || value.witnessCleanCheckpoint !== true) throw fail('ERR_MEASURE_RESUME_INPUT');
    const checked = { state: final.state, shutdownComplete: final.shutdownComplete, persistentInstanceId: final.persistentInstanceId,
      bootMode: final.bootMode, retirement: projectRetirement(final.retirement, final.persistentInstanceId) };
    if (!cleanCheckpointConfirmed(checked)) throw fail('ERR_MEASURE_RESUME_INPUT');
    return { instanceId: value.instanceId, persistentInstanceId: final.persistentInstanceId,
      guestClose: checked.retirement.guestClose, witness: projectWitness(value.witness, 'write'), summarySha256: hash(bytes) };
  } catch { throw fail('ERR_MEASURE_RESUME_INPUT'); }
}

class Evidence {
  #start = process.hrtime.bigint(); #sequence = 0; #tails = new Map(); #withhold = false;
  constructor(directory, withhold = false) { this.directory = directory; this.#withhold = withhold; }
  get outputWithheld() { return this.#withhold; }
  ms() { return Number(process.hrtime.bigint() - this.#start) / 1e6; }
  async event(kind, value = {}) {
    const row = { sequence: ++this.#sequence, at: new Date().toISOString(), monotonicNs: (process.hrtime.bigint() - this.#start).toString(), kind, ...value };
    await fs.appendFile(path.join(this.directory, 'events.jsonl'), JSON.stringify(row) + '\n', { mode: 0o600 });
    return row;
  }
  async status(label, state, ownedJob) {
    // Proxy/account configuration can reach arbitrary command output. This is
    // sticky for the entire measurement, before processing this status's job.
    // Current proxy facts cannot establish the provenance of a historical or
    // unconfirmed job, even when the current setting has switched to direct.
    this.#withhold ||= state.job !== null && !ownedJob || state.proxy?.httpConfigured === true || state.proxy?.httpsConfigured === true;
    const value = { ...state };
    if (state.job) {
      value.job = { ...state.job };
      for (const stream of ['stdout', 'stderr']) {
        const source = state.job[stream];
        if (this.#withhold) {
          value.job[stream] = { outputWithheld: true, reason: 'OUTPUT_OMITTED_PRIVACY', totalBytes: source.totalBytes,
            retainedBytes: source.retainedBytes, truncated: source.truncated, startOffset: source.totalBytes - source.retainedBytes };
          continue;
        }
        const sha256 = hash(source.bytes); const key = `${state.job.id}/${stream}`;
        let previous = this.#tails.get(key);
        if (!previous || previous.sha256 !== sha256) {
          const directory = path.join(this.directory, 'jobs', String(state.job.id));
          await fs.mkdir(directory, { recursive: true, mode: 0o700 });
          const relative = `jobs/${state.job.id}/${stream}-${this.#sequence + 1}.bin`;
          await fs.writeFile(path.join(this.directory, relative), source.bytes, { flag: 'wx', mode: 0o600 });
          previous = { file: relative, sha256 }; this.#tails.set(key, previous);
        }
        value.job[stream] = { ...previous, totalBytes: source.totalBytes, retainedBytes: source.retainedBytes,
          truncated: source.truncated, startOffset: source.totalBytes - source.retainedBytes };
      }
    }
    await this.event('status', { label, status: value, retirementConfirmed: retirementConfirmed(state) });
    return value;
  }
}

class Client {
  #host; #token; #cookie = null; #evidence; #timeout; #agent;
  constructor(host, token, evidence, timeout) {
    this.#host = host; this.#token = token; this.#evidence = evidence; this.#timeout = timeout;
    this.#agent = new Agent({ keepAlive: false });
    // Even an inherited host proxy setting cannot move this connection away from the selected loopback port.
    this.#agent.createConnection = () => connect({ host: '127.0.0.1', port: host.port });
  }
  close() { this.#agent.destroy(); }
  async #request(method, target, body, label) {
    const started = this.#evidence.ms(); let receivedBytes = 0;
    try {
      const result = await new Promise((resolve, reject) => {
        const headers = { 'cache-control': 'no-store' };
        if (label !== 'login') headers.cookie = this.#cookie;
        if (body !== null) { headers['content-type'] = 'application/json'; headers['content-length'] = Buffer.byteLength(body); }
        let finished = false;
        const end = (error, result) => { if (finished) return; finished = true; clearTimeout(timer); error ? reject(error) : resolve(result); };
        const req = request({ hostname: '127.0.0.1', port: this.#host.port, method, path: target,
          headers, agent: this.#agent }, res => {
          const chunks = [];
          res.on('data', bytes => {
            receivedBytes += bytes.length;
            if (receivedBytes > CAP) { const error = fail('ERR_MEASURE_RESPONSE_LIMIT'); end(error); req.destroy(error); }
            else chunks.push(bytes);
          });
          res.on('end', () => end(null, { status: res.statusCode, headers: res.headers, bytes: Buffer.concat(chunks) }));
          res.on('error', error => end(fail(safeCode(error), 'transport')));
          res.on('aborted', () => end(fail('ERR_MEASURE_RESPONSE_ABORTED', 'transport')));
        });
        const timer = setTimeout(() => req.destroy(fail('ERR_MEASURE_HTTP_TIMEOUT', 'transport')), this.#timeout);
        req.on('error', error => end(fail(safeCode(error), error.category ?? 'transport')));
        req.end(body ?? undefined);
      });
      await this.#evidence.event('http', { operation: label, method, httpStatus: result.status, receivedBytes,
        elapsedMs: this.#evidence.ms() - started });
      return result;
    } catch (error) {
      await this.#evidence.event('http-failure', { operation: label, method, errorCode: safeCode(error), receivedBytes,
        elapsedMs: this.#evidence.ms() - started, completionInferred: false });
      throw error;
    }
  }
  async #login() {
    if (this.#cookie !== null) return;
    const result = await this.#request('GET', '/?token=' + encodeURIComponent(this.#token), null, 'login');
    const rows = result.headers['set-cookie'] ?? [];
    const cookies = rows.map(value => value.split(';')[0]).filter(value => /^dsh-auth-[A-Za-z0-9_-]+=[A-Za-z0-9_.-]+$/.test(value));
    if (result.status !== 303 || cookies.length !== 1) throw fail('ERR_MEASURE_AUTH');
    this.#cookie = cookies[0];
  }
  async exchange(body = null, operation = 'status') {
    await this.#login();
    const result = await this.#request(body === null ? 'GET' : 'POST', ROUTE, body, operation);
    if (result.status === 401) this.#cookie = null;
    let decoded;
    try { decoded = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(result.bytes)); }
    catch { throw fail('ERR_MEASURE_RESPONSE_JSON'); }
    if (result.status !== (body === null ? 200 : 202)) {
      const error = fail(code(decoded?.error?.code) && decoded.error.code !== null ? decoded.error.code : 'ERR_MEASURE_HTTP_STATUS', 'http');
      error.httpStatus = result.status;
      throw error;
    }
    return decodeStatus(decoded);
  }
}

const CLONE = `set -eu
d="/workspace/$1"
mkdir "$d"
git init --bare --quiet "$d/source.git"
git -c protocol.file.allow=always clone --no-hardlinks "file://$d/source.git" "$d/copy"
test "$(git -C "$d/copy" rev-parse --is-inside-work-tree)" = true
test "$(git -C "$d/copy" config --get remote.origin.url)" = "file://$d/source.git"
if git -C "$d/copy" rev-parse --verify HEAD >/dev/null 2>&1; then exit 1; fi
printf 'DSH_EMPTY_CLONE_OK\\n'`;

function cases(suite, env, repository, remote) {
  const text = value => value.job.stdout.bytes.toString('utf8');
  const successful = value => value.job.outcome?.exitCode === 0 && value.job.outcome.signal === null && value.job.outcome.cancelled === false;
  const row = (label, argv, check, extra = {}) => ({ label, argv, check: value => successful(value) && check(text(value)), ...extra });
  return [
    row('gh-version', ['gh', '--version'], value => value.startsWith('gh version 2.97.0 (2026-10-14)\n')),
    row('python-print', ['python3', '-c', 'print(1)'], value => value === '1\n'),
    row('python-version', ['python3', '--version'], value => value.trim() === 'Python 3.14.10'),
    row('rg-version', ['rg', '--version'], value => /^ripgrep 15\.1\.0(?:\s|$)/.test(value)),
    row('rg-search', ['rg', '--fixed-strings', '--line-number', 'needle'], value => value === '2:beta needle\n', { stdin: 'alpha\nbeta needle\n' }),
    row('git-version', ['git', '--version'], value => value.trim() === 'git version 2.54.0'),
    row('git-local-clone', ['sh', '-c', CLONE, 'dsh-measure', 'dsh-measure-' + suite], value => value === 'DSH_EMPTY_CLONE_OK\n'),
    ...(remote ? [row('git-remote-clone', ['git', 'clone', '--depth', '1', '--single-branch', '--no-tags', '--', remote,
      '/workspace/dsh-remote-' + suite], () => true),
    row('git-remote-head', ['git', '-C', '/workspace/dsh-remote-' + suite, 'rev-parse', '--verify', 'HEAD'],
      value => /^(?:[0-9a-f]{40}|[0-9a-f]{64})\n$/.test(value))] : []),
    ...(env ? [row('gh-pr-list', ['gh', 'pr', 'list', '--repo', repository, '--limit', '5', '--json', 'number,state,title,url'], value => {
      try { const rows = JSON.parse(value); return Array.isArray(rows) && rows.every(item => plain(item) && Number.isInteger(item.number)); } catch { return false; }
    }, { env })] : []),
  ];
}

export async function measure(options) {
  const host = endpoint(options.baseUrl);
  const remote = cloneUrl(options.cloneUrl);
  if (options.writeWitness && options.resumeFrom || options.observeOnly && (options.proxyFile || options.writeWitness || options.resumeFrom)) throw fail('ERR_MEASURE_ARGUMENT');
  const witnessPhase = options.writeWitness ? 'write' : options.resumeFrom ? 'read' : null;
  if (options.ghPrList && (!options.envFile || !/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/.test(options.ghRepo ?? '') ||
      ['.', '..'].includes(options.ghRepo.split('/')[1]))) throw fail('ERR_MEASURE_GH_ARGUMENT');
  await fs.mkdir(options.out, { mode: 0o700 }); // Existing evidence is never overwritten.
  const evidence = new Evidence(options.out, !!(options.proxyFile || options.envFile)); const suite = randomUUID();
  const result = { v: 1, suite, scope: 'Measurements of the supplied loopback endpoint; device identity is not attested by this client',
    nodeVersion: process.versions.node, lockedGuestVersions: LOCKED_VERSIONS, cases: [], status: 'INCOMPLETE',
    requestedChecks: { ghPrList: options.ghPrList === true, remoteClone: remote !== null,
      proxySetting: !!options.proxyFile, writeWitness: witnessPhase === 'write', resume: witnessPhase === 'read' },
    shutdownConfirmed: false, interruptionRequested: false, errors: [] };
  let client, state, instance, attempt, lastSaved, previous, ownsControl = false;
  if (witnessPhase) result.witnessCleanCheckpoint = false;
  if (witnessPhase === 'read') result.resumeConfirmed = false;
  const acceptedRequestIds = new Set();
  const interrupted = () => { result.interruptionRequested = true; };
  process.on('SIGINT', interrupted); process.on('SIGTERM', interrupted);
  const save = async label => { lastSaved = await evidence.status(label, state, state.job !== null && acceptedRequestIds.has(state.job.id)); return state; };
  const same = (value, allowFirstAttempt = false) => {
    if (value.instanceId !== instance || value.attemptId !== attempt && !(allowFirstAttempt && attempt === null)) throw fail('ERR_MEASURE_STALE');
    return value;
  };
  const get = async (label, allowFirstAttempt = false) => {
    const next = await client.exchange();
    if (instance) {
      try { same(next, allowFirstAttempt); }
      catch (error) {
        await evidence.event('identity-mismatch', { expectedInstanceId: instance, expectedAttemptId: attempt,
          observedInstanceId: next.instanceId, observedAttemptId: next.attemptId, completionInferred: false });
        throw error;
      }
    }
    state = next; await save(label); return state;
  };
  const unhealthy = () => ['unknown', 'failed', 'unavailable', 'stopped'].includes(state.state);
  const control = async (action, values = {}, firstAttempt = false, beforeSend = null) => {
    const body = JSON.stringify({ v: 1, instanceId: instance, attemptId: attempt, action, ...values });
    for (let number = 1; number <= 3; number++) {
      if (action === 'shutdown' || action === 'setProxy' || action === 'setEnabled' && values.enabled === false) {
        // These actions affect the whole owner. A previously observed idle owner
        // is not a lease: another client may have won admission in the meantime.
        await get(action + '-ownership');
        if (state.job && !acceptedRequestIds.has(state.job.id)) throw fail('ERR_MEASURE_FOREIGN_JOB');
      }
      beforeSend?.();
      try { state = same(await client.exchange(body, action), firstAttempt); await save(action); return state; }
      catch (error) {
        if (error.category !== 'transport') throw error;
        await evidence.event('control-unconfirmed', { action, transmission: number, completionInferred: false });
        await get(action + '-reconcile', firstAttempt);
        if (firstAttempt && state.attemptId !== attempt || action === 'shutdown' && retirementConfirmed(state) ||
            action === 'setEnabled' && values.enabled === false && state.enabled === false && !state.admission) return state;
        if (number === 3) throw fail('ERR_MEASURE_CONTROL_UNCONFIRMED');
        await delay(options.pollMs);
      }
    }
  };
  const waitFor = async (label, timeout, predicate, allowFailure = false) => {
    const deadline = evidence.ms() + timeout;
    while (!predicate(state)) {
      if (!allowFailure && (unhealthy() || result.interruptionRequested)) throw fail(result.interruptionRequested ? 'ERR_MEASURE_INTERRUPTED' : 'ERR_MEASURE_PROVIDER_STATE');
      if (evidence.ms() >= deadline) throw fail('ERR_MEASURE_OBSERVATION_TIMEOUT');
      await delay(options.pollMs); await get(label);
    }
    return state;
  };
  const run = async (test, cancellation = false) => {
    await get(test.label + '-before');
    if (!state.enabled || !state.guestOpened || state.state !== 'enabled' || !state.admission ||
        state.job && state.job.state !== 'settled') throw fail('ERR_MEASURE_ADMISSION');
    const requestId = state.nextRequestId;
    const item = { label: test.label, requestId, instanceId: instance, attemptId: attempt, sentMs: evidence.ms(),
      accepted: false, status: 'UNCONFIRMED', cancellationRequestedByClient: false };
    result.cases.push(item);
    const body = JSON.stringify({ v: 1, instanceId: instance, attemptId: attempt, action: 'runPrivateGuest', requestId,
      argv: test.argv, cwd: '/workspace', env: test.env ?? { LC_ALL: 'C', GIT_TERMINAL_PROMPT: '0' }, stdin: test.stdin ?? '' });
    // Keep these exact serialized bytes and this ID until ownership is confirmed.
    // A GET with the same numeric ID alone could belong to a racing client.
    for (let number = 1; number <= 3; number++) {
      try {
        state = same(await client.exchange(body, 'runPrivateGuest'));
        if (state.job?.id !== requestId) throw fail('ERR_MEASURE_JOB_ID');
        acceptedRequestIds.add(requestId);
        item.accepted = true; item.acceptedMs = evidence.ms(); await save(test.label + '-accepted'); break;
      } catch (error) {
        if (error.category !== 'transport') throw error;
        await evidence.event('run-unconfirmed', { label: test.label, requestId, transmission: number, completionInferred: false });
        await get(test.label + '-reconcile');
        if (number === 3) throw fail('ERR_MEASURE_RUN_UNCONFIRMED');
        await delay(options.pollMs); // Same body/ID retry; never allocate nextRequestId here.
      }
    }
    const ownJob = predicate => value => {
      if (value.job?.id !== requestId) throw fail('ERR_MEASURE_FOREIGN_JOB');
      return predicate(value);
    };
    const cancel = () => control('setEnabled', { enabled: false }, false, () => {
      item.cancellationRequestedByClient = true; item.cancelSentMs ??= evidence.ms();
    });
    if (cancellation) {
      await waitFor(test.label + '-started', options.jobTimeoutMs, ownJob(value =>
        value.job.started && value.job.stdout.bytes.includes(Buffer.from('DSH_CANCEL_READY\n'))));
      await cancel();
    }
    try {
      await waitFor(test.label + '-poll', options.jobTimeoutMs, ownJob(value => ['settled', 'unknown'].includes(value.job.state)));
    } catch (error) {
      item.status = error.code === 'ERR_MEASURE_OBSERVATION_TIMEOUT' ? 'OBSERVATION_TIMEOUT' : 'UNCONFIRMED';
      if (item.status === 'OBSERVATION_TIMEOUT') {
        await cancel();
        await waitFor(test.label + '-timeout-cancel', options.shutdownTimeoutMs,
          ownJob(value => ['settled', 'unknown'].includes(value.job.state)), true);
      }
      throw error;
    } finally {
      if (state?.job?.id === requestId) {
        item.observedAtMs = evidence.ms(); item.jobState = state.job.state;
        item.cancelRequested = state.job.cancelRequested; item.outcome = state.job.outcome;
        item.stdout = lastSaved?.job?.stdout; item.stderr = lastSaved?.job?.stderr;
      }
    }
    if (state.job.state === 'unknown' || state.state === 'unknown') { item.status = 'UNKNOWN'; throw fail('ERR_MEASURE_JOB_UNKNOWN'); }
    item.status = (cancellation ? state.job.cancelRequested && state.job.outcome.cancelled : test.check(state)) ? 'PASS' : 'FAIL';
    item.elapsedMs = item.observedAtMs - item.sentMs;
  };
  try {
    const token = await readToken(options.tokenFile);
    if (options.ghPrList && !options.envFile) throw fail('ERR_MEASURE_GH_ENV_REQUIRED');
    const env = options.ghPrList ? await readGuestEnv(options.envFile) : null;
    const proxy = await readProxy(options.proxyFile);
    previous = await readPreviousSummary(options.resumeFrom);
    client = new Client(host, token, evidence, options.requestTimeoutMs);
    await evidence.event('start', { suite, baseUrl: host.origin, programSha256: hash(await fs.readFile(fileURLToPath(import.meta.url))),
      ghPrListRequested: options.ghPrList === true, hasGhEnvironmentFile: env !== null, proxySettingRequested: proxy !== null,
      witnessPhase, observationOnly: options.observeOnly, timeBounds: {
        requestMs: options.requestTimeoutMs, pollMs: options.pollMs, installationMs: options.installTimeoutMs,
        jobMs: options.jobTimeoutMs, shutdownMs: options.shutdownTimeoutMs } });
    await get('initial'); instance = state.instanceId; attempt = state.attemptId;
    result.instanceId = instance; result.initialAttemptId = attempt;
    if (options.observeOnly) { result.status = 'OBSERVED_ONLY'; result.shutdownConfirmed = retirementConfirmed(state); return result; }
    if (previous && previous.instanceId === instance) throw fail('ERR_MEASURE_RESUME_IDENTITY');
    if (witnessPhase === 'write' && (attempt !== null || state.ownerRetained || state.guestOpened || state.job !== null || state.state !== 'disabled')) {
      throw fail('ERR_MEASURE_WITNESS_FRESH_INSTALL');
    }
    if (state.job && state.job.state !== 'settled') throw fail('ERR_MEASURE_EXISTING_JOB');
    ownsControl = true;
    if (proxy !== null) await control('setProxy', { proxy });
    const installStarted = evidence.ms();
    await control('setEnabled', { enabled: true }, true); attempt = state.attemptId;
    result.attemptId = attempt;
    await waitFor('installation', options.installTimeoutMs, value => value.admission && value.guestOpened && value.state === 'enabled');
    result.enableToOpenedObservedMs = evidence.ms() - installStarted;
    if (witnessPhase) {
      if (!uuid(state.persistentInstanceId) || state.bootMode !== (witnessPhase === 'write' ? 'install' : 'resume') ||
          previous && previous.persistentInstanceId !== state.persistentInstanceId) {
        throw fail(witnessPhase === 'write' ? 'ERR_MEASURE_WITNESS_FRESH_INSTALL' : 'ERR_MEASURE_RESUME_IDENTITY');
      }
      result.persistentInstanceId = state.persistentInstanceId; result.bootMode = state.bootMode;
      if (previous) result.previousMeasurement = { instanceId: previous.instanceId, persistentInstanceId: previous.persistentInstanceId,
        summarySha256: previous.summarySha256, guestCloseEpoch: previous.guestClose.epoch };
      const command = witnessCommands({ phase: witnessPhase })[0];
      await run({ label: command.name, argv: [...command.argv], check: value => value.job.outcome.exitCode === 0 &&
        value.job.outcome.signal === null && value.job.outcome.cancelled === false && !value.job.stdout.truncated });
      if (result.cases.at(-1).status !== 'PASS') throw fail('ERR_MEASURE_WITNESS_FAILED');
      result.witness = projectWitness(state.job.stdout.bytes, witnessPhase);
      result.witnessRequestId = state.job.id;
      if (previous) result.witnessComparison = compareWitnessResults(previous.witness, result.witness);
    }
    for (const test of cases(suite, env, options.ghRepo, remote)) {
      if (result.interruptionRequested) throw fail('ERR_MEASURE_INTERRUPTED');
      await run(test);
    }
    if (!env) result.cases.push({ label: 'gh-pr-list', status: 'NOT_RUN', reason: 'NOT_OPTED_IN' });
    if (!remote) result.cases.push({ label: 'git-remote-clone', status: 'NOT_RUN', reason: 'NO_CLONE_URL' });
    await run({ label: 'cooperative-cancel', argv: ['python3', '-u', '-c',
      'import time\nprint("DSH_CANCEL_READY", flush=True)\ntime.sleep(600)'] }, true);
    await waitFor('off-after-cancel', options.shutdownTimeoutMs, value => !value.enabled && !value.admission &&
      (value.state === 'disabled' || value.state === 'stopped' && retirementConfirmed(value)));
    result.cancellation = { requested: true, jobSettled: state.job?.state === 'settled',
      cancelRequested: state.job?.cancelRequested, outcome: state.job?.outcome, ownerRetained: state.ownerRetained,
      guestOpened: state.guestOpened, attemptId: state.attemptId };
    result.status = result.cases.some(row => row.status === 'FAIL') ? 'FAIL' : env && remote ? 'PASS_SCOPED' : env || remote ? 'PASS_PARTIAL_SCOPE' : 'PASS_LOCAL_ONLY';
  } catch (error) {
    result.errors.push({ code: safeCode(error), category: error.category ?? 'local' });
    result.status = state?.state === 'unknown' || state?.job?.state === 'unknown' ? 'UNKNOWN' : 'INCOMPLETE';
  } finally {
    if (client && instance && ownsControl && !options.observeOnly) {
      try {
        // Query the same identity before final shutdown; never stop a replacement runtime.
        await control('shutdown');
        await waitFor('shutdown', options.shutdownTimeoutMs, retirementConfirmed, true);
        result.shutdownConfirmed = retirementConfirmed(state);
        result.shutdownStatus = result.shutdownConfirmed ? 'CONFIRMED' : 'UNCONFIRMED';
      } catch (error) {
        result.errors.push({ code: safeCode(error), phase: 'shutdown', completionInferred: false });
        result.shutdownConfirmed = false;
        result.shutdownStatus = error.code === 'ERR_MEASURE_FOREIGN_JOB' ? 'UNCONFIRMED_FOREIGN_JOB' : 'UNCONFIRMED';
      }
      if (!result.shutdownConfirmed && result.status.startsWith('PASS_')) result.status = 'INCOMPLETE';
    }
    if (witnessPhase && result.witness) {
      result.witnessCleanCheckpoint = result.shutdownConfirmed && cleanCheckpointConfirmed(state) &&
        state.persistentInstanceId === result.persistentInstanceId && state.bootMode === result.bootMode;
      if (!result.witnessCleanCheckpoint) {
        result.errors.push({ code: 'ERR_MEASURE_WITNESS_CHECKPOINT', completionInferred: false });
        if (result.status.startsWith('PASS_')) result.status = 'INCOMPLETE';
      }
      if (previous && result.witnessComparison) {
        result.resumeConfirmed = result.witnessCleanCheckpoint && state.instanceId !== previous.instanceId &&
          state.retirement.guestClose.epoch !== previous.guestClose.epoch;
        if (!result.resumeConfirmed) {
          result.errors.push({ code: 'ERR_MEASURE_RESUME_CHECKPOINT', completionInferred: false });
          if (result.status.startsWith('PASS_')) result.status = 'INCOMPLETE';
        }
      }
    }
    result.finalStatus = lastSaved ?? null;
    result.outputWithheld = evidence.outputWithheld;
    result.elapsedMs = evidence.ms();
    client?.close();
    process.off('SIGINT', interrupted); process.off('SIGTERM', interrupted);
    await fs.writeFile(path.join(options.out, 'SUMMARY.json'), JSON.stringify(result, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  }
  return result;
}

function number(values, key, fallback, maximum) {
  const value = values[key] === undefined ? fallback : Number(values[key]);
  if (!Number.isSafeInteger(value) || value < 10 || value > maximum) throw fail('ERR_MEASURE_ARGUMENT');
  return value;
}

async function main() {
  const { values } = parseArgs({ options: {
    'base-url': { type: 'string' }, 'token-file': { type: 'string' }, 'env-file': { type: 'string' }, out: { type: 'string' },
    'proxy-file': { type: 'string' }, 'resume-from': { type: 'string' }, 'write-witness': { type: 'boolean', default: false },
    'gh-repo': { type: 'string' }, 'clone-url': { type: 'string' },
    'observe-only': { type: 'boolean', default: false }, 'gh-pr-list': { type: 'boolean', default: false }, help: { type: 'boolean', default: false },
    'poll-ms': { type: 'string' }, 'request-timeout-ms': { type: 'string' }, 'install-timeout-ms': { type: 'string' },
    'job-timeout-ms': { type: 'string' }, 'shutdown-timeout-ms': { type: 'string' },
  }, strict: true });
  if (values.help) {
    process.stdout.write('用法：node tooling/ohos/linux-device-measure.mjs --base-url http://127.0.0.1:PORT --token-file TOKEN_FILE --out NEW_DIRECTORY [--proxy-file PRIVATE_JSON] [--write-witness | --resume-from PREVIOUS_SUMMARY] [--clone-url https://HOST/REPO.git] [--gh-pr-list --gh-repo OWNER/REPO --env-file JSON_FILE] [--observe-only]\n');
    return;
  }
  if (!values['base-url'] || !values['token-file'] || !values.out) throw fail('ERR_MEASURE_ARGUMENT');
  if (values['observe-only'] && values['gh-pr-list']) throw fail('ERR_MEASURE_ARGUMENT');
  if (values['write-witness'] && values['resume-from'] || values['observe-only'] && (values['proxy-file'] || values['write-witness'] || values['resume-from'])) throw fail('ERR_MEASURE_ARGUMENT');
  const result = await measure({ baseUrl: values['base-url'], tokenFile: values['token-file'], envFile: values['env-file'], out: path.resolve(values.out),
    ghRepo: values['gh-repo'], cloneUrl: values['clone-url'],
    proxyFile: values['proxy-file'], writeWitness: values['write-witness'], resumeFrom: values['resume-from'],
    observeOnly: values['observe-only'], ghPrList: values['gh-pr-list'], pollMs: number(values, 'poll-ms', 250, 10000),
    requestTimeoutMs: number(values, 'request-timeout-ms', 5000, 60000), installTimeoutMs: number(values, 'install-timeout-ms', 600000, 3600000),
    jobTimeoutMs: number(values, 'job-timeout-ms', 120000, 3600000), shutdownTimeoutMs: number(values, 'shutdown-timeout-ms', 180000, 3600000) });
  process.stdout.write(JSON.stringify({ status: result.status, cases: result.cases.map(({ label, status }) => ({ label, status })),
    shutdownConfirmed: result.shutdownConfirmed, report: path.join(path.resolve(values.out), 'SUMMARY.json') }) + '\n');
  process.exitCode = result.interruptionRequested ? 130 : result.status.startsWith('PASS_') || result.status === 'OBSERVED_ONLY' ? 0 : result.status === 'FAIL' ? 1 : 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { process.stderr.write(safeCode(error) + '\n'); process.exitCode = 2; });
}
