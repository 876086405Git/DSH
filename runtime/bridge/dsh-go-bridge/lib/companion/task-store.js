import { randomUUID } from 'node:crypto';
import { isAbsolute } from 'node:path';
import { TASK_KIND, TASK_LIMIT_MS, createSchema, amendSchema, cancelSchema, folderSchema,
  folderRecordSchema, globalSchema, recordSchema, parseTask, taskError, fingerprint, taskAgreement, dayRange } from './task-schema.js';

const clone = value => structuredClone(value);
const terminal = new Set(['done', 'partial', 'failed', 'cancelled']);
const settled = step => step.finishedAtMs !== null;
const unresolvedEffect = record => record.steps.some(step => !settled(step) ||
  step.state === 'unknown' && step.stepKey === 'model' || step.stepKey === 'writePage' &&
  record.notes[String(step.taskRev)]?.publicationAttempted === true &&
  !record.artifacts.some(artifact => artifact.taskRev === step.taskRev && artifact.stepKey === 'writePage'));
const stepKeys = new Set(['selectInputs', 'readInputs', 'model', 'writePage']);

export async function openCompanionTaskStore({facility, fs, now = Date.now}) {
  if (typeof facility?.dshGoOpenCompanionTasks !== 'function') throw taskError(503, 'unavailable', 'Task storage is not mounted');
  const {defineDomain, domainTable} = await import('@deepseek-ai/dsh-storage-domain');
  const domain = await facility.dshGoOpenCompanionTasks(defineDomain({name: 'companion_tasks', version: 1, layout: 'single',
    global: {schema: globalSchema, initial: {v: 1, hostStoreId: null, createdAtMs: 0}},
    tables: {tasks: domainTable(recordSchema), folders: domainTable(folderRecordSchema)}}));
  const store = new CompanionTaskStore({domain, fs, now});
  domain.dshGoBindCompanionTaskOwner(() => store.stop());
  try {
    if (domain.global.get().hostStoreId === null) {
      if (domain.table('tasks').size || domain.table('folders').size) throw taskError(503, 'unavailable', 'Task store identity is missing');
      await domain.global.set({v: 1, hostStoreId: randomUUID(), createdAtMs: now()});
    }
    return store;
  } catch (error) { await domain.close(); throw error; }
}

// One aggregate commit is the transaction. Never mutate Domain's cached objects.
export class CompanionTaskStore {
  constructor({domain, fs, now = Date.now}) {
    this.domain = domain; this.fs = fs; this.now = now;
    this.table = domain.table('tasks'); this.folders = domain.table('folders');
    this.chain = Promise.resolve(); this.stopping = false; this.runner = null; this.stopped = null;
  }
  get hostStoreId() { return this.domain.global.get().hostStoreId; }
  attachRunner(runner) {
    if (this.runner || this.stopping || typeof runner?.stop !== 'function' || typeof runner?.wake !== 'function')
      throw taskError(503, 'unavailable', 'A live task runner is required');
    this.runner = runner;
  }
  async stop() {
    if (!this.stopped) {
      this.stopping = true;
      this.stopped = (async () => { await this.runner?.stop(); await this.chain; })();
    }
    return this.stopped;
  }
  async close() { await this.stop(); await this.domain.close(); }
  enqueue(job, finishing = false) {
    if (this.stopping && !finishing) return Promise.reject(taskError(503, 'unavailable', 'Task owner is stopping'));
    const result = this.chain.then(job);
    this.chain = result.then(() => {}, () => {});
    return result;
  }
  checkStore(id) {
    if (id !== this.hostStoreId) throw taskError(409, 'store-mismatch', 'This request belongs to another task store');
  }
  read(id) {
    const record = this.table.get(id);
    if (!record) throw taskError(404, 'not-found', 'Task is not present in this store');
    return clone(record);
  }
  snapshot(id) { return this.project(this.read(id)); }
  project(record) {
    const {originalCreate, originalFingerprint, operations, notes, execution, ...publicRecord} = clone(record);
    publicRecord.hostStoreId = this.hostStoreId;
    publicRecord.originalCreatePresent = originalCreate !== null;
    publicRecord.steps = record.steps.map(({reserveMs, finishFingerprint, ...step}) => clone(step));
    publicRecord.artifacts = record.artifacts.map(({identity, reference, ...artifact}) => clone(artifact));
    return publicRecord;
  }
  list(cursor) {
    let after = '';
    if (cursor !== undefined && cursor !== null) {
      try {
        const parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'));
        if (parsed.hostStoreId !== this.hostStoreId || typeof parsed.after !== 'string') throw new Error();
        after = parsed.after;
      } catch { throw taskError(400, 'invalid-request', 'Invalid task cursor'); }
    }
    const keys = [...this.table.keys()].sort().filter(id => id > after);
    const page = keys.slice(0, 50);
    const tasks = page.map(id => {
      const {taskId, hostExecutionId, taskRev, runnerReceiptSeq, kind, state, waitReason, updatedAtMs} = this.read(id);
      return {taskId, hostExecutionId, taskRev, runnerReceiptSeq, kind, state, waitReason, updatedAtMs};
    });
    return {v: 1, hostStoreId: this.hostStoreId, tasks, nextCursor: keys.length > page.length
      ? Buffer.from(JSON.stringify({hostStoreId: this.hostStoreId, after: page.at(-1)})).toString('base64url') : null};
  }
  runnable() {
    return [...this.table.entries()].filter(([, r]) => r.originalCreate !== null &&
      (!terminal.has(r.state) || r.steps.some(step => !settled(step)))).map(([id]) => id);
  }
  folder(id) {
    const record = this.folders.get(id);
    if (!record) throw taskError(400, 'invalid-request', 'The chosen directory is not bound to this store');
    return clone(record.directory);
  }
  bindFolder(input, signal) {
    const body = parseTask(folderSchema, input);
    this.checkStore(body.hostStoreId);
    if (!isAbsolute(body.path) || typeof this.fs?.dshGoBindNotesDirectory !== 'function')
      throw taskError(400, 'invalid-request', 'Choose an actual absolute host directory');
    return this.enqueue(async () => {
      const target = await this.fs.resolve(body.path, {signal});
      const directory = await this.fs.dshGoBindNotesDirectory(target, signal);
      const record = folderRecordSchema.parse({folderRef: randomUUID(), directory, createdAtMs: this.now()});
      await this.folders.put(record.folderRef, record);
      return {v: 1, hostStoreId: this.hostStoreId, folderRef: record.folderRef, displayPath: directory.target.displayPath};
    });
  }
  validateAgreement(agreement) {
    this.folder(agreement.args.folderRef); this.folder(agreement.args.outputDirRef);
    return dayRange(agreement);
  }
  fresh(id) {
    const now = this.now();
    return {v: 1, taskId: id, hostExecutionId: randomUUID(), kind: TASK_KIND, taskRev: 1, runnerReceiptSeq: 0,
      originalCreate: null, originalFingerprint: null, origin: null, hostSessionId: null,
      state: 'waiting', waitReason: 'original_create_missing', cancelRequested: false,
      createdAtMs: now, updatedAtMs: now, agreement: null, revisions: [], operations: {}, steps: [], artifacts: [],
      approval: null, budget: {limitMs: TASK_LIMIT_MS, spentMs: 0, heldMs: 0}, execution: null, notes: {}};
  }
  setPlanState(record) {
    record.approval = null;
    if (record.steps.some(step => !settled(step))) { record.state = 'unknown'; record.waitReason = 'prior_step_unresolved'; }
    else if (record.cancelRequested) { record.state = 'cancelled'; record.waitReason = null; }
    else if (record.artifacts.length) {
      record.state = record.artifacts.every(item => item.taskRev === record.taskRev) ? 'done' : 'partial';
      record.waitReason = record.state === 'partial' ? 'prior_revision_effect' : null;
    }
    else if (!record.originalCreate) { record.state = 'waiting'; record.waitReason = 'original_create_missing'; }
    else if (record.agreement.afterExit === 'pause') { record.state = 'waiting'; record.waitReason = 'foreground_control_unavailable'; }
    else if (record.agreement.deadlineAtMs !== null && this.now() >= record.agreement.deadlineAtMs) {
      record.state = 'failed'; record.waitReason = 'deadline_expired';
    } else { record.state = 'running'; record.waitReason = null; }
  }
  async commit(record) {
    record.runnerReceiptSeq++; record.updatedAtMs = this.now();
    const checked = recordSchema.parse(record);
    await this.table.put(record.taskId, checked);
    return this.project(checked);
  }
  wake(id) { try { this.runner?.wake(id); } catch { /* Persisted work remains queryable and resumable. */ } }
  create(input) {
    const body = parseTask(createSchema, input); this.checkStore(body.hostStoreId);
    return this.enqueue(async () => {
      const stored = this.table.get(body.taskId), record = stored ? clone(stored) : this.fresh(body.taskId);
      const hash = fingerprint(body);
      if (record.originalFingerprint !== null) {
        if (record.originalFingerprint !== hash) throw taskError(409, 'conflict', 'Task ID has another original creation', this.project(record));
        if (!terminal.has(record.state)) this.wake(record.taskId);
        return {created: false, snapshot: this.project(record)};
      }
      const agreement = taskAgreement(body);
      const range = this.validateAgreement(agreement);
      record.originalCreate = body; record.originalFingerprint = hash;
      record.origin = body.origin; record.hostSessionId = body.hostSessionId;
      record.revisions.unshift({taskRev: 1, operation: 'create', acceptedAtMs: this.now(), agreement});
      if (record.taskRev === 1) record.agreement = agreement;
      record.notes['1'] = {dayRange: range};
      this.setPlanState(record);
      const snapshot = await this.commit(record);
      this.wake(record.taskId);
      return {created: !stored, snapshot};
    });
  }
  operation(id, input, cancel) {
    const body = parseTask(cancel ? cancelSchema : amendSchema, input); this.checkStore(body.hostStoreId);
    return this.enqueue(async () => {
      const stored = this.table.get(id), record = stored ? clone(stored) : this.fresh(id);
      const hash = fingerprint({cancel, body});
      const previous = Object.hasOwn(record.operations, body.operationId) ? record.operations[body.operationId] : undefined;
      if (previous) {
        if (previous.fingerprint !== hash) throw taskError(409, 'conflict', 'Operation ID has another request', this.project(record));
        return this.project(record);
      }
      if (stored && record.cancelRequested && body.taskRev <= record.taskRev) return this.project(record);
      if (stored && (record.originalCreate !== null ? body.expectedTaskRev !== record.taskRev : body.taskRev <= record.taskRev))
        throw taskError(409, 'conflict', 'Task agreement revision changed', this.project(record));
      if (!cancel && record.artifacts.length) throw taskError(409, 'conflict', 'This task already has a published result', this.project(record));
      const agreement = cancel ? record.agreement : body.changes;
      const range = cancel ? null : this.validateAgreement(agreement);
      record.taskRev = body.taskRev; record.agreement = agreement; record.cancelRequested = cancel;
      record.operations[body.operationId] = {fingerprint: hash, taskRev: body.taskRev};
      record.revisions.push({taskRev: body.taskRev, operation: cancel ? 'cancel' : 'amend', acceptedAtMs: this.now(), agreement});
      if (!cancel) record.notes[String(body.taskRev)] = {dayRange: range};
      this.setPlanState(record);
      const snapshot = await this.commit(record);
      this.wake(id);
      return snapshot;
    });
  }
  amend(id, body) { return this.operation(id, body, false); }
  cancel(id, body) { return this.operation(id, body, true); }
  current(record, taskRev, physical = true) {
    if (record.taskRev !== taskRev || record.cancelRequested || !record.originalCreate)
      throw taskError(409, 'conflict', 'The task agreement no longer authorizes this step', this.project(record));
    if (physical && (record.agreement.afterExit !== 'continue' || terminal.has(record.state) ||
      record.agreement.deadlineAtMs !== null && this.now() >= record.agreement.deadlineAtMs))
      throw taskError(409, 'conflict', 'The current task is not runnable', this.project(record));
  }
  findClaim(record, claim) {
    const step = record.steps.find(s => s.taskRev === claim.taskRev && s.stepKey === claim.stepKey && s.attemptId === claim.attemptId);
    if (!step) throw taskError(409, 'conflict', 'The original task step claim is missing', this.project(record));
    return step;
  }
  bindExecution(id, taskRev, execution) {
    return this.enqueue(async () => {
      const record = this.read(id); this.current(record, taskRev, false);
      if (record.execution && record.execution.agentId !== execution.agentId)
        throw taskError(409, 'conflict', 'The task already owns another agent', this.project(record));
      record.execution = clone(execution); return this.commit(record);
    });
  }
  claimStep(id, taskRev, stepKey, {reserveMs, retryKnownSafe = false}) {
    return this.enqueue(async () => {
      const record = this.read(id); this.current(record, taskRev);
      if (!stepKeys.has(stepKey) || !Number.isSafeInteger(reserveMs) || reserveMs <= 0)
        throw taskError(400, 'invalid-request', 'Invalid fixed task step');
      const previous = record.steps.findLast(step => step.taskRev === taskRev && step.stepKey === stepKey);
      if (record.steps.some(step => !settled(step)) || previous && (!retryKnownSafe || !this.retryable(record, previous)))
        throw taskError(409, 'conflict', 'An original step must be reconciled before another claim', this.project(record));
      const remaining = TASK_LIMIT_MS - record.budget.spentMs - record.budget.heldMs;
      const deadlineMs = record.agreement.deadlineAtMs === null ? remaining : record.agreement.deadlineAtMs - this.now();
      const held = Math.min(reserveMs, remaining, deadlineMs);
      if (held <= 0) {
        record.state = unresolvedEffect(record) ? 'unknown' : 'failed'; record.waitReason = 'execution_budget_exhausted';
        const snapshot = await this.commit(record);
        throw taskError(409, 'conflict', 'The task execution budget is exhausted', snapshot);
      }
      const step = {taskRev, stepKey, attemptId: randomUUID(), state: 'running', startedAtMs: this.now(), finishedAtMs: null,
        reason: null, result: null, reserveMs: held, finishFingerprint: null};
      record.steps.push(step); record.budget.heldMs += held; record.state = 'running'; record.waitReason = null; record.approval = null;
      await this.commit(record);
      return {taskId: id, taskRev, stepKey, attemptId: step.attemptId, reserveMs: held, deadlineAtMs: record.agreement.deadlineAtMs};
    });
  }
  retryable(record, previous) {
    if (!settled(previous) || previous.state !== 'waiting') return false;
    const notes = record.notes[String(previous.taskRev)];
    if (previous.stepKey === 'selectInputs') return !notes?.selection;
    if (previous.stepKey === 'readInputs') return !!notes?.selection && !notes.inputs;
    if (previous.stepKey === 'writePage') return previous.result?.completion?.publicationNotAttempted === true &&
      !!notes?.publishIntent && !!notes.candidate && notes.publicationAttempted !== true && record.artifacts.length === 0;
    if (previous.stepKey !== 'model' || notes?.candidate) return false;
    const proof = previous.result?.completion, observations = previous.result?.observations ?? [];
    const physical = new Set(['dispatch','handoff','http','usage','runtime-usage','stop','complete']);
    if (proof?.preflightDispatched !== false || observations.some(event => physical.has(event.type) ||
      event.dispatched === true || event.type === 'model-finish' && event.dispatched === null)) return false;
    const last = observations.findLast(event => event.type === 'model-finish');
    return last ? last.dispatched === false : proof.streamEntered === false;
  }
  savePrivate(claim, key, value) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId); this.findClaim(record, claim);
      const notes = record.notes[String(claim.taskRev)];
      if (!notes) throw taskError(409, 'conflict', 'The original task agreement is missing');
      if (notes[key] && fingerprint(notes[key]) !== fingerprint(value))
        throw taskError(409, 'conflict', 'The original task result is already saved', this.project(record));
      if (notes[key]) return this.project(record);
      notes[key] = clone(value); return this.commit(record);
    }, true);
  }
  saveSelection(claim, selection) { return this.savePrivate(claim, 'selection', selection); }
  saveInputs(claim, input) { return this.savePrivate(claim, 'inputs', input); }
  saveCandidate(claim, candidate) { return this.savePrivate(claim, 'candidate', candidate); }
  savePublishIntent(claim, reference) { return this.savePrivate(claim, 'publishIntent', reference); }
  observeStep(claim, observation) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId), step = this.findClaim(record, claim);
      step.result ??= {};
      step.result.observations ??= [];
      step.result.observations.push(clone(observation));
      return this.commit(record);
    }, true);
  }
  settle(record, step, completion) {
    if (completion.elapsedMs !== null && (!Number.isSafeInteger(completion.elapsedMs) || completion.elapsedMs < 0))
      throw taskError(400, 'invalid-request', 'Elapsed task time must be observed or unknown');
    step.state = completion.state; step.reason = completion.reason ?? null; step.finishedAtMs = this.now();
    if (completion.result !== undefined && completion.result !== null)
      step.result = {...step.result, completion: clone(completion.result)};
    if (completion.elapsedMs !== null) {
      record.budget.heldMs -= step.reserveMs;
      record.budget.spentMs += completion.elapsedMs;
    }
  }
  finishStep(claim, completion) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId), step = this.findClaim(record, claim), hash = fingerprint(completion);
      if (step.finishFingerprint) {
        if (step.finishFingerprint !== hash) throw taskError(409, 'conflict', 'The original step already has a completion', this.project(record));
        return this.project(record);
      }
      this.settle(record, step, completion); step.finishFingerprint = hash;
      if (record.taskRev === claim.taskRev && !record.cancelRequested) {
        if (completion.state === 'unknown' || completion.state === 'failed') {
          record.state = completion.state; record.waitReason = completion.reason ?? null;
        }
      } else this.setPlanState(record);
      return this.commit(record);
    }, true);
  }
  wait(id, taskRev, reason, approval = null) {
    return this.enqueue(async () => {
      const record = this.read(id); this.current(record, taskRev, false);
      if (record.steps.some(step => !settled(step))) throw taskError(409, 'conflict', 'Settle the active time claim before waiting');
      record.state = 'waiting'; record.waitReason = reason; record.approval = approval;
      return this.commit(record);
    }, true);
  }
  stopPlan(id, taskRev, state, reason) {
    return this.enqueue(async () => {
      const record = this.read(id); this.current(record, taskRev, false);
      if (!['failed','partial'].includes(state) || state === 'partial' && !record.artifacts.length)
        throw taskError(400, 'invalid-request', 'A stopped partial task requires a real artifact');
      if (terminal.has(record.state)) return this.project(record);
      record.state = unresolvedEffect(record) ? 'unknown' : state;
      record.waitReason = record.state === 'unknown' ? 'prior_step_unresolved' : reason;
      record.approval = null;
      return this.commit(record);
    }, true);
  }
  saveApproval(id, taskRev, binding) {
    return this.enqueue(async () => {
      const record = this.read(id), notes = record.notes[String(taskRev)];
      if (!notes) throw taskError(409, 'conflict', 'The original approval agreement is missing');
      if (binding.outcome === null && (record.taskRev !== taskRev || record.cancelRequested))
        throw taskError(409, 'conflict', 'The task revision no longer accepts this pending approval', this.project(record));
      if (notes.approval && fingerprint(notes.approval) === fingerprint(binding)) return this.project(record);
      notes.approval = clone(binding);
      if (record.taskRev === taskRev && !record.cancelRequested) {
        if (record.steps.some(step => !settled(step))) throw taskError(409, 'conflict', 'Settle execution time before approval waiting');
        record.state = 'waiting'; record.waitReason = binding.outcome === null ? 'approval' : `approval_${binding.outcome}`;
        record.approval = binding.eventId && binding.outcome === null ?
          {taskRev, stepKey: binding.stepKey, agentId: binding.agentId, approvalId: binding.approvalId,
            eventId: binding.eventId, callId: binding.callId} : null;
      }
      return this.commit(record);
    }, true);
  }
  publish(claim, job) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId); this.current(record, claim.taskRev);
      const step = this.findClaim(record, claim), notes = record.notes[String(claim.taskRev)];
      if (claim.stepKey !== 'writePage' || settled(step) || !notes?.publishIntent || !notes.candidate || notes.publicationAttempted === true || record.artifacts.length)
        throw taskError(409, 'conflict', 'The original publication intent is not runnable', this.project(record));
      // Durable possible-send boundary: even a crash before the actual link consumes this attempt.
      notes.publicationAttempted = true; notes.publicationAttemptId = claim.attemptId;
      await this.commit(record);
      this.current(record, claim.taskRev);
      try {
        const result = await job(clone(notes.publishIntent), clone(record));
        const artifact = {...clone(result.artifact), artifactId: randomUUID(), taskRev: claim.taskRev, stepKey: 'writePage',
          reference: clone(notes.publishIntent)};
        record.artifacts.push(artifact);
        this.settle(record, step, {state: 'done', reason: null, result: {artifactId: artifact.artifactId}, elapsedMs: result.elapsedMs});
        step.finishFingerprint = fingerprint({artifactId: artifact.artifactId});
        record.state = result.state ?? 'done'; record.waitReason = result.reason ?? null; record.approval = null;
        return await this.commit(record);
      } catch (error) {
        // A physical call or the subsequent commit may already have taken effect.
        if (error?.code === 'unknown-state') throw error;
        const current = this.read(claim.taskId), originalStep = this.findClaim(current, claim);
        originalStep.state = 'unknown'; originalStep.reason = 'publication_unconfirmed';
        current.state = 'unknown'; current.waitReason = 'publication_unconfirmed';
        await this.commit(current);
        throw error;
      }
    });
  }
  // Read-only reconciliation supplies a verified existing effect; this method never links a file.
  recordArtifact(claim, result) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId), step = this.findClaim(record, claim);
      const notes = record.notes[String(claim.taskRev)], intent = notes?.publishIntent;
      if (claim.stepKey !== 'writePage' || !intent || notes.publicationAttempted !== true || notes.publicationAttemptId !== claim.attemptId)
        throw taskError(409, 'conflict', 'The original publication attempt is not bound to this claim');
      const previous = record.artifacts.find(item => item.taskRev === claim.taskRev && item.stepKey === 'writePage');
      if (previous) {
        if (previous.identity !== result.artifact.identity || previous.sha256 !== result.artifact.sha256)
          throw taskError(409, 'conflict', 'The recorded original artifact differs', this.project(record));
        return this.project(record);
      }
      const artifact = {...clone(result.artifact), artifactId: randomUUID(), taskRev: claim.taskRev, stepKey: 'writePage', reference: clone(intent)};
      record.artifacts.push(artifact);
      if (!settled(step)) this.settle(record, step, {state: 'done', reason: null, result: {artifactId: artifact.artifactId}, elapsedMs: result.elapsedMs});
      else { step.state = 'done'; step.reason = null; step.result = {...step.result, completion: {artifactId: artifact.artifactId}}; }
      step.finishFingerprint = fingerprint({artifactId: artifact.artifactId});
      if (record.taskRev === claim.taskRev && !record.cancelRequested) { record.state = result.state ?? 'done'; record.waitReason = result.reason ?? null; }
      else this.setPlanState(record);
      return this.commit(record);
    }, true);
  }
  async artifact(id, artifactId, signal) {
    const record = this.read(id), artifact = record.artifacts.find(value => value.artifactId === artifactId);
    if (!artifact) throw taskError(404, 'artifact-not-found', 'Artifact is not recorded for this task');
    const envelope = {v: 1, hostStoreId: this.hostStoreId, taskId: id, hostExecutionId: record.hostExecutionId,
      artifactId, mediaType: artifact.mediaType, content: null, reason: null};
    try {
      const read = await this.fs.dshGoReadNotesArtifact(artifact.reference.directory, artifact.relativePath, artifact, signal);
      return {...envelope, status: 'available', content: read.text};
    } catch (error) {
      if (error?.code === 'FS_NOT_FOUND' || error?.code === 'ENOENT') return {...envelope, status: 'missing', reason: 'original_missing'};
      if (error?.code === 'FS_STALE_VERSION') return {...envelope, status: 'changed', reason: 'original_changed'};
      return {...envelope, status: 'unknown', reason: 'original_unavailable'};
    }
  }
}
