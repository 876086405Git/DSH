import {join} from 'node:path';
import {performance} from 'node:perf_hooks';
import {XLSX_TYPE} from './task-schema.js';
import {canReadReceiptPdf, readReceiptPdf} from './receipt-pdf.js';
import {RECEIPT_LIMITS, ReceiptTaskError, receiptTextLines, receiptObservation, receiptReport,
  excludeReceiptAtPublish, receiptGrid, completeReceiptReport} from './receipt-content.js';

const finished = new Set(['done', 'partial', 'failed', 'cancelled']);
const stepOf = (record, key, rev = record.taskRev) => record.steps.findLast(step => step.taskRev === rev && step.stepKey === key);
const notesOf = (record, rev = record.taskRev) => record.notes[String(rev)];
const unresolved = record => record.steps.some(step => step.finishedAtMs === null ||
  step.state === 'unknown' && (step.taskRev === record.taskRev || step.stepKey === 'writeSheet' &&
    notesOf(record, step.taskRev)?.publicationAttempted === true));
const elapsed = start => Math.max(0, Math.ceil(performance.now() - start));
const claimOf = (record, step) => ({taskId: record.taskId, taskRev: step.taskRev, stepKey: step.stepKey,
  attemptId: step.attemptId, reserveMs: step.reserveMs,
  deadlineAtMs: record.revisions.find(value => value.taskRev === step.taskRev)?.agreement?.deadlineAtMs ?? null});
const failure = error => error?.receiptReason ?? (error?.code === 'FS_STALE_VERSION' ? 'input_changed' :
  error?.code === 'FS_TOO_LARGE' ? 'input_too_large' : /^pdf_[a-z_]+$/u.test(error?.code ?? '') ? error.code : 'input_unavailable');
const methods = ['dshGoReadReceipt', 'dshGoNotesPublicationSupport', 'dshGoStageNotesFile',
  'dshGoPublishNotesFile', 'dshGoInspectNotesPublication', 'dshGoReadTaskArtifactBytes', 'dshGoReleaseNotesStage'];
export const receiptsToSheetSupported = fs => methods.every(name => typeof fs?.[name] === 'function');
export const receiptInputFormats = () => ['md', 'txt', ...(canReadReceiptPdf() ? ['pdf'] : [])];

function deadlineTimer(controller, atMs) {
  let timer;
  const tick = () => {
    if (atMs === null || controller.signal.aborted) return;
    const left = atMs - Date.now();
    if (left <= 0) controller.abort(new ReceiptTaskError('deadline_expired'));
    else { timer = setTimeout(tick, Math.min(left, 2147483647)); timer.unref?.(); }
  };
  tick(); return () => clearTimeout(timer);
}
export function createReceiptsToSheetRunner({ctx, store, execution}) {
  const fs = ctx.get('fs'), queue = new Set();
  let closed = false, drain = null, active = null;
  if (!receiptsToSheetSupported(fs)) throw new ReceiptTaskError('receipt_filesystem_unavailable');
  // read = store.stored for checks that discard the record.
  function guard(id, rev, signal, owner, read = store.read) {
    signal?.throwIfAborted();
    if (closed) throw new ReceiptTaskError('task_owner_stopping', 'waiting');
    const record = read.call(store, id);
    if (record.taskRev !== rev || record.cancelRequested || !record.originalCreate || record.agreement?.afterExit !== 'continue')
      throw new ReceiptTaskError('task_agreement_changed');
    if (record.agreement.deadlineAtMs !== null && Date.now() >= record.agreement.deadlineAtMs)
      throw new ReceiptTaskError('deadline_expired');
    if (ctx.get('fs') !== fs) throw new ReceiptTaskError('filesystem_owner_changed');
    owner?.guard(); return record;
  }
  function observedReport(record, rev, missingReason = 'input_not_read') {
    const agreement = record.revisions.find(value => value.taskRev === rev).agreement;
    return receiptReport(agreement.args.inputs.map(reference => notesOf(record, rev)?.receiptObservations?.[reference.sourceRef] ??
      receiptObservation(store.input(reference), {reason: missingReason})));
  }
  async function segment(id, rev, key, reserveMs, controller, owner, job) {
    guard(id, rev, controller.signal, owner, store.stored);
    const start = performance.now();
    const claim = await store.claimStep(id, rev, key, {reserveMs,
      retryKnownSafe: stepOf(store.stored(id), key, rev)?.state === 'waiting'});
    const clock = new AbortController();
    // The reserve is capped at the deadline, so both can fire together; the deadline is the real reason.
    const timer = setTimeout(() => clock.abort(new ReceiptTaskError(
      claim.deadlineAtMs !== null && Date.now() >= claim.deadlineAtMs ? 'deadline_expired' : 'execution_budget_exhausted')),
    claim.reserveMs);
    timer.unref?.();
    const signal = AbortSignal.any([controller.signal, clock.signal]);
    const current = read => {
      if (elapsed(start) > claim.reserveMs) throw new ReceiptTaskError('execution_budget_exhausted');
      return guard(id, rev, signal, owner, read);
    };
    try {
      const invoke = async turnSignal => {
        const fused = turnSignal ? AbortSignal.any([signal, turnSignal]) : signal;
        return job({claim, signal: fused, current: read => { fused.throwIfAborted(); return current(read); }, elapsed: () => elapsed(start)});
      };
      const result = owner ? await owner.runTurn(invoke) : await invoke();
      if (stepOf(store.stored(id), key, rev).finishedAtMs === null)
        await store.finishStep(claim, {state: 'done', reason: null, result: result ?? null, elapsedMs: elapsed(start)});
      return result;
    } catch (caught) {
      const error = signal.aborted && signal.reason instanceof ReceiptTaskError ? signal.reason : caught;
      const record = store.read(id), original = stepOf(record, key, rev), notes = notesOf(record, rev);
      if (key === 'writeSheet' && notes?.publicationAttempted === true) throw error;
      if (original.finishedAtMs === null) {
        const stopped = closed || error.receiptReason === 'task_owner_stopping';
        const state = stopped ? 'waiting' : error.receiptState ?? 'failed';
        const unsent = stopped && key === 'writeSheet' && notes?.publicationAttempted !== true;
        await store.finishStep(claim, {state, reason: state === 'waiting'
          ? unsent ? 'publication_not_started' : 'receipt_read_interrupted' : failure(error),
          result: {report: error.receiptReport ?? observedReport(record, rev, failure(error)),
            ...(unsent ? {publicationNotAttempted: true} : {})}, elapsedMs: elapsed(start)});
      }
      throw error;
    } finally { clearTimeout(timer); }
  }
  async function readInputs(id, rev, controller) {
    return segment(id, rev, 'readInputs', 180000, controller, null, async ({claim, signal, current}) => {
      const record = current(), args = record.agreement.args, output = store.folder(args.outputDirRef);
      if (!(await fs.dshGoNotesPublicationSupport(output, signal)).supported)
        throw new ReceiptTaskError('output_filesystem_unsupported');
      const target = await fs.resolve(join(output.target.displayPath, args.outputName), {signal});
      if (await fs.stat(target, signal)) throw new ReceiptTaskError('output_exists');
      for (const reference of args.inputs) {
        const latest = current();
        if (Object.hasOwn(notesOf(latest).receiptObservations ?? {}, reference.sourceRef)) continue;
        const binding = store.input(reference); let read = null, extraction = null, reason = null;
        try {
          read = await fs.dshGoReadReceipt(binding.directory, binding.entry, RECEIPT_LIMITS.fileBytes, signal);
          current(store.stored);
          extraction = /\.pdf$/iu.test(binding.entry.name)
            ? await readReceiptPdf(read.bytes, {signal, maxPages: RECEIPT_LIMITS.pdfPages, maxTextBytes: RECEIPT_LIMITS.textBytes})
            : receiptTextLines(read.bytes);
          current(store.stored);
        } catch (error) { signal.throwIfAborted(); current(store.stored); reason = failure(error); }
        await store.saveReceiptObservation(claim, reference.sourceRef, receiptObservation(binding, {read, extraction, reason}));
      }
      const observations = args.inputs.map(reference => notesOf(current()).receiptObservations[reference.sourceRef]);
      const report = receiptReport(observations);
      await store.saveInputs(claim, {observations, report});
      return {report};
    });
  }
  async function outputPolicy(record, owner, signal) {
    const directory = store.folder(record.agreement.args.outputDirRef);
    const target = await fs.resolve(join(directory.target.displayPath, record.agreement.args.outputName), {signal});
    if (typeof fs.checkedTarget !== 'function') return owner.standingPolicy;
    try { await fs.checkedTarget(target, owner.standingPolicy); return owner.standingPolicy; }
    catch (error) { if (error?.code !== 'FS_SANDBOX_DENIED') throw error; }
    const modes = owner.standingPolicy?.mode === 'read-only' ? ['workspace-write', 'danger-full-access'] : ['danger-full-access'];
    let requestedMode;
    for (const mode of modes) {
      try { await fs.checkedTarget(target, {...owner.standingPolicy, mode}); requestedMode = mode; break; }
      catch (error) { if (error?.code !== 'FS_SANDBOX_DENIED') throw error; }
    }
    if (!requestedMode) throw new ReceiptTaskError('output_policy_unavailable');
    guard(record.taskId, record.taskRev, signal, owner, store.stored);
    return owner.approve('writeSheet', {requestedMode,
      justification: `只在 ${directory.target.displayPath} 新建《${record.agreement.args.outputName}》，将本人选定的四份票据整理为日期、项目、金额和来源；不覆盖已有文件，不改原票。`}, signal);
  }
  async function verifyOriginal(observation, signal) {
    if (!observation.sha256) return false;
    const reference = observation.source, binding = store.input(reference);
    const read = await fs.dshGoReadReceipt(binding.directory, binding.entry, RECEIPT_LIMITS.fileBytes, signal);
    if (read.sha256 !== observation.sha256) throw new ReceiptTaskError('input_changed');
    return true;
  }
  function artifactResult(reference, verified, candidate) {
    if (verified.state !== 'verified') throw new ReceiptTaskError('publication_unconfirmed', 'unknown');
    const complete = completeReceiptReport(candidate.report);
    return {artifact: {relativePath: reference.outputName, mediaType: XLSX_TYPE, size: verified.size,
      sha256: verified.sha256, identity: verified.identity, verifiedAtMs: Date.now(), sourceCount: 4},
      report: candidate.report, state: complete ? 'done' : 'partial', reason: complete ? null : 'receipts_incomplete'};
  }
  async function reopenWorkbook(reference, verified, candidate, signal) {
    const actual = await fs.dshGoReadTaskArtifactBytes(reference.directory, reference.outputName, verified, signal);
    const {verifyReceiptWorkbook} = await import('./receipt-workbook.js');
    verifyReceiptWorkbook(actual.bytes, candidate.grid);
    if (actual.sha256 !== candidate.sha256) throw new ReceiptTaskError('workbook_verification_failed');
  }
  async function reconcile(id) {
    let record = store.read(id);
    for (const original of record.steps) {
      if (closed) return;
      const notes = notesOf(record, original.taskRev), claim = claimOf(record, original);
      if (original.stepKey === 'writeSheet' && (notes?.publicationAttempted === true
        ? notes.publicationAttemptId !== original.attemptId
        : stepOf(record, 'writeSheet', original.taskRev)?.attemptId !== original.attemptId)) continue;
      if (original.stepKey === 'writeSheet' && notes?.publishIntent && notes.candidate &&
          !record.artifacts.some(value => value.taskRev === original.taskRev && value.stepKey === 'writeSheet')) {
        let observed = {state: 'unavailable'};
        try {
          observed = await fs.dshGoInspectNotesPublication(notes.publishIntent);
          if (observed.state === 'verified') await reopenWorkbook(notes.publishIntent, observed, notes.candidate);
        } catch { observed = {state: 'unavailable'}; }
        if (observed.state === 'verified' && notes.publicationAttempted === true)
          await store.recordArtifact(claim, {...artifactResult(notes.publishIntent, observed, notes.candidate), elapsedMs: null});
        else if (original.finishedAtMs === null) {
          const unsent = notes.publicationAttempted !== true && observed.state === 'absent';
          await store.finishStep(claim, {state: unsent ? 'waiting' : 'unknown',
            reason: unsent ? 'publication_not_started' : 'publication_unconfirmed', result: unsent
              ? {publicationNotAttempted: true} : {inspection: observed.state, publicationAttempted: notes.publicationAttempted === true}, elapsedMs: null});
        }
      } else if (original.finishedAtMs === null) {
        if (original.stepKey === 'readInputs')
          await store.finishStep(claim, {state: notes?.inputs ? 'done' : 'waiting',
            reason: notes?.inputs ? null : 'receipt_read_interrupted',
            result: {report: notes?.inputs?.report ?? observedReport(record, original.taskRev)}, elapsedMs: null});
        else if (original.stepKey === 'writeSheet' && notes?.inputs && notes.publicationAttempted !== true)
          await store.finishStep(claim, {state: 'waiting', reason: 'publication_not_started',
            result: {publicationNotAttempted: true}, elapsedMs: null});
        else await store.finishStep(claim, {state: 'unknown', reason: 'prior_step_unresolved', elapsedMs: null});
      }
      record = store.read(id);
    }
  }
  async function writeSheet(id, rev, controller, owner, policy) {
    return segment(id, rev, 'writeSheet', 120000, controller, owner, async ({claim, signal, current, elapsed}) => {
      let record = current(), notes = notesOf(record), candidate = notes.candidate;
      if (!candidate) {
        const observations = [];
        for (const observed of notes.inputs.observations) {
          current(store.stored); let observation = structuredClone(observed);
          try { observation.source.verifiedAtPublish = await verifyOriginal(observation, signal); }
          catch (error) { signal.throwIfAborted(); current(store.stored); observation = excludeReceiptAtPublish(observation,
            failure(error) === 'input_changed' ? 'input_changed_at_publish' : 'input_unavailable_at_publish'); }
          observations.push(observation);
        }
        const report = receiptReport(observations);
        if (!report.coverage.rowsWithVerifiedFields)
          throw Object.assign(new ReceiptTaskError('receipt_fields_unavailable'), {receiptReport: report});
        const {createReceiptWorkbook, verifyReceiptWorkbook} = await import('./receipt-workbook.js');
        const grid = receiptGrid(report), bytes = createReceiptWorkbook(grid);
        verifyReceiptWorkbook(bytes, grid);
        const {createHash} = await import('node:crypto');
        candidate = {bytesBase64: bytes.toString('base64'), sha256: createHash('sha256').update(bytes).digest('hex'), grid, report};
        current(store.stored); await store.saveCandidate(claim, candidate);
      }
      record = current(); notes = notesOf(record);
      const reference = notes.publishIntent ?? await fs.dshGoStageNotesFile(store.folder(record.agreement.args.outputDirRef),
        record.agreement.args.outputName, Buffer.from(candidate.bytesBase64, 'base64'), signal, policy);
      if (notes.publishIntent && (notes.publicationAttempted === true ||
          (await fs.dshGoInspectNotesPublication(reference, signal)).state !== 'absent'))
        throw new ReceiptTaskError('publication_unconfirmed', 'unknown');
      // Persist the exact retained object before any later guard can interrupt us.
      await store.savePublishIntent(claim, reference);
      // Only sources included as current in this candidate may support its published cells.
      for (let index = 0; index < 4; index++) if (candidate.report.sources[index].verifiedAtPublish) {
        current(store.stored); await verifyOriginal(notes.inputs.observations[index], signal);
      }
      current(store.stored);
      const snapshot = await store.publish(claim, async saved => {
        current(store.stored);
        const verified = await fs.dshGoPublishNotesFile(saved, signal, policy);
        await reopenWorkbook(saved, verified, candidate, signal);
        return {...artifactResult(saved, verified, candidate), elapsedMs: elapsed()};
      });
      try { await fs.dshGoReleaseNotesStage(reference, signal, policy); } catch { /* Receipt already committed. */ }
      return {artifactId: snapshot.artifacts.find(value => value.taskRev === rev)?.artifactId ?? null, report: candidate.report};
    });
  }
  async function run(id, controller) {
    await reconcile(id); let record = store.read(id);
    if (closed || !record.originalCreate || record.cancelRequested || finished.has(record.state) || unresolved(record)) return;
    if (record.agreement.afterExit !== 'continue') { await store.wait(id, record.taskRev, 'foreground_control_unavailable'); return; }
    const rev = record.taskRev, stopDeadline = deadlineTimer(controller, record.agreement.deadlineAtMs);
    try {
      record = guard(id, rev, controller.signal);
      if (!stepOf(record, 'readInputs') || stepOf(record, 'readInputs').state === 'waiting') await readInputs(id, rev, controller);
      record = guard(id, rev, controller.signal);
      if (!notesOf(record).inputs) return;
      if (!notesOf(record).inputs.report.coverage.rowsWithVerifiedFields) {
        await store.stopPlan(id, rev, 'failed', 'receipt_fields_unavailable'); return;
      }
      if (record.budget.spentMs + record.budget.heldMs >= record.budget.limitMs) {
        await store.stopPlan(id, rev, 'failed', 'execution_budget_exhausted'); return;
      }
      const owner = await execution.openExecution(record, controller.signal, {requireModel: false});
      const policy = await outputPolicy(record, owner, controller.signal);
      record = guard(id, rev, controller.signal, owner);
      if (!stepOf(record, 'writeSheet') || stepOf(record, 'writeSheet').state === 'waiting')
        await writeSheet(id, rev, controller, owner, policy);
    } catch (error) {
      if (!closed) {
        await reconcile(id); record = store.read(id);
        if (record.taskRev === rev && !record.cancelRequested && !finished.has(record.state) && !unresolved(record) &&
            record.waitReason !== 'approval' && !String(record.waitReason).startsWith('approval_'))
          await store.stopPlan(id, rev, 'failed', failure(error));
      }
    } finally { stopDeadline(); }
  }
  async function work() {
    while (!closed && queue.size) {
      const id = queue.values().next().value; queue.delete(id); const controller = new AbortController();
      active = {id, rev: store.read(id).taskRev, controller};
      try { await run(id, controller); } catch { /* Original unresolved facts stay durable. */ }
      finally { controller.abort(); active = null; }
    }
  }
  function wake(id) {
    if (closed) return;
    if (active?.id === id) {
      const record = store.read(id);
      if (record.taskRev !== active.rev || record.cancelRequested)
        active.controller.abort(new ReceiptTaskError('task_agreement_changed'));
    }
    queue.add(id);
    if (!drain) drain = Promise.resolve().then(work).finally(() => { drain = null;
      if (!closed && queue.size) wake(queue.values().next().value); });
    return drain;
  }
  return {wake, async stop() { closed = true; queue.clear();
    active?.controller.abort(new ReceiptTaskError('task_owner_stopping', 'waiting')); await drain; }};
}
