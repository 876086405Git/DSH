import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { closeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [directory, config, sourcePath, mode, closeFailure] = process.argv.slice(2);
const temp = await mkdtemp(join(tmpdir(), 'waker-adoption-'));
let debt;
try {
  let source = await readFile(sourcePath, 'utf8');
  assert.equal(source.split("import { Socket } from 'node:net';").length, 2);
  source = source.replace("import { Socket } from 'node:net';", "import { Socket } from './net-fixture.mjs';");
  if (closeFailure === 'yes') source = source.replace("import { closeSync } from 'node:fs';", "import { closeSync } from './close-fixture.mjs';");
  await writeFile(join(temp, 'native-session.mjs'), source);
  await writeFile(join(temp, 'net-fixture.mjs'), 'export class Socket { constructor() { throw Object.assign(new Error("explicit adoption boundary"), {code:"TEST_ADOPTION"}); } }');
  await writeFile(join(temp, 'close-fixture.mjs'), 'export function closeSync() { throw Object.assign(new Error("explicit close boundary"), {code:"TEST_CLOSE"}); }');
  const { loadLinuxNative } = await import(pathToFileURL(join(temp, 'native-session.mjs')));
  const native = loadLinuxNative({ nativeLibraryDirectory: directory });
  let caught; try { native.create(config); } catch (cause) { caught = cause; }
  assert.equal(caught.code, 'TEST_ADOPTION'); assert.ok(caught.linuxJoin instanceof Promise);
  if (closeFailure === 'yes') {
    assert.equal(caught.linuxFdCloseError.code, 'TEST_CLOSE');
    assert.ok(Number.isInteger(caught.linuxUnsettledFd)); debt = caught.linuxUnsettledFd;
  } else assert.equal(caught.linuxUnsettledFd, undefined);
  let result;
  if (mode === 'reference-fail') await assert.rejects(caught.linuxJoin, { code: 'ERR_OHOS_LINUX_JOIN' });
  else {
    result = await caught.linuxJoin;
    assert.equal(result.joined, false); assert.equal(result.joinAttempted, false); assert.equal(result.joinError, null);
    assert.equal(result.apiResult, null); assert.equal(result.ramRetirement, null); assert.equal(result.fdRetirement, null);
    assert.equal(result.stopNotification.errorCode, 5);
  }
  assert.throws(() => native.create(config), { code: 'ERR_OHOS_LINUX_OWNER_QUARANTINED' });
  console.log(JSON.stringify({ originalCause: caught.code, mode, closeFailure, joinRejected: mode === 'reference-fail', result }));
} finally {
  if (debt !== undefined) closeSync(debt);
  await rm(temp, { recursive: true, force: true });
}
