// One fixed notes task. No model-generated tool calls, command execution, or generic DAG.
import {join} from 'node:path';
import {performance} from 'node:perf_hooks';
import {usageReceipt, errorCode} from './auxiliary.js';
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
  const queue = new Set();
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
      record.agreement?.afterExit !== 'continue') throw new NotesTaskError('task_agreement_changed');
    if (record.agreement.deadlineAtMs !== null && Date.now() >= record.agreement.deadlineAtMs)
      throw new NotesTaskError('deadline_expired', 'failed');
    owner?.guard();
    return record;
  }

  async function segment(id, rev, key, reserveMs, controller, owner, job) {
    guard(id, rev, controller.signal, owner);
    const claim = await store.claimStep(id, rev, key, {reserveMs,
      retryKnownSafe: step(store.read(id), key, rev)?.state === 'waiting'});
    const start = performance.now(), clock = new AbortController();
    const timeout = setTimeout(() => clock.abort(new NotesTaskError('execution_budget_exhausted', 'failed')), claim.reserveMs);
    timeout.unref?.();
    const signal = AbortSignal.any([controller.signal, clock.signal]);
    const current = () => guard(id, rev, signal, owner);
    try {
      current();
      const result = await owner.runTurn(turnSignal => job({claim, signal: AbortSignal.any([signal, turnSignal]),
        guard: () => {turnSignal.throwIfAborted(); return current();}, elapsed: () => duration(start)}));
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
        await store.finishStep(claim, {state, reason: error.notesReason ?? (key === 'model' ? 'model_unconfirmed' : 'step_unavailable'),
          result: error.notesPreflightProof ?? null, elapsedMs: duration(start)});
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
      const receipt = {provider: owner.selected.provider, model: owner.selected.model,
        rawUsageAvailable: capability.rawUsage === 'deepseek-messages-cumulative',
        dispatched: false, dispatchAtMs: null, handoffAtMs: null, httpStatus: null,
        startUsage: null, finalUsage: null, stopReason: null, complete: false, terminal: 'incomplete',
        normalizedUsage: [], runtimeFinishKind: null};
      let writes = Promise.resolve(), persistenceFailure = null, contextWindow = null, inputBudget = null;
      let streamEntered = false, transportObserved = false;
      const persistenceAbort = new AbortController();
      const callSignal = AbortSignal.any([signal, persistenceAbort.signal]);
      const observed = event => {
        const data = structuredClone(event);
        if (Buffer.byteLength(JSON.stringify(data)) > 65536) throw new NotesTaskError('model_usage_limit', 'failed');
        writes = writes.then(() => store.observeStep(claim, data));
        writes.catch(error => { persistenceFailure ??= error; persistenceAbort.abort(error); });
      };
      const observe = event => {
        transportObserved = true;
        if (event.type === 'dispatch') {receipt.dispatched = true; receipt.dispatchAtMs = event.atMs;}
        else if (event.type === 'handoff') {receipt.dispatched = null; receipt.handoffAtMs = event.atMs;}
        else if (event.type === 'http') receipt.httpStatus = event.status;
        else if (event.type === 'stop') receipt.stopReason = event.stopReason;
        else if (event.type === 'complete') receipt.complete = true;
        else if (event.type === 'usage') {
          if (!event.raw || typeof event.raw !== 'object' || Array.isArray(event.raw)) throw new NotesTaskError('model_usage_invalid', 'failed');
          if (event.event === 'message_start') receipt.startUsage = structuredClone(event.raw);
          else if (event.event === 'message_delta') receipt.finalUsage = structuredClone(event.raw);
          else throw new NotesTaskError('model_usage_invalid', 'failed');
        }
        observed(dataObservation(event));
      };
      const check = () => {callSignal.throwIfAborted(); current(); if (persistenceFailure) throw persistenceFailure;};
      const checkRequest = (body, boundary) => {
        inputBudget = {...notesInputEstimate(body, contextWindow), boundary};
        return Number.isSafeInteger(contextWindow) && inputBudget.accepted;
      };
      let text = '', outputBytes = 0, finish = null, caught = null;
      try {
        const reasoningEffort = receipt.rawUsageAvailable ? 'off' : owner.selected.reasoningEffort;
        const call = await owner.llm.prepareCompanionAuxiliaryCall({provider: receipt.provider, model: receipt.model,
          ...(reasoningEffort === undefined ? {} : {reasoningEffort}), maxTokens: NOTES_LIMITS.outputTokens},
          callSignal, {guard: check, observe, checkRequest});
        check();
        contextWindow = call.contextWindow;
        if (!Number.isSafeInteger(contextWindow) || contextWindow <= 0) throw new NotesTaskError('model_context_window_unknown');
        if (!notesInputEstimate(estimateBody, contextWindow).accepted) throw new NotesTaskError('model_input_limit');
        if (call.config.provider !== receipt.provider || call.config.model !== receipt.model ||
          call.config.maxTokens !== NOTES_LIMITS.outputTokens || reasoningEffort !== undefined && call.config.reasoningEffort !== reasoningEffort)
          throw new NotesTaskError('model_selection_changed');
        streamEntered = true;
        for await (const chunk of call.stream({system: notesSystem, input})) {
          check();
          if (chunk.type === 'tool-call-delta' || chunk.type === 'block-start' && chunk.blockType === 'tool-call')
            throw new NotesTaskError('model_tool_output', 'failed');
          if (chunk.type === 'text-delta' || chunk.type === 'reasoning-delta') {
            if (typeof chunk.text !== 'string') throw new NotesTaskError('model_output_invalid', 'failed');
            outputBytes += Buffer.byteLength(chunk.text);
            if (outputBytes > NOTES_LIMITS.outputBytes) throw new NotesTaskError('model_output_limit', 'failed');
            if (chunk.type === 'text-delta') text += chunk.text;
          }
          if (chunk.type === 'finish') finish = chunk.reason;
          if (chunk.type === 'usage' && !receipt.rawUsageAvailable) {
            if (!chunk.usage || typeof chunk.usage !== 'object' || Array.isArray(chunk.usage))
              throw new NotesTaskError('model_usage_invalid', 'failed');
            receipt.normalizedUsage.push(structuredClone(chunk.usage));
            if (Buffer.byteLength(JSON.stringify(receipt.normalizedUsage)) > 65536)
              throw new NotesTaskError('model_usage_limit', 'failed');
            observed({type: 'runtime-usage', semantics: 'runtime-normalized', usage: chunk.usage});
          }
        }
        if (!receipt.rawUsageAvailable) {
          receipt.runtimeFinishKind = finish?.kind ?? null;
          receipt.complete = ['stop', 'max-tokens'].includes(finish?.kind) || ['REFUSAL', 'EMPTY_RESPONSE'].includes(finish?.failure?.code);
        }
        receipt.terminal = receipt.complete && finish?.kind === 'stop' ? 'complete'
          : finish?.kind === 'max-tokens' ? 'max_tokens' : finish?.kind === 'aborted' ? 'cancelled' : 'provider_error';
      } catch (error) {
        caught = error;
        if (receipt.dispatched === false && !transportObserved && !callSignal.aborted) {
          if (!(caught instanceof NotesTaskError)) caught = new NotesTaskError(
            errorCode(error) === 'COMPANION_LOOKUP_INPUT_LIMIT' ? 'model_input_limit' : 'model_preflight_unavailable');
          if (caught.notesState === 'waiting') caught.notesPreflightProof = {preflightDispatched: false, streamEntered};
        }
        receipt.terminal = callSignal.aborted ? 'cancelled' : receipt.dispatched === false ? 'preflight_error' : 'unconfirmed';
      }
      finally {
        // Await every observation and the original iterator's close before releasing the owner.
        await writes;
        const usage = usageReceipt(receipt);
        await store.observeStep(claim, {type: 'model-finish', dispatched: receipt.dispatched,
          httpStatus: receipt.httpStatus, usage, inputBudget,
          reason: caught ? errorCode(caught) : null});
      }
      if (caught) throw caught;
      check();
      if (receipt.terminal !== 'complete') throw new NotesTaskError('model_result_incomplete', receipt.complete ? 'failed' : 'unknown');
      const page = renderNotesPage(readNotesProposal(text, inputs), inputs);
      await store.saveCandidate(claim, {content: page.content,
        mediaType: current().agreement.args.outputName.toLowerCase().endsWith('.md') ? 'text/markdown' : 'text/plain',
        sourceCount: page.sourceCount, itemCount: page.itemCount, usage: usageReceipt(receipt)});
      return {sourceCount: page.sourceCount, itemCount: page.itemCount, inputBudget, usage: usageReceipt(receipt)};
    });
  }

  async function run(id, controller) {
    await reconcile(id);
    let record = store.read(id);
    if (closed || !record.originalCreate || record.cancelRequested || finished.has(record.state) ||
      unresolved(record)) return;
    if (record.agreement.afterExit !== 'continue') {await store.wait(id, record.taskRev, 'foreground_control_unavailable'); return;}
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
          // Recheck the fixed whole versions after staging, immediately before the durable
          // publication boundary. This is not an atomic snapshot against unrelated writers.
          for (const entry of notes.inputs.entries) {
            const actual = await fs.dshGoReadNote(notes.inputs.directory, entry, NOTES_LIMITS.fileBytes, signal);
            if (actual.sha256 !== entry.sha256) throw new NotesTaskError('input_changed');
          }
          current();
          await store.savePublishIntent(claim, reference);
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
      active = {id, revision: store.read(id).taskRev, controller};
      try {await run(id, controller);} catch { /* Durable unresolved facts remain for explicit recovery. */ }
      finally {controller.abort(); active = null;}
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
  return {wake, async stop() {
    closed = true; queue.clear(); active?.controller.abort(new NotesTaskError('task_owner_stopping'));
    await drain;
  }};
}

function dataObservation(event) {
  if (event.type === 'usage') return {type: 'usage', event: event.event, semantics: 'cumulative', raw: event.raw};
  if (event.type === 'dispatch' || event.type === 'handoff') return {type: event.type, atMs: event.atMs, boundary: event.boundary};
  if (event.type === 'http') return {type: 'http', status: event.status};
  if (event.type === 'stop') return {type: 'stop', stopReason: event.stopReason};
  if (event.type === 'complete') return {type: 'complete'};
  throw new NotesTaskError('model_observation_invalid', 'failed');
}
