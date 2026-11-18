// Drives thirteen real approval/guest rounds on the iOS Simulator, including
// denial, per-call root grants, cancellation and persisted approval records.
// The synthetic model chooses tools; the production approval chain decides them.
//
//   node guest-drive.mjs --simulator <udid> --smoke <binary> --frameworks <dir> --runtime <tree> \
//     --work <new dir> --ws <dir holding the ws package>
//
// The Simulator shares this Mac's filesystem and loopback, which is what makes this work.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import http from 'node:http';
import { appendFileSync, cpSync, existsSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs';
import { readFile, stat, rm } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { startGuestModel } from './guest-model.mjs';
import assert from 'node:assert/strict';
import {verifyApproval,verifyAudit} from './guest-assertions.mjs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { BoundedLineDecoder, createGuestDiagnostics, diagnosticError, diagnosticLimits,
  observeMux, safeError, safeScenario, safeTool } from './guest-diagnostics.mjs';

async function main() {
  let cleanup = async () => {};
  try {

    const { values } = parseArgs({ options: { ...Object.fromEntries(
      ['simulator', 'smoke', 'frameworks', 'runtime', 'work', 'ws', 'rootfs'].map((name) => [name, { type: 'string' }])),
      direct: { type: 'boolean', default: false },
    } });
    for (const name of [...(values.direct ? [] : ['simulator']), 'smoke', 'frameworks', 'runtime', 'work', 'ws', 'rootfs']) {
      if (!values[name]) throw new Error(`--${name} is required`);
    }
    const repo = fileURLToPath(new URL('../../..', import.meta.url));
    const { WebSocket } = createRequire(join(resolve(values.ws), 'package.json'))('ws');

    const work = resolve(values.work);
    mkdirSync(work);
    const guest = realpathSync(work) + '/guest';
    const dshHome = `${guest}/root/.dsh`;
    const workspace = `${guest}/root/workspace`;
    const cache = realpathSync(work) + '/cache';
    for (const directory of [dshHome, `${guest}/root/.agents`, workspace, cache]) mkdirSync(directory, { recursive: true });

    const logFile = join(work, 'engine.log');
    const report = { status: 'BLOCKED', stage: 'startup', approvals: 0, restart: 'not-run', eventTypes: [], scenarios: [] };
    const fail = kind => { throw diagnosticError(kind); };
    const diagnostics = createGuestDiagnostics({ writeLog: line => appendFileSync(logFile, line) });

    const model = await startGuestModel(workspace);
    cleanup = () => model.close();
    // Trusted test host only: rootfs was published by the production Swift installer.
    const rootfs = realpathSync(values.rootfs);
    const marker = JSON.parse(await readFile(join(rootfs, 'installed.json'), 'utf8'));
    assert.equal(marker.version, '3.24.4');
    assert.equal(marker.archiveSHA256, '4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de');
    for (const name of ['data', 'meta.db']) assert.ok(existsSync(join(rootfs, name)));
    const guestTemporary=join(work,'guest-tmp');mkdirSync(guestTemporary,{mode:0o700});
    const snapshot = join(work, 'guest-config.json');
    writeFileSync(snapshot, JSON.stringify({ installed: true, root: rootfs, temporaryRoot: guestTemporary,
      addon: join(realpathSync(values.frameworks), 'DshGuestBridge.framework/DshGuestBridge'),
      protectedPaths: [dshHome, `${guest}/root/.agents`, cache, rootfs, realpathSync(values.runtime)],
      metadata: {v:1,source:'ios-native-owner',state:'ready',installed:'present',available:true,enforcement:'partial',python:'unknown'}
    }));

    const overlay = join(work, 'model.patch.yml');
    writeFileSync(overlay, JSON.stringify([
      { id: 'llm-pi-ai', config: { providers: { 'ohos-fake': {
        api: 'openai-completions', baseURL: model.baseURL, apiKeyEnv: 'DSH_OHOS_TEST_KEY',
        retryPolicy: { mode: 'normal', maxRetries: 0 },
        models: [{ id: 'ohos-script', contextWindow: 32768, maxTokens: 4096, reasoningEfforts: false }],
      } } } },
      { id: 'agent-default-model', config: { provider: 'ohos-fake', model: 'ohos-script' } },
      { id: 'session-title-llm', disabled: true },
    ]));

    const smokeArgs = [resolve(values.frameworks), resolve(values.runtime), guest, cache, snapshot];
    const engine = spawn(values.direct ? resolve(values.smoke) : 'xcrun', values.direct ? smokeArgs :
      ['simctl', 'spawn', values.simulator, resolve(values.smoke), ...smokeArgs], {
      env: {
        ...process.env,
        DSH_IOS_SMOKE_PATCH: overlay,
        SIMCTL_CHILD_DSH_IOS_SMOKE_PATCH: overlay,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let exited = null;
    let engineEnded = null;
    let restarting = false;
    const readyWaiters = [];
    const readies = [];
    let childClosed = false;
    let resolveExit, resolveClose;
    const exitDone = new Promise(resolve => { resolveExit = resolve; });
    const closeDone = new Promise(resolve => { resolveClose = resolve; });
    const stdoutLines = new BoundedLineDecoder(diagnosticLimits.hostJsonLineBytes, line => {
      if (line === '[]' || line === '') return;
      let rows;
      try { rows = JSON.parse(line); } catch { diagnostics.hostInvalid(); return; }
      for (const row of Array.isArray(rows) ? rows : [rows]) {
        diagnostics.hostRecord(row, row?.kind === 'exit' && restarting);
        if (!row || typeof row !== 'object') continue;
        if (row.kind === 'ready') {
          // The launch token stays in this private transport state, never the report.
          readies.push(row);
          for (const waiter of readyWaiters.splice(0)) waiter();
        } else if (row.kind === 'exit' && restarting) restarting = false;
        else if (row.kind === 'exit' || row.kind === 'error' || row.kind === 'fatal') {
          engineEnded = row;
          for (const waiter of readyWaiters.splice(0)) waiter();
        }
      }
    }, () => diagnostics.hostInvalid(true));
    engine.stderr.on('data', data => diagnostics.childStderr(data));
    engine.stderr.on('end', () => diagnostics.childStderrEnd());
    engine.stdout.on('data', data => stdoutLines.write(data));
    engine.stdout.on('end', () => { stdoutLines.end(); diagnostics.hostStdoutEnd(); });
    engine.on('error', error => {
      exited = { failed: true }; diagnostics.childError(error); resolveExit();
      for (const waiter of readyWaiters.splice(0)) waiter();
    });
    engine.on('exit', (code, signal) => {
      exited = { code, signal }; diagnostics.childExit(code, signal); resolveExit();
      for (const waiter of readyWaiters.splice(0)) waiter();
    });
    engine.on('close', () => { childClosed = true; diagnostics.stdioClosed(); resolveClose(); });
    let cleanupPromise;
    cleanup = () => cleanupPromise ??= (async () => {
      diagnostics.freezeBeforeCleanup();
      if (!exited) {
        diagnostics.markCleanup('quit');
        try { writeFileSync(`${guest}/quit`, ''); }
        catch (error) { diagnostics.failure('cleanup-error', error); report.status = 'BLOCKED'; }
        await Promise.race([exitDone, delay(20000)]);
        if (!exited) {
          diagnostics.markCleanup('kill');
          try { engine.kill(); }
          catch (error) { diagnostics.failure('cleanup-error', error); report.status = 'BLOCKED'; }
        }
      }
      // exit can precede the final stderr/end/close notifications. An incomplete
      // line at the bounded drain deadline remains withheld and marked incomplete.
      if (!childClosed) await Promise.race([closeDone, delay(2000)]);
      try { await model.close(); }
      catch (error) { diagnostics.failure('cleanup-error', error); report.status = 'BLOCKED'; }
    })();

    async function waitReady(index, ms) {
      const deadline = Date.now() + ms;
      while (readies.length <= index) {
        if (exited) fail('engine-exit');
        if (engineEnded) fail('engine-event');
        if (Date.now() > deadline) fail('readiness-timeout');
        await Promise.race([new Promise((done) => readyWaiters.push(done)), new Promise((done) => setTimeout(done, 1000))]);
      }
      return readies[index];
    }

    function exchange(url, { body, cookie } = {}) {
      return new Promise((accept, reject) => {
        const bytes = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
        const req = http.request(url, {
          method: bytes ? 'POST' : 'GET', headers: {
            ...(cookie ? { Cookie: cookie } : {}),
            ...(bytes ? { 'content-type': 'application/json', 'content-length': bytes.length } : {}),
          },
        }, (res) => {
          const chunks = [];
          res.on('data', (data) => chunks.push(data));
          res.on('end', () => accept({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
          res.on('error', reject);
        });
        req.on('error', reject);
        req.setTimeout(60000, () => req.destroy(diagnosticError('http-timeout')));
        req.end(bytes);
      });
    }

    async function login(ready, diagnostic) {
      const response = await exchange(`${ready.baseUrl}/?token=${encodeURIComponent(ready.token)}`);
      if (response.status !== 303) {
        diagnostic.serverError('rpc-http', undefined, 'launch', response.status);
        throw diagnostic.fail('launch-http');
      }
      const cookie = response.headers['set-cookie']?.find((item) => item.startsWith('dsh-auth-'))?.split(';')[0];
      if (!cookie) throw diagnostic.fail('launch-cookie');
      const rpc = async (endpoint, args = {}) => {
        const rpcId = randomUUID();
        const reply = await exchange(new URL(`/api/${endpoint}`, ready.baseUrl), {
          cookie, body: { type: 'client-request', rpcId, method: endpoint, payload: { args } },
        });
        if (reply.status !== 200) {
          diagnostic.serverError('rpc-http', undefined, endpoint, reply.status);
          throw diagnostic.fail('rpc-http');
        }
        let wire;
        try { wire = JSON.parse(reply.text); } catch { throw diagnostic.fail('rpc-envelope'); }
        if (!wire || wire.rpcId !== rpcId || wire.type !== 'server-response') throw diagnostic.fail('rpc-envelope');
        if (wire.result?.ok !== true) {
          diagnostic.serverError('rpc', wire.result?.error, endpoint);
          throw diagnostic.fail('rpc-error', wire.result?.error);
        }
        return wire.result.value;
      };
      return { cookie, rpc };
    }

    async function round(ready, mode, reuse) {
      const diagnostic = diagnostics.startRound(mode), frames = [], events = [], waiters = new Set();
      let clientId, sessionId, approval, socket;
      const rejectWaiters = error => { for (const waiter of [...waiters]) waiter.reject(error); };
      function waitFrame(predicate) {
        if (diagnostic.error) return Promise.reject(diagnostic.error);
        const found=frames.find(predicate);if(found)return Promise.resolve(found);
        return new Promise((resolve,reject)=>{
          const w={predicate,accept(f){clearTimeout(w.timer);waiters.delete(w);resolve(f);},reject(e){clearTimeout(w.timer);waiters.delete(w);reject(e);}};
          w.timer=setTimeout(()=>w.reject(diagnostic.fail('mux-timeout')),120000);waiters.add(w);
        });
      }
      try {
        const { cookie, rpc } = await login(ready, diagnostic);
        diagnostic.setPhase('opening_mux');
        socket = new WebSocket(ready.baseUrl.replace('http:','ws:')+'/api/remote.mux',{headers:{Cookie:cookie},handshakeTimeout:30000});
        observeMux(socket, diagnostic, { onFailure: rejectWaiters, onFrame(frame) {
          frames.push(frame);
          if (frame.value?.type === 'event') events.push(frame.value.event);
          for (const waiter of [...waiters]) if (waiter.predicate(frame)) waiter.accept(frame);
        } });
        await once(socket,'open',{signal:AbortSignal.timeout(30000)});
        diagnostic.setPhase('host_ready');
        socket.send(JSON.stringify({type:'open',streamId:'host',endpoint:'$events',payload:{args:{}}}));
        clientId=(await waitFrame(f=>f.streamId==='host'&&f.value?.type==='ready')).value.clientId;
        diagnostic.setPhase('session_create');
        sessionId=reuse??(await rpc('session/create',{request:{cwd:workspace,agentPreset:'standard'}})).sessionId;
        diagnostic.setPhase('session_snapshot');
        socket.send(JSON.stringify({type:'open',streamId:'session',endpoint:'session/follow',payload:{args:{request:{address:{kind:'session',sessionId},assistantDeltas:true}}}}));
        await waitFrame(f=>f.streamId==='session'&&f.value?.type==='snapshot');
        report.stage=mode;
        diagnostic.setPhase('prompt');
        const receipt=await rpc('session/prompt',{request:{requestId:randomUUID(),sessionId,mode:'queue',content:[{type:'text',text:`[DSH_IOS_SMOKE:${mode}] Run the one deterministic guest fixture tool.`}]}});
        assert.equal(receipt.accepted,true);
        diagnostic.setPhase('prompt_accepted');
        diagnostic.setPhase('waiting_approval');
        approval=(await waitFrame(f=>f.value?.type==='waterfall'&&f.value.event==='approval/request')).value;
        verifyApproval(approval,sessionId,model.calls.get(mode));
        assert.equal(existsSync(join(workspace,'deny-marker')),false);
        if(mode==='identity')assert.equal(existsSync(join(workspace,'中文 标记.txt')),false);
        if(mode==='cancel')assert.equal(existsSync(join(workspace,'ready')),false);
        if(mode==='exit'||mode==='after')assert.equal(existsSync(join(workspace,mode+'-marker')),false);
        const decision=mode==='deny'?'rejected':'allowed-once';
        diagnostic.setPhase('approval_result');
        await rpc('$events/result',{clientId,eventId:approval.eventId,outcome:{kind:'result',value:decision}});
        report.approvals++;
        const decisions=[decision];
        if(mode==='rootdeny'||mode==='rootallow') {
          diagnostic.setPhase('root_approval');
          const root=(await waitFrame(f=>f.value?.type==='waterfall'&&f.value.event==='approval/request'&&f.value.eventId!==approval.eventId)).value;
          verifyApproval(root,sessionId,model.calls.get(mode));
          assert.match(root.request.reason,/Linux/);
          const rootDecision=mode==='rootdeny'?'rejected':'allowed-once';
          diagnostic.setPhase('approval_result');
          await rpc('$events/result',{clientId,eventId:root.eventId,outcome:{kind:'result',value:rootDecision}});
          decisions.push(rootDecision);report.approvals++;
        }
        if(mode==='cancel') {
          diagnostic.setPhase('cancel_wait');
          const until=Date.now()+60000;
          while(!existsSync(join(workspace,'ready'))) {
            if(diagnostic.error)throw diagnostic.error;if(Date.now()>until)throw diagnosticError('guest-readiness-timeout');await delay(25);
          }
          diagnostic.setPhase('cancel_request');
          await rpc('session/cancel',{request:{sessionId}});
        }
        diagnostic.setPhase('waiting_turn_end');
        const end=(await waitFrame(f=>f.streamId==='session'&&f.value?.event?.type==='turn/end')).value.event;
        diagnostic.setPhase('verify_result');
        assert.equal(end.data.reason?.kind,mode==='cancel'?'aborted':'completed');
        const results=events.filter(e=>e.type==='tool/result');
        if(mode!=='cancel')assert.equal(results.length,1);
        for(const event of results)assert.equal(event.data.message?.source?.callId,approval.request.callId);
        const text=results.flatMap(e=>e.data.message?.content??[]).map(part=>part.text??'').join('\n');
        if(mode==='deny'){assert.equal(existsSync(join(workspace,'deny-marker')),false);assert.ok(/reject|denied|拒绝|未批准/i.test(text),'deny result must report refusal');}
        if(mode==='identity'){
          assert.match(text,/Linux/);assert.match(text,/(?:^|\n)3\.24\.4(?:\r?\n|$)/);assert.equal(await readFile(join(workspace,'中文 标记.txt'),'utf8'),'guest-ok');
          assert.ok(text.includes('python3=absent')||text.includes('python3=present:2'),'optional Python observation missing');
          assert.equal(results[0].data.message.isError,false);
        }
        if(mode==='osrelease'||mode==='pipeline')assert.match(text,/(?:^|\n)ID=alpine(?:\r?\n|$)/);
        if(mode==='apkpath')assert.match(text,/\/sbin\/apk(?:\r?\n|$)/);
        if(mode==='full')assert.match(text,/apk-tools/);
        if(mode==='rootdeny')assert.ok(/reject|denied|拒绝|未批准/i.test(text),'root denial must report refusal');
        if(mode==='rootreadonly'||mode==='rootafter') {
          assert.match(text,/Read-only file system/i);
          assert.match(text,mode==='rootreadonly'?/root-readonly/:/root-readonly-again/);
          assert.equal(results[0].data.message.isError,false);
        }
        if(mode==='rootallow') {
          assert.match(text,/approved/);assert.equal(results[0].data.message.isError,false);
        }
        if(mode==='exit')assert.match(text,/\[exit code: 7\]/);
        if(mode==='after')assert.match(text,/guest-after-cancel/);
        if(mode==='cancel'){
          const heartbeat=join(workspace,'heartbeat');await delay(300);
          const before=(await stat(heartbeat)).size;await delay(500);assert.equal((await stat(heartbeat)).size,before,'guest writes continued after cancellation');
        }
        // Reopen the same real session to inspect persisted approval records.
        diagnostic.setPhase('audit');
        const auditId='audit-'+mode;
        socket.send(JSON.stringify({type:'open',streamId:auditId,endpoint:'session/follow',payload:{args:{request:{address:{kind:'session',sessionId},assistantDeltas:false}}}}));
        const rows=(await waitFrame(f=>f.streamId===auditId&&f.value?.type==='snapshot')).value.records;
        const audit=rows.map(r=>r.event).filter(Boolean);
        verifyAudit(audit,approval.request.callId,decisions);
        report.scenarios.push({name:mode,sessionLabel:'session-1',callLabel:'call-'+mode,decision,decisions,asked:decisions.length,decided:decisions.length,persistedTurnEnclosed:true});
        diagnostic.setPhase('complete');
        return sessionId;
      } catch (error) { throw diagnostic.fail('round-error', error); }
      finally {
        diagnostics.freezeBeforeCleanup();
        if (socket) { diagnostic.beginCleanup(); socket.terminate(); }
        rejectWaiters(diagnostic.error ?? diagnosticError('round-closed'));
      }
    }
    try {
      const ready=await waitReady(0,240000);
      let session;
      for(const mode of ['deny','identity','osrelease','apkpath','pipeline','full','rootreadonly','rootdeny','rootallow','rootafter','exit','cancel','after'])session=await round(ready,mode,session);
      // Every sensitive call requested a fresh approval. allowed-once did not become a standing grant.
      assert.equal(report.approvals,15);report.status='PASS';report.stage='complete';
    } catch (error) { diagnostics.failure('round-error', error); }
    await cleanup(); cleanup = async () => {};
    report.modelRequests = model.requests.map(row => ({ scenario: safeScenario(row.scenario), requestedTool: safeTool(row.requestedTool) }));
    const { nativeHost, eventTypes, ...detail } = diagnostics.snapshot();
    detail.hostTransport = stdoutLines.snapshot();
    report.nativeHost = nativeHost; report.eventTypes = eventTypes; report.diagnostics = detail;
    if (detail.firstFailure) { report.status = 'BLOCKED'; report.error = detail.firstFailure.failure; }
    writeFileSync(join(work, 'guest-report.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
    return report.status === 'PASS' ? 0 : 1;
  } finally { await cleanup(); }
}
// Setup/cleanup failures can include paths or arbitrary assertion text too.
main().then(code => process.exit(code), error => {
  console.error(JSON.stringify({ status: 'BLOCKED', stage: 'setup-or-cleanup', error: safeError(error) }));
  process.exit(1);
});
