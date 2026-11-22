// Fixed metadata search and original-version verification. No model, Agent, Session or write.
import {randomUUID} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {Temporal} from '@js-temporal/polyfill';
import {FIND_KIND, TASK_LIMIT_MS} from './task-schema.js';

const done = new Set(['done','partial','failed','cancelled']);
const duration = start => Math.max(0, Math.ceil(performance.now() - start));
const stepAt = (record, key, rev = record.taskRev) => record.steps.findLast(value => value.taskRev === rev && value.stepKey === key);
const claimOf = (record, step) => ({taskId:record.taskId, taskRev:step.taskRev, stepKey:step.stepKey,
  attemptId:step.attemptId, reserveMs:step.reserveMs,
  deadlineAtMs:record.revisions.find(value => value.taskRev === step.taskRev).agreement.deadlineAtMs});
const stopped = reason => Object.assign(new Error(reason), {findReason:reason});
const readFailure = error => ['FS_STALE_VERSION','FS_NOT_DIRECTORY','ENOTDIR','ELOOP'].includes(error?.code) ? 'original_changed'
  : ['FS_NOT_FOUND','ENOENT'].includes(error?.code) ? 'original_missing'
  : error?.code === 'FS_TOO_LARGE' ? 'original_too_large'
  : error?.code === 'FS_NOT_TEXT' ? 'original_not_text'
  : ['FS_PERMISSION_DENIED','FS_SANDBOX_DENIED','EACCES','EPERM'].includes(error?.code) ? 'original_not_readable'
  : 'original_unavailable';

export function findDraftSupported(fs) {
  return process.platform === 'linux' && ['dshGoBindNotesDirectory','dshGoListDrafts','dshGoReadNote']
    .every(name => typeof fs?.[name] === 'function');
}

function findings(selection, rev, verified, interruption = null) {
  const coverage = structuredClone(selection.coverage);
  if (interruption && selection.entries.length) coverage.gaps.push({relativePath:null, reason:interruption});
  const sources = [], matches = selection.entries.map(entry => {
    const actual = verified.get(entry.sourceRef);
    sources.push({sourceRef:entry.sourceRef, taskRev:rev, stepKey:'readInputs', directory:selection.directory,
      entry:{name:entry.name, version:entry.version, identity:entry.identity}, sha256:actual?.sha256 ?? null});
    return {sourceRef:entry.sourceRef, relativePath:entry.name, size:entry.size, modifiedAtMs:entry.modifiedAtMs,
      modifiedOffsetSeconds:Temporal.Instant.fromEpochMilliseconds(entry.modifiedAtMs)
        .toZonedDateTimeISO(selection.scope.timeZone).offsetNanoseconds / 1_000_000_000,
      version:entry.version, openable:actual?.openable === true,
      reason:actual?.openable === true ? null : actual?.reason ?? interruption ?? 'verification_interrupted'};
  });
  return {report:{scope:structuredClone(selection.scope), coverage, matches}, sources};
}

export function createFindDraftRunner({ctx, store}) {
  const fs = ctx.get('fs');
  if (!findDraftSupported(fs)) throw stopped('find_filesystem_unavailable');
  const queue = new Set();
  let closed = false, drain = null, active = null;

  function guard(id, rev, signal, reserveMs) {
    signal?.throwIfAborted();
    if (closed) throw stopped('task_owner_stopping');
    const record = store.read(id);
    if (record.taskRev !== rev || record.cancelRequested || !record.originalCreate || record.agreement?.afterExit !== 'continue')
      throw stopped('task_agreement_changed');
    if (record.agreement.deadlineAtMs !== null && store.now() >= record.agreement.deadlineAtMs)
      throw stopped('deadline_expired');
    if (reserveMs !== undefined && reserveMs <= 0) throw stopped('execution_budget_exhausted');
    return record;
  }
  function clock(claim, controller) {
    const budget = new AbortController();
    const timers = [];
    // The reserve is capped at the deadline, so both can run out together; the deadline is the real reason.
    const spent = () => stopped(claim.deadlineAtMs !== null && store.now() >= claim.deadlineAtMs
      ? 'deadline_expired' : 'execution_budget_exhausted');
    if (claim.reserveMs <= 0) budget.abort(spent());
    else timers.push(setTimeout(() => budget.abort(spent()), claim.reserveMs));
    const tick = () => {
      if (claim.deadlineAtMs === null || budget.signal.aborted) return;
      const left = claim.deadlineAtMs - store.now();
      if (left <= 0) budget.abort(stopped('deadline_expired'));
      else {const timer=setTimeout(tick,Math.min(left,2147483647));timer.unref?.();timers.push(timer);}
    };
    tick(); for (const timer of timers) timer.unref?.();
    return {signal:AbortSignal.any([controller.signal,budget.signal]), stop:()=>timers.forEach(clearTimeout)};
  }
  async function reconcile(id) {
    let record = store.read(id);
    for (const step of record.steps.filter(value => value.finishedAtMs === null)) {
      const claim = claimOf(record, step), selection = record.notes[String(step.taskRev)]?.selection;
      if (step.stepKey === 'readInputs' && selection) {
        // This is pure settlement of durable observations. No re-enumeration or read.
        await store.finishFind(claim, {...findings(selection, step.taskRev, new Map(), 'verification_interrupted'), elapsedMs:null});
      } else {
        await store.finishStep(claim, {state:'unknown', reason:'scan_interrupted', result:null, elapsedMs:null});
      }
      record = store.read(id);
    }
  }
  async function verify(id, rev, controller) {
    const record = store.read(id), selection = record.notes[String(rev)].selection;
    const claim = claimOf(record, stepAt(record, 'readInputs', rev));
    const timer = clock(claim, controller), start = performance.now(), verified = new Map();
    let interruption = null;
    try {
      for (const entry of selection.entries) {
        try {guard(id, rev, timer.signal, claim.reserveMs);}
        catch (error) {interruption=error.findReason ?? 'verification_interrupted';break;}
        try {
          const read = await fs.dshGoReadNote(selection.directory, entry, 65536, timer.signal);
          verified.set(entry.sourceRef, {openable:true, sha256:read.sha256});
        } catch (error) {
          if (timer.signal.aborted) {interruption=timer.signal.reason?.findReason ?? 'verification_interrupted';break;}
          verified.set(entry.sourceRef, {openable:false, reason:readFailure(error), sha256:null});
        }
        try {guard(id, rev, timer.signal, claim.reserveMs);}
        catch (error) {interruption=error.findReason ?? 'verification_interrupted';break;}
      }
      await store.finishFind(claim, {...findings(selection, rev, verified, interruption), elapsedMs:duration(start)});
    } finally {timer.stop();}
  }
  async function run(id, controller) {
    await reconcile(id);
    let record = store.read(id);
    if (record.kind !== FIND_KIND || closed || !record.originalCreate || record.cancelRequested || done.has(record.state)) return;
    const rev = record.taskRev;
    // Replaying the original create never re-scans a lost or completed original selection.
    if (stepAt(record, 'selectInputs')) return;
    if (record.agreement.afterExit !== 'continue') {await store.wait(id,rev,'foreground_control_unavailable');return;}
    let claim, timer;
    const start = performance.now();
    try {
      guard(id, rev, controller.signal);
      claim = await store.claimStep(id, rev, 'selectInputs', {reserveMs:TASK_LIMIT_MS});
      timer = clock(claim, controller);
      const args = record.agreement.args, range = record.notes[String(rev)].dayRange;
      guard(id, rev, timer.signal, claim.reserveMs);
      const listing = await fs.dshGoListDrafts(store.folder(args.folderRef), {...range,extensions:args.extensions}, timer.signal);
      // Even a late cancel/amend retains this already observed original batch. The next
      // persisted read claim receives zero time if its agreement no longer permits IO.
      const selection = {...listing, entries:listing.entries.map(entry => ({...entry,sourceRef:randomUUID()})),
        scope:{...structuredClone(args),displayPath:listing.directory.target.displayPath,...range}};
      await store.finishFindSelection(claim, selection, duration(start));
      timer.stop(); timer = null;
      await verify(id, rev, controller);
    } catch (error) {
      record = store.read(id);
      const original = claim && stepAt(record,'selectInputs',rev);
      if (original?.finishedAtMs === null) {
        const interrupted = controller.signal.aborted || timer?.signal.aborted || error?.code === 'FS_ABORTED';
        await store.finishStep(claim, {state:interrupted?'unknown':'failed',
          reason:interrupted?'scan_interrupted':error.findReason ?? 'directory_unavailable', result:null, elapsedMs:duration(start)});
      } else if (!claim && record.taskRev === rev && !record.cancelRequested && !done.has(record.state)) {
        await store.stopPlan(id,rev,'failed',error.findReason ?? 'find_unavailable');
      }
      // A failed persistence boundary stays unresolved for recovery; never invent a report.
    } finally {timer?.stop();}
  }
  async function work() {
    while (!closed && queue.size) {
      const id=queue.values().next().value;queue.delete(id);
      const record=store.read(id);
      if (record.kind !== FIND_KIND) continue;
      const controller=new AbortController();active={id,rev:record.taskRev,controller};
      try {await run(id,controller);} catch { /* Persisted claims remain explicit recovery evidence. */ }
      finally {active=null;controller.abort();}
    }
  }
  function wake(id) {
    if (closed) return;
    if (active?.id===id) {
      const record=store.read(id);
      if (record.taskRev!==active.rev || record.cancelRequested) active.controller.abort(stopped('task_agreement_changed'));
    }
    queue.add(id);
    if (!drain) drain=Promise.resolve().then(work).finally(()=>{drain=null;if(!closed&&queue.size)wake(queue.values().next().value);});
    return drain;
  }
  return {wake,async stop(){closed=true;queue.clear();active?.controller.abort(stopped('task_owner_stopping'));await drain;}};
}
