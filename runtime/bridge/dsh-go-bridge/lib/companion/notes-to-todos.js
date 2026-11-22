// One fixed notes task. No model-generated tool calls, command execution, or generic DAG.
import {join} from 'node:path';
import {performance} from 'node:perf_hooks';
import {errorCode} from './auxiliary.js';
import {taskError} from './task-schema.js';
import {runTaskModel} from './task-model.js';
import {NOTES_LIMITS, NotesTaskError, notesSystem, selectNotes, notesModelInput,
  notesInputEstimate, readNotesProposal, renderNotesPage} from './notes-content.js';

const finished = new Set(['done', 'partial', 'failed', 'cancelled']);
const step = (record, key, revision = record.taskRev) => record.steps.findLast(value => value.taskRev === revision && value.stepKey === key);
const privateNotes = record => record.notes[String(record.taskRev)];
const unresolved = record => record.steps.some(value => value.finishedAtMs === null ||
  value.state === 'unknown' && (value.taskRev === record.taskRev ||
    value.stepKey === 'writePage' && record.notes[String(value.taskRev)]?.publicationAttempted === true));
const duration = start => Math.max(0, Math.ceil(performance.now() - start));
const claimOf = (record, value) => ({taskId: record.taskId, taskRev: value.taskRev,
  stepKey: value.stepKey, attemptId: value.attemptId, reserveMs: value.reserveMs,
  deadlineAtMs: record.revisions.find(revision => revision.taskRev === value.taskRev)?.agreement?.deadlineAtMs ?? null});
const inputFailure = error => error?.code === 'FS_STALE_VERSION' ? 'input_changed'
  : error?.code === 'FS_TOO_LARGE' ? 'input_too_large' : error?.code === 'FS_NOT_TEXT' ? 'input_not_text' : 'input_unavailable';

function deadlineTimer(controller, atMs) {
  let timer;
  const tick = () => {
    if (atMs === null || controller.signal.aborted) return;
    const left = atMs - Date.now();
    if (left <= 0) controller.abort(new NotesTaskError('deadline_expired', 'failed'));
    else { timer = setTimeout(tick, Math.min(left, 2147483647)); timer.unref?.(); }
  };
  tick();
  return () => clearTimeout(timer);
}

export function createNotesToTodosRunner({ctx, store, execution}) {
  const queue = new Set(), foregrounds = new Map();
  let closed = false, drain = null, active = null;
  const fs = ctx.get('fs');
  const required = ['dshGoListNotes', 'dshGoReadNote', 'dshGoNotesPublicationSupport',
    'dshGoStageNotesFile', 'dshGoPublishNotesFile', 'dshGoInspectNotesPublication',
    'dshGoReadNotesArtifact', 'dshGoReleaseNotesStage'];
  if (required.some(name => typeof fs?.[name] !== 'function'))
    throw new NotesTaskError('notes_filesystem_unavailable');

  function guard(taskId, taskRev, signal, owner) {
    signal?.throwIfAborted();
    if (closed) throw new NotesTaskError('task_owner_stopping');
    const record = store.read(taskId);
    if (record.taskRev !== taskRev || record.cancelRequested || !record.originalCreate ||
      !store.executionAllowed(record)) throw new NotesTaskError('task_agreement_changed');
    if (record.agreement.deadlineAtMs !== null && Date.now() >= record.agreement.deadlineAtMs)
      throw new NotesTaskError('deadline_expired', 'failed');
    owner?.guard();
    return record;
  }

  async function segment(id, rev, key, reserveMs, controller, owner, job) {
    const pause = guard(id, rev, controller.signal, owner).agreement.afterExit === 'pause';
    const claim = await store.claimStep(id, rev, key, {reserveMs,
      retryKnownSafe: step(store.read(id), key, rev)?.state === 'waiting'});
    const start = performance.now(), clock = new AbortController();
    // The reserve is capped at the deadline, so both can fire together; the deadline is the real reason.
    const timeout = setTimeout(() => clock.abort(new NotesTaskError(
      claim.deadlineAtMs !== null && Date.now() >= claim.deadlineAtMs ? 'deadline_expired' : 'execution_budget_exhausted',
      'failed')), claim.reserveMs);
    timeout.unref?.();
    const signal = AbortSignal.any([controller.signal, clock.signal]);
    const current = () => guard(id, rev, signal, owner);
    let jobEntered = false;
    try {
      current();
      const result = await owner.runTurn(turnSignal => {
        jobEntered = true;
        return job({claim, signal: AbortSignal.any([signal, turnSignal]),
          guard: () => {turnSignal.throwIfAborted(); return current();}, elapsed: () => duration(start)});
      });
      const latest = store.read(id), original = step(latest, key, rev);
      if (original.finishedAtMs === null)
        await store.finishStep(claim, {state: 'done', reason: null, result: result ?? null, elapsedMs: duration(start)});
      return result;
    } catch (caught) {
      const error = signal.aborted && signal.reason instanceof NotesTaskError ? signal.reason : caught;
      const latest = store.read(id), original = step(latest, key, rev), notes = latest.notes[String(rev)];
      // Once a publication job may have begun, its retained object is the recovery evidence.
      // Never turn an abort/flush/commit exception into a no-write claim.
      if (key === 'writePage' && notes?.publicationAttempted === true) throw error;
      if (original.finishedAtMs === null) {
        let state = error.notesState ?? (key === 'model' ? 'unknown' : ['selectInputs', 'readInputs'].includes(key) ? 'waiting' : 'failed');
        // A direct guard can observe a wall-clock deadline before its timer fires.
        // The error reason, not only the abort bit, identifies that interruption.
        if (key === 'model' && (signal.aborted || state === 'waiting' ||
          ['deadline_expired', 'execution_budget_exhausted'].includes(error.notesReason))) {
          const observations = original.result?.observations ?? [];
          const outbound = observations.some(event => ['dispatch', 'handoff', 'http', 'usage', 'runtime-usage', 'stop', 'complete'].includes(event.type));
          if (outbound) {
            const finish = observations.findLast(event => event.type === 'model-finish');
            // A control interruption does not prove the original request was unsent or failed.
            // A drained, observed complete request can settle this cancelled agreement's step;
            // otherwise its original result stays unknown, with every observation retained.
            state = latest.cancelRequested && finish?.usage?.complete === true ? 'cancelled' : 'unknown';
          }
        }
        const saved = key === 'selectInputs' ? notes?.selection : key === 'readInputs' ? notes?.inputs
          : key === 'model' ? notes?.candidate : null;
        const interrupted = pause && ['foreground_withdrawn', 'task_owner_stopping'].includes(error.notesReason);
        if (interrupted && saved) state = 'done';
        const completion = interrupted && saved ? {recoveredSavedResult: true}
          : interrupted && key === 'model' && !jobEntered ? {preflightDispatched: false, streamEntered: false}
          : interrupted && key === 'writePage' && notes?.publicationAttempted !== true ? {publicationNotAttempted: true}
          : error.notesPreflightProof ?? null;
        await store.finishStep(claim, {state, reason: state === 'done' ? null
          : error.notesReason ?? (key === 'model' ? 'model_unconfirmed' : 'step_unavailable'),
          result: completion, elapsedMs: duration(start)});
        if (state === 'waiting' && latest.taskRev === rev && !latest.cancelRequested && !closed)
          await store.wait(id, rev, error.notesReason ?? 'step_unavailable');
      }
      throw error;
    } finally { clearTimeout(timeout); }
  }

  function artifactData(reference, verified, notes, candidate) {
    if (verified.state !== 'verified') throw new NotesTaskError('publication_unconfirmed', 'unknown');
    const scope = notes.inputs?.scope;
    return {artifact: {relativePath: reference.outputName, mediaType: candidate.mediaType,
      size: verified.size, sha256: verified.sha256, identity: verified.identity,
      verifiedAtMs: Date.now(), sourceCount: candidate.sourceCount},
      state: scope?.gaps?.length ? 'partial' : 'done', reason: scope?.gaps?.length ? 'inputs_incomplete' : null};
  }

  async function reconcile(id) {
    let record = store.read(id);
    for (const original of record.steps) {
      if (closed) return;
      const notes = record.notes[String(original.taskRev)];
      const claim = claimOf(record, original);
      if (original.stepKey === 'writePage' && (notes?.publicationAttempted === true
        ? notes.publicationAttemptId !== original.attemptId
        : step(record, 'writePage', original.taskRev)?.attemptId !== original.attemptId)) continue;
      if (original.stepKey === 'writePage' && notes?.publishIntent && notes.candidate &&
        !record.artifacts.some(value => value.taskRev === original.taskRev && value.stepKey === 'writePage')) {
        // Reconciliation has no model, link, rename, overwrite or candidate-as-artifact path.
        let observed = {state: 'unavailable'};
        try { observed = await fs.dshGoInspectNotesPublication(notes.publishIntent); }
        catch { /* An unavailable original identity is not evidence of a missing historical effect. */ }
        if (observed.state === 'verified' && notes.publicationAttempted === true) {
          await store.recordArtifact(claim,
            {...artifactData(notes.publishIntent, observed, notes, notes.candidate), elapsedMs: null});
        } else if (original.finishedAtMs === null) {
          // No marker means publish's durable-before-job boundary was never crossed. Preserve
          // this time hold, then reserve NEW remaining time for a first use of the SAME stage.
          const provenUnsent = notes.publicationAttempted !== true && observed.state === 'absent';
          await store.finishStep(claim, {state: provenUnsent ? 'waiting' : 'unknown',
            reason: provenUnsent ? 'publication_not_started' : 'publication_unconfirmed',
            result: provenUnsent ? {publicationNotAttempted: true} :
              {inspection: observed.state, publicationAttempted: notes.publicationAttempted === true}, elapsedMs: null});
        }
      } else if (original.finishedAtMs === null) {
        const saved = original.stepKey === 'selectInputs' ? notes?.selection
          : original.stepKey === 'readInputs' ? notes?.inputs : original.stepKey === 'model' ? notes?.candidate : null;
        // Saved results allow read-only settlement; a lost model result is never regenerated.
        await store.finishStep(claim, {state: saved ? 'done' : 'unknown',
          reason: saved ? null : original.stepKey === 'model' ? 'model_unconfirmed' : 'prior_step_unresolved',
          result: saved ? {recoveredSavedResult: true} : null, elapsedMs: null});
      }
      record = store.read(id);
    }
  }

  async function outputPolicy(record, owner, signal) {
    const directory = store.folder(record.agreement.args.outputDirRef);
    const target = await fs.resolve(join(directory.target.displayPath, record.agreement.args.outputName), {signal});
    if (typeof fs.checkedTarget !== 'function') return owner.standingPolicy;
    try { await fs.checkedTarget(target, owner.standingPolicy); return owner.standingPolicy; }
    catch (error) { if (error?.code !== 'FS_SANDBOX_DENIED') throw error; }
    const modes = owner.standingPolicy?.mode === 'read-only'
      ? ['workspace-write', 'danger-full-access'] : ['danger-full-access'];
    let requestedMode;
    // These are only checks for the narrowest ask. No mutation receives this hypothetical policy.
    for (const mode of modes) {
      try { await fs.checkedTarget(target, {...owner.standingPolicy, mode}); requestedMode = mode; break; }
      catch (error) { if (error?.code !== 'FS_SANDBOX_DENIED') throw error; }
    }
    if (!requestedMode) throw new NotesTaskError('output_policy_unavailable');
    guard(record.taskId, record.taskRev, signal, owner);
    return owner.approve('writePage', {requestedMode,
      justification: `只在 ${directory.target.displayPath} 新建《${record.agreement.args.outputName}》以整理本次选定笔记；不覆盖已有文件，不改原笔记。`}, signal);
  }

  async function generateCandidate(id, rev, controller, owner) {
    const inputs = privateNotes(guard(id, rev, controller.signal, owner)).inputs, input = notesModelInput(inputs);
    const estimateBody = JSON.stringify({system: notesSystem, messages: [{role: 'user', content: [{type: 'text', text: input}]}]});
    if (!notesInputEstimate(estimateBody).accepted) throw new NotesTaskError('model_input_limit');
    const capability = owner.llm?.companionAuxiliaryCapability?.(owner.selected.provider);
    if (!capability || typeof owner.llm?.prepareCompanionAuxiliaryCall !== 'function')
      throw new NotesTaskError('model_channel_unavailable');
    return segment(id, rev, 'model', 180_000, controller, owner, async ({claim, signal, guard: current}) => {
      const {text, inputBudget, usage} = await runTaskModel({store, claim, owner, signal, guard: current,
        system: notesSystem, input, capability, inputEstimate: notesInputEstimate, outputTokens: NOTES_LIMITS.outputTokens});
      const mediaType = current().agreement.args.outputName.toLowerCase().endsWith('.md') ? 'text/markdown' : 'text/plain';
      const page = renderNotesPage(readNotesProposal(text, inputs), inputs, mediaType);
      await store.saveCandidate(claim, {content: page.content,
        mediaType,
        sourceCount: page.sourceCount, itemCount: page.itemCount, usage});
      return {sourceCount: page.sourceCount, itemCount: page.itemCount, inputBudget, usage};
    });
  }

  async function run(id, controller, foreground) {
    await reconcile(id);
    let record = store.read(id);
    if (closed || !record.originalCreate || record.cancelRequested || finished.has(record.state) ||
      unresolved(record)) return;
    if (!store.executionAllowed(record) || record.agreement.afterExit === 'pause' &&
        (foreground?.revision !== record.taskRev || foreground !== foregrounds.get(id))) {
      await store.wait(id, record.taskRev, 'foreground_required'); return;
    }
    const revision = record.taskRev, stopDeadline = deadlineTimer(controller, record.agreement.deadlineAtMs);
    try {
      guard(id, revision, controller.signal);
      const owner = await execution.openExecution(record, controller.signal);
      if (!step(record, 'selectInputs') || step(record, 'selectInputs').state === 'waiting') await segment(id, revision, 'selectInputs', 25_000, controller, owner,
        async ({claim, signal, guard: current}) => {
          const currentRecord = current(), args = currentRecord.agreement.args, notes = privateNotes(currentRecord);
          const output = store.folder(args.outputDirRef);
          if (!(await fs.dshGoNotesPublicationSupport(output, signal)).supported)
            throw new NotesTaskError('output_filesystem_unsupported');
          const outputTarget = await fs.resolve(join(output.target.displayPath, args.outputName), {signal});
          if (await fs.stat(outputTarget, signal)) throw new NotesTaskError('output_exists');
          const listing = await fs.dshGoListNotes(store.folder(args.folderRef), signal);
          const selection = selectNotes(listing, args, notes.dayRange, output, Date.now());
          current(); await store.saveSelection(claim, selection);
          return {selectedCount: selection.entries.length, gapCount: selection.scope.gaps.length};
        });
      record = guard(id, revision, controller.signal, owner);
      if (step(record, 'selectInputs')?.state !== 'done') return;
      if (!step(record, 'readInputs') || step(record, 'readInputs').state === 'waiting') await segment(id, revision, 'readInputs', 60_000, controller, owner,
        async ({claim, signal, guard: current}) => {
          const selection = privateNotes(current()).selection;
          if (!selection) throw new NotesTaskError('selection_unavailable');
          const entries = [], gaps = [...selection.scope.gaps];
          for (const selected of selection.entries) {
            current();
            try {
              const actual = await fs.dshGoReadNote(selection.directory, selected, NOTES_LIMITS.fileBytes, signal);
              entries.push({...selected, text: actual.text, sha256: actual.sha256});
            } catch (error) {signal.throwIfAborted(); gaps.push({name: selected.name, reason: inputFailure(error)});}
          }
          current();
          if (!entries.length) throw new NotesTaskError('matching_inputs_unavailable');
          await store.saveInputs(claim, {directory: selection.directory, entries, scope: {...selection.scope, gaps}});
          return {sourceCount: entries.length, gapCount: gaps.length};
        });
      record = guard(id, revision, controller.signal, owner);
      if (step(record, 'readInputs')?.state !== 'done') return;
      // Approval waits have no active execution-time reservation. The real approval hook owns its turn.
      const policy = await outputPolicy(record, owner, controller.signal);
      record = guard(id, revision, controller.signal, owner);
      if (!step(record, 'model') || step(record, 'model').state === 'waiting') await generateCandidate(id, revision, controller, owner);
      record = guard(id, revision, controller.signal, owner);
      if (step(record, 'model')?.state !== 'done' || !privateNotes(record).candidate) return;
      if (!step(record, 'writePage') || step(record, 'writePage').state === 'waiting') await segment(id, revision, 'writePage', 60_000, controller, owner,
        async ({claim, signal, guard: current, elapsed}) => {
          const original = current(), notes = privateNotes(original), candidate = notes.candidate;
          const reference = notes.publishIntent ?? await fs.dshGoStageNotesFile(store.folder(original.agreement.args.outputDirRef),
            original.agreement.args.outputName, candidate.content, signal, policy);
          if (notes.publishIntent && (notes.publicationAttempted === true ||
              (await fs.dshGoInspectNotesPublication(reference, signal)).state !== 'absent'))
            throw new NotesTaskError('publication_unconfirmed', 'unknown');
          // Retain the actual stage even when foreground withdrawal interrupts the
          // subsequent reads. This observation does not authorize publication.
          await store.savePublishIntent(claim, reference);
          // Recheck the fixed whole versions after staging, immediately before the durable
          // publication boundary. This is not an atomic snapshot against unrelated writers.
          for (const entry of notes.inputs.entries) {
            const actual = await fs.dshGoReadNote(notes.inputs.directory, entry, NOTES_LIMITS.fileBytes, signal);
            if (actual.sha256 !== entry.sha256) throw new NotesTaskError('input_changed');
          }
          current();
          const snapshot = await store.publish(claim, async saved => {
            current();
            const verified = await fs.dshGoPublishNotesFile(saved, signal, policy);
            return {...artifactData(saved, verified, notes, candidate), elapsedMs: elapsed()};
          });
          // Receipt success comes first. Cleanup failure cannot erase or recreate the artifact.
          try {await fs.dshGoReleaseNotesStage(reference, signal, policy);} catch {}
          return {artifactId: snapshot.artifacts.find(value => value.taskRev === revision)?.artifactId ?? null};
        });
    } catch (error) {
      if (!closed) {
        await reconcile(id);
        record = store.read(id);
        if (record.taskRev === revision && !record.cancelRequested && !finished.has(record.state) &&
          !unresolved(record) &&
          record.waitReason !== 'approval' && !String(record.waitReason).startsWith('approval_')) {
          if (error.notesState === 'failed' || error.notesState === 'partial')
            await store.stopPlan(id, revision, error.notesState, error.notesReason);
          else if (record.waitReason !== (error.notesReason ?? 'execution_unavailable'))
            await store.wait(id, revision, error.notesReason ?? 'execution_unavailable');
        }
      }
    } finally {stopDeadline();}
  }

  async function work() {
    while (!closed && queue.size) {
      const id = queue.values().next().value; queue.delete(id);
      const controller = new AbortController();
      const revision = store.read(id).taskRev, held = foregrounds.get(id);
      active = {id, revision, controller, foreground: held?.revision === revision ? held : null};
      try {await run(id, controller, active.foreground);} catch { /* Durable unresolved facts remain for explicit recovery. */ }
      finally {
        controller.abort();
        active.foreground?.finish();
        active = null;
      }
    }
  }
  function wake(id) {
    if (closed) return;
    if (active?.id === id) {
      const record = store.read(id);
      if (record.taskRev !== active.revision || record.cancelRequested) active.controller.abort(new NotesTaskError('task_agreement_changed'));
    }
    queue.add(id);
    if (!drain) drain = Promise.resolve().then(work).finally(() => {drain = null; if (!closed && queue.size) wake(queue.values().next().value);});
    return drain;
  }
  function foregroundActive(id, revision) {
    const held = foregrounds.get(id);
    return !closed && held?.revision === revision && !held.signal.aborted;
  }
  function foreground(id, revision, signal) {
    signal.throwIfAborted();
    if (closed || foregrounds.has(id))
      throw taskError(409, 'conflict', 'The original notes request is still draining');
    let finish;
    const completed = new Promise(resolve => { finish = resolve; });
    const held = {revision, signal, finish}; foregrounds.set(id, held);
    const abort = () => {
      if (store.read(id).taskRev === revision) queue.delete(id);
      if (active?.foreground === held)
        active.controller.abort(new NotesTaskError('foreground_withdrawn'));
      else finish();
    };
    signal.addEventListener('abort', abort, {once: true});
    wake(id);
    return completed.finally(() => {
      signal.removeEventListener('abort', abort);
      if (foregrounds.get(id) === held) foregrounds.delete(id);
    });
  }
  return {wake, foreground, foregroundActive, async stop() {
    closed = true; queue.clear(); active?.controller.abort(new NotesTaskError('task_owner_stopping'));
    for (const [id, held] of foregrounds) {
      if (active?.foreground !== held) held.finish();
    }
    await drain;
  }};
}

