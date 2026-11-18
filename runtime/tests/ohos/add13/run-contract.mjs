import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

export async function runAdd13Contract({ base, cookie, exchange, out, server, expectation, stdioMarker }) {
  const directory = join(out, 'add13');
  await mkdir(directory);
  const report = { status: 'RUNNING', expectation, startedUtc: new Date().toISOString(), responses: [],
    scope: 'Actual Host registry and product-preloaded child APIs; HTTP MCP registered definitions, not a new agent ToolRuntime approval scenario' };
  const request = async (name, path, body) => {
    const response = await exchange(new URL(path, base), { cookie, body });
    const bytes = Buffer.from(response.text);
    const file = `${String(report.responses.length + 1).padStart(2, '0')}-${name}.bin`;
    await writeFile(join(directory, file), bytes, { flag: 'wx' });
    const entry = { name, path, method: body === undefined ? 'GET' : 'POST', authenticated: true,
      requestBody: body, status: response.status, responseHeaders: response.headers,
      file, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
    report.responses.push(entry);
    assert.equal(response.status, 200, `${name} must succeed through the owned authenticated route`);
    return JSON.parse(response.text);
  };
  const statusUntil = async predicate => {
    const deadline = Date.now() + 5000;
    let result;
    do {
      result = await request('status', '/__add13_mcp/status');
      if (predicate(result)) return result;
      await new Promise(resolve => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    throw new Error('Actual Host MCP observation deadline exceeded');
  };
  try {
    const cp = await request('child-process', '/__add13_cp/run', {});
    report.childProcess = cp;
    assert.equal(cp.platform, 'openharmony');
    assert.equal(cp.node, 'v24.22.1');
    assert.equal(cp.mainThread, true);
    assert.equal(cp.noWasm, true);
    assert.ok(cp.execArgv.includes('--jitless'));
    assert.equal(cp.cases.length, 12);
    for (const checks of Object.values(cp.aliases)) for (const value of Object.values(checks)) assert.equal(value, true);
    for (const item of cp.cases) {
      if (expectation === 'existing') {
        assert.equal(item.error, undefined, item.id);
        assert.equal(item.creationReturned, true, item.id);
        assert.equal(item.marker?.parsed.id, item.id);
        assert.equal(item.result.stdout.text, `ADD13_CHILD:${item.id}\n`);
        if (Object.hasOwn(item.result, 'code')) { assert.equal(item.result.code, 0); assert.equal(item.result.signal, null); }
        assert.ok(!item.result.requested?.length, item.id);
      } else {
        assert.equal(item.creationReturned, false, item.id);
        assert.equal(item.error?.code, 'ERR_OHOS_NO_SPAWN', item.id);
        assert.equal(item.marker, null, item.id);
      }
    }
    report.childProcessStatus = expectation === 'existing' ? 'BEFORE_OS_CREATION_GAP_CONFIRMED' : 'PRODUCT_GUARD_REFUSED_ALL_12';
    assert.equal(cp.ordinaryWorkerExit.code, 0);
    assert.equal(cp.ordinaryWorkerError, undefined);
    assert.equal(cp.ordinaryWorker.platform, 'openharmony');
    assert.equal(cp.ordinaryWorker.mainThread, false);
    assert.equal(cp.ordinaryWorker.noWasm, true);
    if (expectation === 'existing') {
      assert.equal(cp.ordinaryWorker.error, undefined);
      assert.equal(cp.ordinaryWorker.childExit.code, 0);
      assert.equal(cp.ordinaryWorker.childExit.signal, null);
      assert.equal(cp.ordinaryWorker.marker?.id, 'ordinary-worker');
    } else {
      assert.equal(cp.ordinaryWorker.error?.code, 'ERR_OHOS_NO_SPAWN');
      assert.equal(cp.ordinaryWorker.marker, null);
    }
    const initial = await statusUntil(value => ['mcp__add13_http__echo', 'mcp__add13_http__hold'].every(name => value.tools.includes(name)));
    report.initialInventory = initial.inventory;
    const message = 'ADD13 Host 中文 echo';
    const echo = await request('echo', '/__add13_mcp/echo', { message });
    assert.deepEqual(echo.result.structuredContent, { fixture: 'add13-owned-http', received: message });
    assert.deepEqual(echo.result.content, [{ type: 'text', text: JSON.stringify(echo.result.structuredContent) }]);
    report.echo = echo;
    const hold = await request('hold', '/__add13_mcp/hold', { message: 'cancel registered MCP request' });
    const opened = await server.waitFor(row => row.type === 'hold-open');
    report.cancelRequested = { utc: new Date().toISOString(), monotonicNs: process.hrtime.bigint().toString(), afterServerSequence: opened.sequence };
    const cancelled = await request('cancel', '/__add13_mcp/cancel', { id: hold.id });
    assert.deepEqual(cancelled, { requested: true, id: hold.id });
    const closed = await server.waitFor(row => row.type === 'hold-closed' && row.request === opened.request);
    const settled = await statusUntil(value => value.jobs.some(job => job.id === hold.id && job.state === 'rejected'));
    assert.equal(closed.fixtureClosing, false);
    assert.ok(BigInt(closed.monotonicNs) >= BigInt(report.cancelRequested.monotonicNs), 'Server close must follow the explicit owner cancellation');
    assert.equal(server.activeHolds(), 0);
    report.cancellation = { opened, closed, job: settled.jobs.find(job => job.id === hold.id) };
    // This fixed interval spans more than the unchanged default first retry delay (500 ms).
    // Source review, not this interval alone, establishes the new permanent-failure branch.
    report.quietWindow = { startedUtc: new Date().toISOString(), milliseconds: 1200 };
    await new Promise(resolve => setTimeout(resolve, 1200));
    report.quietWindow.endedUtc = new Date().toISOString();
    const final = await request('final-status', '/__add13_mcp/status');
    const stdio = final.inventory.entries.find(entry => entry.entryId === 'include:add13-stdio');
    const http = final.inventory.entries.find(entry => entry.entryId === 'include:add13-http');
    report.stdioInventory = stdio;
    report.httpInventory = http;
    assert.ok(stdio && http);
    assert.equal(http.fiberPhase, 'active');
    assert.equal(stdio.fiberPhase, 'active');
    let marker = '';
    try { marker = await readFile(stdioMarker, 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    report.stdioProcessMarkers = marker.trim() ? marker.trim().split('\n').map(line => JSON.parse(line)) : [];
    if (expectation === 'guard-only') assert.equal(report.stdioProcessMarkers.length, 0);
    else assert.ok(report.stdioProcessMarkers.length > 0, 'SDK must actually start the owned peer');
    if (expectation === 'complete') {
      assert(report.stdioProcessMarkers.every(row => row.worker === true));
      const stdioEcho = await request('stdio-echo', '/__add13_mcp/stdio-echo', { message: '真实 stdio MCP' });
      assert.deepEqual(stdioEcho.result.content, [{ type: 'text', text: '真实 stdio MCP' }]);
      report.stdioEcho = stdioEcho;
    }
    assert.equal(server.events.some(row => row.type === 'fixture-error'), false);
    report.httpMethods = server.events.filter(row => row.type === 'rpc').map(row => row.method);
    assert.ok(report.httpMethods.includes('server/discover'));
    assert.ok(report.httpMethods.includes('tools/list'));
    assert.ok(report.httpMethods.filter(method => method === 'tools/call').length >= 2);
    report.status = expectation === 'existing' ? 'BEFORE_GAP_OBSERVED_HTTP_FUNCTIONAL' : expectation === 'guard-only' ? 'GUARD_ONLY_MCP_STATE_OBSERVED_HTTP_FUNCTIONAL' : 'PASS_SCOPED_ADD13_HOST';
    return report;
  } catch (error) {
    report.status = 'FAIL';
    report.error = { name: error.name, code: error.code, message: error.message, stack: error.stack };
    throw error;
  } finally {
    report.endedUtc = new Date().toISOString();
    await writeFile(join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
  }
}
