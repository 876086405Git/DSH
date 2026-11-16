import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { deriveLinuxJobDiagnostic } from '../../ohos/linux/job-diagnostics.mjs';

const wire = value => {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value);
  return { encoding: 'base64', data: bytes.toString('base64'), totalBytes: bytes.length, retainedBytes: bytes.length, truncated: false };
};
const failed = (value, more = {}) => ({ state: 'settled', outcome: { exitCode: 128, signal: null, cancelled: false }, stderr: wire(value), ...more });
const tls = await readFile(new URL('./fixtures/linux-job-diagnostics/phone930-github.stderr', import.meta.url));
const success = await readFile(new URL('./fixtures/linux-job-diagnostics/phone930-gitee.stderr', import.meta.url));

test('unchanged device Git stderr identifies reported TLS interruption, retaining its exact SHA', () => {
  assert.equal(tls.length, 225);
  assert.equal(createHash('sha256').update(tls).digest('hex'), '972e8f182b0dfaef685ad478937dec8b7839bf48b3400178526b1b5b28c47930');
  const input = failed(tls), before = JSON.stringify(input), result = deriveLinuxJobDiagnostic(input);
  assert.equal(result.category, 'tls-interrupted'); assert.equal(result.evidence, 'stderr');
  assert.match(result.message, /输出提示 TLS 连接被中途断开/); assert.match(result.message, /无法判断断开方/);
  assert.equal(JSON.stringify(input), before); assert.equal(Object.isFrozen(result), true);
});

test('unchanged successful Gitee stderr remains success even though clone wrote stderr', () => {
  assert.equal(createHash('sha256').update(success).digest('hex'), 'e601b48e46baecf6dc76ef1f28720fd60c42f542fe9c684db7e105911ebf892e');
  assert.equal(deriveLinuxJobDiagnostic(failed(success, { outcome: { exitCode: 0, signal: null, cancelled: false } })), null);
});

// The following are deliberately synthetic diagnostic strings. They cover
// classification boundaries; they do not claim these network faults occurred.
for (const [name, text, category] of [
  ['Git host lookup failure', 'fatal: unable to access: Could not resolve host: fixture.invalid', 'dns'],
  ['Git proxy lookup failure', 'Could not resolve proxy: proxy.invalid', 'dns'],
  ['Go DNS failure', 'dial tcp: lookup fixture.invalid on 10.0.2.3:53: no such host', 'dns'],
  ['Python name lookup failure', 'socket.gaierror: [Errno -2] Name or service not known', 'dns'],
  ['TCP refusal', 'dial tcp 192.0.2.1:443: connect: connection refused', 'connection'],
  ['connect timeout', 'Failed to connect to fixture.invalid port 443: Connection timed out', 'connection'],
  ['no route', 'connect: no route to host', 'connection'],
  ['certificate verification', 'SSL certificate problem: unable to get local issuer certificate', 'tls-certificate'],
  ['Go certificate verification', 'x509: certificate signed by unknown authority', 'tls-certificate'],
]) test(name + ' is a hint from complete stderr, including non-128 exits', () => {
  const result = deriveLinuxJobDiagnostic(failed(text, { outcome: { exitCode: 1, signal: null, cancelled: false } }));
  assert.equal(result.category, category); assert.equal(result.evidence, 'stderr');
});

test('exit 128 by itself and unrelated failures are not called network errors', () => {
  for (const text of ['', 'fatal: not a git repository', 'PermissionError: [Errno 13] Permission denied', 'fatal: remote error: repository not found']) {
    const result = deriveLinuxJobDiagnostic(failed(text)); assert.equal(result.category, 'unknown'); assert.equal(result.evidence, 'none');
  }
});

test('an unqualified unexpected EOF is not evidence of a TLS interruption', () => {
  assert.equal(deriveLinuxJobDiagnostic(failed('unexpected EOF')).category, 'unknown');
});

test('conflicting complete stderr categories remain unknown', () => {
  assert.equal(deriveLinuxJobDiagnostic(failed('Could not resolve host: fixture.invalid\n' + tls.toString())).category, 'unknown');
  assert.equal(deriveLinuxJobDiagnostic(failed('SSL certificate problem\n' + tls.toString())).category, 'unknown');
});

test('success, cancelled SIGKILL, other signals and not-started work do not become a network failure', () => {
  for (const outcome of [
    { exitCode: 0, signal: null, cancelled: false },
    { exitCode: null, signal: 'SIGKILL', cancelled: true, requestedSignal: 'SIGTERM' },
    { exitCode: null, signal: 'SIGTERM', cancelled: false },
    { exitCode: 128, signal: null, cancelled: true },
    { exitCode: 128, signal: null, cancelled: false, notStarted: true },
  ]) assert.equal(deriveLinuxJobDiagnostic(failed(tls, { outcome })), null);
});

test('unknown and live lifecycle states cannot be repaired by error text', () => {
  for (const state of ['queued', 'running', 'unknown', undefined]) assert.equal(deriveLinuxJobDiagnostic(failed(tls, { state })), null);
  assert.equal(deriveLinuxJobDiagnostic(failed(tls, { outcome: null })), null);
});

test('matching truncated tails, including a falsely small total, remain unknown', () => {
  const input = failed(tls);
  for (const more of [{ truncated: true }, { truncated: true, totalBytes: 20000 }, { totalBytes: 20000 }]) {
    assert.equal(deriveLinuxJobDiagnostic({ ...input, stderr: { ...input.stderr, ...more } }).category, 'unknown');
  }
});

test('malformed byte metadata, noncanonical base64 and invalid UTF8 cannot produce a hint', () => {
  const input = failed(tls);
  for (const more of [{ retainedBytes: tls.length - 1 }, { totalBytes: tls.length + 1 }, { encoding: 'utf8' },
    { data: input.stderr.data + '\n' }, { data: input.stderr.data.slice(0, -1) }, { totalBytes: -1 }, { truncated: undefined }]) {
    assert.equal(deriveLinuxJobDiagnostic({ ...input, stderr: { ...input.stderr, ...more } }).category, 'unknown');
  }
  assert.equal(deriveLinuxJobDiagnostic(failed(Buffer.concat([tls, Buffer.from([255])]))).category, 'unknown');
});

test('stdout is never used to infer a failure category', () => {
  assert.equal(deriveLinuxJobDiagnostic({ ...failed(''), stdout: wire(tls) }).category, 'unknown');
});

test('a credential-like synthetic URL cannot be returned in a diagnostic', () => {
  const synthetic = 'synthetic-test-user:synthetic-test-password';
  const input = failed('fatal: unable to access https://' + synthetic + '@fixture.invalid/: TLS connect error: error:0A000126:SSL routines::unexpected eof while reading');
  const result = deriveLinuxJobDiagnostic(input);
  assert.equal(result.category, 'tls-interrupted');
  assert.deepEqual(Object.keys(result).sort(), ['category', 'evidence', 'message']);
  assert.equal(JSON.stringify(result).includes(synthetic), false);
  assert.equal(JSON.stringify(result).includes('fixture.invalid'), false);
});
