import { randomUUID } from 'node:crypto';
import { isAbsolute, join } from 'node:path';
import { TASK_KIND, FIND_KIND, COMPARE_KIND, RECEIPT_KIND, XLSX_TYPE, TASK_LIMIT_MS, createSchema, amendSchema, cancelSchema, folderSchema, foregroundSchema,
  inputSchema, inputRecordSchema, folderRecordSchema, globalSchema, recordSchema, parseTask, taskError, fingerprint, taskAgreement, dayRange } from './task-schema.js';

const clone = value => structuredClone(value);
const terminal = new Set(['done', 'partial', 'failed', 'cancelled']);
const settled = step => step.finishedAtMs !== null;
const writeKey = record => record.kind === RECEIPT_KIND ? 'writeSheet' : 'writePage';
const unresolvedEffect = record => record.steps.some(step => !settled(step) ||
  step.state === 'unknown' && step.stepKey === 'model' || step.stepKey === writeKey(record) &&
  record.notes[String(step.taskRev)]?.publicationAttempted === true &&
  !record.artifacts.some(artifact => artifact.taskRev === step.taskRev && artifact.stepKey === writeKey(record)));
const stepKeys = new Set(['selectInputs', 'readInputs', 'model', 'writePage', 'report', 'writeSheet']);

export async function openCompanionTaskStore({facility, fs, now = Date.now}) {
  if (typeof facility?.dshGoOpenCompanionTasks !== 'function') throw taskError(503, 'unavailable', 'Task storage is not mounted');
  const {defineDomain, domainTable} = await import('@deepseek-ai/dsh-storage-domain');
  const domain = await facility.dshGoOpenCompanionTasks(defineDomain({name: 'companion_tasks', version: 3, compatibleVersions: [1, 2], layout: 'single',
    global: {schema: globalSchema, initial: {v: 1, hostStoreId: null, createdAtMs: 0}},
    tables: {tasks: domainTable(recordSchema), folders: domainTable(folderRecordSchema), inputs: domainTable(inputRecordSchema)}}));
  const store = new CompanionTaskStore({domain, fs, now});
  domain.dshGoBindCompanionTaskOwner(() => store.stop());
  try {
    if (domain.global.get().hostStoreId === null) {
      if (domain.table('tasks').size || domain.table('folders').size || domain.table('inputs').size)
        throw taskError(503, 'unavailable', 'Task store identity is missing');
      await domain.global.set({v: 1, hostStoreId: randomUUID(), createdAtMs: now()});
    }
    return store;
  } catch (error) { await domain.close(); throw error; }
}

// One aggregate commit is the transaction. Never mutate Domain's cached objects.
export class CompanionTaskStore {
  constructor({domain, fs, now = Date.now}) {
    this.domain = domain; this.fs = fs; this.now = now;
    this.table = domain.table('tasks'); this.folders = domain.table('folders'); this.inputs = domain.table('inputs');
    this.chain = Promise.resolve(); this.stopping = false; this.runner = null; this.stopped = null;
    this.observers = new Map();
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
  observe(id, listener) {
    const listeners = this.observers.get(id) ?? new Set();
    listeners.add(listener); this.observers.set(id, listeners);
    return () => { listeners.delete(listener); if (!listeners.size) this.observers.delete(id); };
  }
  executionAllowed(record) {
    return record.agreement?.afterExit === 'continue' || record.kind === TASK_KIND &&
      record.agreement?.afterExit === 'pause' && this.runner?.foregroundActive?.(record.taskId, record.taskRev) === true;
  }
  foreground(id, input, signal) {
    const body = parseTask(foregroundSchema, input); this.checkStore(body.hostStoreId);
    if (this.stopping || typeof this.runner?.foreground !== 'function')
      throw taskError(503, 'unavailable', 'Notes foreground execution is unavailable');
    signal.throwIfAborted();
    const record = this.read(id); this.current(record, body.taskRev, false);
    if (record.kind !== TASK_KIND || record.agreement.afterExit !== 'pause' ||
        record.hostExecutionId !== body.hostExecutionId || record.origin.sourceSessionId !== body.sourceSessionId ||
        terminal.has(record.state) || record.agreement.deadlineAtMs !== null && this.now() >= record.agreement.deadlineAtMs)
      throw taskError(409, 'conflict', 'The original foreground notes agreement is not current', this.project(record));
    return this.runner.foreground(id, body.taskRev, signal);
  }
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
  input(reference) {
    const record = this.inputs.get(reference.sourceRef);
    if (!record || record.entry.version !== reference.version)
      throw taskError(400, 'invalid-request', 'The original selected file version is not bound to this store');
    return clone(record);
  }
  bindInput(input, signal) {
    const body = parseTask(inputSchema, input); this.checkStore(body.hostStoreId);
    return this.enqueue(async () => {
      const receipt = body.kind === RECEIPT_KIND, limit = receipt ? 4194304 : 65536;
      if (receipt && /\.pdf$/iu.test(body.name) && !this.runner?.receiptFormats?.includes('pdf'))
        throw taskError(400, 'input-unavailable', 'This host does not support PDF text extraction');
      const directory = this.folder(body.folderRef);
      const checkDirectory = async () => {
        const current = await this.fs.dshGoBindNotesDirectory(directory.target, signal);
        if (current.identity !== directory.identity || current.target.targetKey !== directory.target.targetKey)
          throw taskError(409, 'input-changed', 'The selected directory was replaced');
      };
      await checkDirectory();
      const info = await this.fs.lstat(join(directory.target.displayPath, body.name), undefined, signal);
      if (!info || info.type !== 'file' || info.size > limit)
        throw taskError(400, 'input-unavailable', receipt ? 'Choose one supported regular receipt of at most 4 MiB' :
          'Choose one regular text or Markdown file of at most 64 KiB');
      await checkDirectory();
      const record = inputRecordSchema.parse({sourceRef: randomUUID(), directory,
        entry: {name: body.name, version: info.version, size: info.size}, createdAtMs: this.now()});
      await this.inputs.put(record.sourceRef, record);
      return {v: 1, hostStoreId: this.hostStoreId, sourceRef: record.sourceRef, displayName: body.name,
        version: info.version, size: info.size, mediaType: /\.pdf$/iu.test(body.name) ? 'application/pdf' :
          /\.md$/iu.test(body.name) ? 'text/markdown' : 'text/plain'};
    });
  }
  validateAgreement(agreement, kind) {
    if (kind === COMPARE_KIND) {
      for (const reference of [agreement.args.a, agreement.args.b]) {
        const selected = this.input(reference);
        if (selected.entry.size > 65536 || !/\.(md|txt)$/iu.test(selected.entry.name))
          throw taskError(400, 'invalid-request', 'A comparison requires two text drafts of at most 64 KiB each');
      }
      return null;
    }
    if (kind === RECEIPT_KIND) {
      const seen = new Set();
      for (const reference of agreement.args.inputs) {
        const selected = this.input(reference), extension = selected.entry.name.split('.').at(-1).toLowerCase();
        if (selected.entry.size > 4194304 || !['md', 'txt', 'pdf'].includes(extension) ||
            extension === 'pdf' && !this.runner?.receiptFormats?.includes('pdf'))
          throw taskError(400, 'invalid-request', 'The selected receipt format or size is unavailable');
        const identity = JSON.stringify([selected.directory.identity, selected.directory.target.targetKey,
          selected.entry.name, selected.entry.version]);
        if (seen.has(identity)) throw taskError(400, 'invalid-request', 'Choose four distinct original receipts');
        seen.add(identity);
      }
      this.folder(agreement.args.outputDirRef);
      return null;
    }
    this.folder(agreement.args.folderRef);
    if (agreement.args.outputDirRef !== undefined) this.folder(agreement.args.outputDirRef);
    return dayRange(agreement);
  }
  fresh(id, kind = TASK_KIND) {
    const now = this.now();
    return {v: 1, taskId: id, hostExecutionId: randomUUID(), kind, taskRev: 1, runnerReceiptSeq: 0,
      originalCreate: null, originalFingerprint: null, origin: null, hostSessionId: null,
      state: 'waiting', waitReason: 'original_create_missing', cancelRequested: false,
      createdAtMs: now, updatedAtMs: now, agreement: null, revisions: [], operations: {}, steps: [], artifacts: [],
      approval: null, budget: {limitMs: TASK_LIMIT_MS, spentMs: 0, heldMs: 0}, execution: null, notes: {}};
  }
  setPlanState(record) {
    record.approval = null;
    if (record.steps.some(step => !settled(step))) { record.state = 'unknown'; record.waitReason = 'prior_step_unresolved'; }
    else if (record.cancelRequested) { record.state = 'cancelled'; record.waitReason = null; }
    else if (record.kind === FIND_KIND && record.steps.some(step => step.taskRev === record.taskRev &&
      step.stepKey === 'readInputs' && settled(step) && step.result?.completion?.scope && ['done','partial'].includes(step.state))) {
      const step = record.steps.findLast(step => step.taskRev === record.taskRev && step.stepKey === 'readInputs');
      record.state = step.state; record.waitReason = step.reason;
    }
    else if (record.kind === COMPARE_KIND && record.steps.some(step => step.taskRev === record.taskRev &&
      step.stepKey === 'report' && settled(step) && step.result?.completion?.published === true)) {
      const step = record.steps.findLast(step => step.taskRev === record.taskRev && step.stepKey === 'report');
      record.state = step.state; record.waitReason = step.reason;
    }
    else if (record.kind === RECEIPT_KIND && record.artifacts.some(value => value.taskRev === record.taskRev)) {
      const step = record.steps.findLast(value => value.taskRev === record.taskRev && value.stepKey === 'writeSheet');
      record.state = step?.state === 'partial' ? 'partial' : 'done'; record.waitReason = step?.reason ?? null;
    }
    else if (record.artifacts.length) {
      record.state = record.artifacts.every(item => item.taskRev === record.taskRev) ? 'done' : 'partial';
      record.waitReason = record.state === 'partial' ? 'prior_revision_effect' : null;
    }
    else if (!record.originalCreate) { record.state = 'waiting'; record.waitReason = 'original_create_missing'; }
    else if (record.agreement.afterExit === 'pause' && !this.executionAllowed(record)) {
      record.state = 'waiting'; record.waitReason = record.kind === TASK_KIND && this.runner?.foreground
        ? 'foreground_required' : 'foreground_control_unavailable';
    }
    else if (record.agreement.deadlineAtMs !== null && this.now() >= record.agreement.deadlineAtMs) {
      record.state = 'failed'; record.waitReason = 'deadline_expired';
    } else { record.state = 'running'; record.waitReason = null; }
  }
  async commit(record) {
    record.runnerReceiptSeq++; record.updatedAtMs = this.now();
    const checked = recordSchema.parse(record);
    await this.table.put(record.taskId, checked);
    const snapshot = this.project(checked);
    for (const listener of this.observers.get(record.taskId) ?? []) {
      // A disconnected reader cannot undo the already durable receipt.
      try { listener(snapshot); } catch {}
    }
    return snapshot;
  }
  wake(id) { try { this.runner?.wake(id); } catch { /* Persisted work remains queryable and resumable. */ } }
  create(input) {
    const body = parseTask(createSchema, input); this.checkStore(body.hostStoreId);
    return this.enqueue(async () => {
      const stored = this.table.get(body.taskId), record = stored ? clone(stored) : this.fresh(body.taskId, body.kind);
      if (record.kind !== body.kind) throw taskError(409, 'conflict', 'The task kind is immutable', this.project(record));
      const hash = fingerprint(body);
      if (record.originalFingerprint !== null) {
        if (record.originalFingerprint !== hash) throw taskError(409, 'conflict', 'Task ID has another original creation', this.project(record));
        if (!terminal.has(record.state)) this.wake(record.taskId);
        return {created: false, snapshot: this.project(record)};
      }
      const agreement = taskAgreement(body);
      const range = this.validateAgreement(agreement, body.kind);
      record.originalCreate = body; record.originalFingerprint = hash;
      record.origin = body.origin; record.hostSessionId = body.hostSessionId;
      record.revisions.unshift({taskRev: 1, operation: 'create', acceptedAtMs: this.now(), agreement});
      if (record.taskRev === 1) record.agreement = agreement;
      record.notes['1'] = [COMPARE_KIND, RECEIPT_KIND].includes(body.kind) ? {} : {dayRange: range};
      this.setPlanState(record);
      const snapshot = await this.commit(record);
      this.wake(record.taskId);
      return {created: !stored, snapshot};
    });
  }
  operation(id, input, cancel) {
    const body = parseTask(cancel ? cancelSchema : amendSchema, input); this.checkStore(body.hostStoreId);
    return this.enqueue(async () => {
      const kind = body.kind ?? TASK_KIND;
      const stored = this.table.get(id), record = stored ? clone(stored) : this.fresh(id, kind);
      if (record.kind !== kind) throw taskError(409, 'conflict', 'The task kind is immutable', this.project(record));
      const hash = fingerprint({cancel, body});
      const previous = Object.hasOwn(record.operations, body.operationId) ? record.operations[body.operationId] : undefined;
      if (previous) {
        if (previous.fingerprint !== hash) throw taskError(409, 'conflict', 'Operation ID has another request', this.project(record));
        return this.project(record);
      }
      if (stored && record.cancelRequested && body.taskRev <= record.taskRev) return this.project(record);
      if (!cancel && [FIND_KIND, COMPARE_KIND].includes(record.kind) && record.cancelRequested)
        throw taskError(409, 'conflict', 'A cancelled read task requires a new explicit task', this.project(record));
      if (stored && (record.originalCreate !== null ? body.expectedTaskRev !== record.taskRev : body.taskRev <= record.taskRev))
        throw taskError(409, 'conflict', 'Task agreement revision changed', this.project(record));
      if (!cancel && record.artifacts.length) throw taskError(409, 'conflict', 'This task already has a published result', this.project(record));
      const agreement = cancel ? record.agreement : body.changes;
      const range = cancel ? null : this.validateAgreement(agreement, record.kind);
      record.taskRev = body.taskRev; record.agreement = agreement; record.cancelRequested = cancel;
      record.operations[body.operationId] = {fingerprint: hash, taskRev: body.taskRev};
      record.revisions.push({taskRev: body.taskRev, operation: cancel ? 'cancel' : 'amend', acceptedAtMs: this.now(), agreement});
      if (!cancel) record.notes[String(body.taskRev)] = [COMPARE_KIND, RECEIPT_KIND].includes(record.kind) ? {} : {dayRange: range};
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
    if (physical && (!this.executionAllowed(record) || terminal.has(record.state) ||
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
      if (record.kind === FIND_KIND && !['selectInputs','readInputs'].includes(stepKey))
        throw taskError(400, 'invalid-request', 'Find tasks have only fixed read steps');
      if (record.kind === COMPARE_KIND && !['readInputs','model','report'].includes(stepKey) ||
          record.kind === RECEIPT_KIND && !['readInputs', 'writeSheet'].includes(stepKey) ||
          record.kind === TASK_KIND && ['report', 'writeSheet'].includes(stepKey))
        throw taskError(400, 'invalid-request', 'This task has no such fixed step');
      if (record.kind === COMPARE_KIND && stepKey === 'model' && record.steps.some(step => step.stepKey === 'model'))
        throw taskError(409, 'conflict', 'This comparison already owns its one model attempt', this.project(record));
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
    if (record.kind === RECEIPT_KIND && previous.stepKey === 'readInputs')
      return settled(previous) && previous.state === 'waiting' && previous.reason === 'receipt_read_interrupted' &&
        !record.notes[String(previous.taskRev)]?.inputs;
    if (record.kind === RECEIPT_KIND && previous.stepKey === 'writeSheet') {
      const notes = record.notes[String(previous.taskRev)];
      return settled(previous) && previous.state === 'waiting' &&
        previous.result?.completion?.publicationNotAttempted === true && !!notes?.inputs &&
        notes.publicationAttempted !== true && (!notes.publishIntent || !!notes.candidate) && record.artifacts.length === 0;
    }
    if (record.kind === COMPARE_KIND && previous.stepKey === 'report')
      return settled(previous) && (previous.state === 'unknown' && previous.reason === 'report_interrupted' &&
        previous.result?.completion === undefined || previous.state === 'partial' &&
        previous.reason === 'report_owner_stopped' && previous.result?.completion?.published === false);
    if (!settled(previous) || previous.state !== 'waiting') return false;
    const notes = record.notes[String(previous.taskRev)];
    if (previous.stepKey === 'selectInputs') return !notes?.selection;
    if (previous.stepKey === 'readInputs') return !!notes?.selection && !notes.inputs;
    if (previous.stepKey === writeKey(record)) return previous.result?.completion?.publicationNotAttempted === true &&
      (!!notes?.publishIntent || record.kind === TASK_KIND && record.agreement.afterExit === 'pause' &&
        ['foreground_withdrawn', 'task_owner_stopping'].includes(previous.reason)) &&
      !!notes?.candidate && notes.publicationAttempted !== true && record.artifacts.length === 0;
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
  finishFindSelection(claim, selection, elapsedMs) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId), step = this.findClaim(record, claim);
      if (record.kind !== FIND_KIND || claim.stepKey !== 'selectInputs')
        throw taskError(409, 'conflict', 'The original find selection claim is required');
      const hash = fingerprint({selection, elapsedMs});
      if (step.finishFingerprint) {
        if (step.finishFingerprint !== hash) throw taskError(409, 'conflict', 'The original selection already completed');
        return this.project(record);
      }
      record.notes[String(claim.taskRev)].selection = clone(selection);
      this.settle(record, step, {state:'done', reason:null, result:{selectedCount:selection.entries.length}, elapsedMs});
      step.finishFingerprint = hash;
      // The saved selection and its read claim share one commit: cancellation or a crash
      // cannot hide observed coverage between two steps. A zero hold authorizes no IO.
      const remaining = TASK_LIMIT_MS - record.budget.spentMs - record.budget.heldMs;
      const agreement = record.revisions.find(value => value.taskRev === claim.taskRev).agreement;
      const deadlineMs = agreement.deadlineAtMs === null ? remaining : agreement.deadlineAtMs - this.now();
      const reserveMs = record.taskRev === claim.taskRev && !record.cancelRequested && agreement.afterExit === 'continue'
        ? Math.max(0, Math.min(remaining, deadlineMs)) : 0;
      record.steps.push({taskRev:claim.taskRev, stepKey:'readInputs', attemptId:randomUUID(), state:'running',
        startedAtMs:this.now(), finishedAtMs:null, reason:null, result:null, reserveMs, finishFingerprint:null});
      record.budget.heldMs += reserveMs;
      if (record.taskRev !== claim.taskRev || record.cancelRequested) this.setPlanState(record);
      return this.commit(record);
    }, true);
  }
  finishFind(claim, {report, sources, elapsedMs}) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId), step = this.findClaim(record, claim);
      if (record.kind !== FIND_KIND || claim.stepKey !== 'readInputs' || !record.notes[String(claim.taskRev)]?.selection)
        throw taskError(409, 'conflict', 'The original find read claim and selection are required');
      const hash = fingerprint({report, sources, elapsedMs});
      if (step.finishFingerprint) {
        if (step.finishFingerprint !== hash) throw taskError(409, 'conflict', 'The original find report already completed');
        return this.project(record);
      }
      const incomplete = !report.coverage.enumerationComplete || report.coverage.entryLimitReached ||
        report.coverage.candidateLimitReached || report.coverage.gaps.length > 0 || report.matches.some(value => !value.openable);
      record.notes[String(claim.taskRev)].sources = clone(sources);
      this.settle(record, step, {state:incomplete?'partial':'done', reason:incomplete?'find_incomplete':null, result:report, elapsedMs});
      step.finishFingerprint = hash;
      this.setPlanState(record);
      return this.commit(record);
    }, true);
  }
  saveInputs(claim, input) { return this.savePrivate(claim, 'inputs', input); }
  saveReceiptObservation(claim, sourceRef, observation) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId); this.findClaim(record, claim);
      const agreement = record.revisions.find(value => value.taskRev === claim.taskRev)?.agreement;
      if (record.kind !== RECEIPT_KIND || claim.stepKey !== 'readInputs' ||
          !agreement?.args.inputs.some(value => value.sourceRef === sourceRef))
        throw taskError(409, 'conflict', 'The original receipt read claim is required');
      const notes = record.notes[String(claim.taskRev)]; notes.receiptObservations ??= {};
      if (Object.hasOwn(notes.receiptObservations, sourceRef)) {
        if (fingerprint(notes.receiptObservations[sourceRef]) !== fingerprint(observation))
          throw taskError(409, 'conflict', 'The first original receipt observation is immutable');
        return this.project(record);
      }
      notes.receiptObservations[sourceRef] = clone(observation);
      return this.commit(record);
    }, true);
  }
  finishCompare(claim, {report, elapsedMs, interruption = null}) {
    return this.enqueue(async () => {
      const record = this.read(claim.taskId), step = this.findClaim(record, claim);
      if (record.kind !== COMPARE_KIND || claim.stepKey !== 'report')
        throw taskError(409, 'conflict', 'The original compare report claim is required');
      const hash = fingerprint({report, elapsedMs, interruption});
      if (step.finishFingerprint) {
        if (step.finishFingerprint !== hash) throw taskError(409, 'conflict', 'The original compare report already completed');
        return this.project(record);
      }
      const agreement = record.revisions.find(value => value.taskRev === claim.taskRev).agreement;
      const currentAgreement = record.taskRev === claim.taskRev && !record.cancelRequested && agreement.afterExit === 'continue' &&
        (agreement.deadlineAtMs === null || this.now() < agreement.deadlineAtMs);
      const ownerStopped = currentAgreement && elapsedMs <= claim.reserveMs &&
        (interruption === 'task_owner_stopping' || this.stopping && interruption === null);
      const published = !this.stopping && interruption === null && elapsedMs <= claim.reserveMs && currentAgreement;
      const complete = report.coverage.comparisonComplete && report.sources.every(value => value.verifiedAtPublish) &&
        (report.identical || report.suggestions.status === 'available');
      const state = complete && published ? 'done' : 'partial';
      this.settle(record, step, {state, reason: published ? (complete ? null : 'compare_incomplete') :
        ownerStopped ? 'report_owner_stopped' : 'report_not_published',
        result: {...clone(report), published}, elapsedMs});
      step.finishFingerprint = hash;
      if (record.taskRev === claim.taskRev && !record.cancelRequested) {
        record.state = published ? state : ownerStopped ? 'unknown' : 'failed';
        record.waitReason = published || ownerStopped ? step.reason : 'deadline_or_agreement_changed';
        record.approval = null;
      } else this.setPlanState(record);
      return this.commit(record);
    }, true);
  }
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
        // A failed optional comparison model still has verified source facts to report.
        if (completion.state === 'unknown' || completion.state === 'failed' &&
            !(record.kind === COMPARE_KIND && claim.stepKey === 'model')) {
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
      if (claim.stepKey !== writeKey(record) || settled(step) || !notes?.publishIntent || !notes.candidate || notes.publicationAttempted === true || record.artifacts.length)
        throw taskError(409, 'conflict', 'The original publication intent is not runnable', this.project(record));
      // Durable possible-send boundary: even a crash before the actual link consumes this attempt.
      notes.publicationAttempted = true; notes.publicationAttemptId = claim.attemptId;
      await this.commit(record);
      this.current(record, claim.taskRev);
      try {
        const result = await job(clone(notes.publishIntent), clone(record));
        const artifact = {...clone(result.artifact), artifactId: randomUUID(), taskRev: claim.taskRev, stepKey: claim.stepKey,
          reference: clone(notes.publishIntent)};
        record.artifacts.push(artifact);
        const receipt = record.kind === RECEIPT_KIND;
        if (receipt && fingerprint(result.report) !== fingerprint(notes.candidate.report))
          throw taskError(409, 'conflict', 'The original workbook report changed');
        this.settle(record, step, {state: receipt ? result.state : 'done', reason: receipt ? result.reason : null,
          result: {artifactId: artifact.artifactId, ...(receipt ? {report: clone(result.report)} : {})}, elapsedMs: result.elapsedMs});
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
      if (claim.stepKey !== writeKey(record) || !intent || notes.publicationAttempted !== true || notes.publicationAttemptId !== claim.attemptId)
        throw taskError(409, 'conflict', 'The original publication attempt is not bound to this claim');
      const previous = record.artifacts.find(item => item.taskRev === claim.taskRev && item.stepKey === claim.stepKey);
      if (previous) {
        if (previous.identity !== result.artifact.identity || previous.sha256 !== result.artifact.sha256)
          throw taskError(409, 'conflict', 'The recorded original artifact differs', this.project(record));
        return this.project(record);
      }
      const artifact = {...clone(result.artifact), artifactId: randomUUID(), taskRev: claim.taskRev, stepKey: claim.stepKey, reference: clone(intent)};
      const receipt = record.kind === RECEIPT_KIND;
      if (receipt && fingerprint(result.report) !== fingerprint(notes.candidate.report))
        throw taskError(409, 'conflict', 'The original workbook report changed');
      const completion = {artifactId: artifact.artifactId, ...(receipt ? {report: clone(result.report)} : {})};
      record.artifacts.push(artifact);
      if (!settled(step)) this.settle(record, step, {state: receipt ? result.state : 'done', reason: receipt ? result.reason : null,
        result: completion, elapsedMs: result.elapsedMs});
      else { step.state = receipt ? result.state : 'done'; step.reason = receipt ? result.reason : null;
        step.result = {...step.result, completion}; }
      step.finishFingerprint = fingerprint({artifactId: artifact.artifactId});
      if (record.taskRev === claim.taskRev && !record.cancelRequested) { record.state = result.state ?? 'done'; record.waitReason = result.reason ?? null; }
      else this.setPlanState(record);
      return this.commit(record);
    }, true);
  }
  async artifact(id, artifactId, signal) {
    const record = this.read(id), artifact = record.artifacts.find(value => value.artifactId === artifactId);
    if (!artifact) throw taskError(404, 'artifact-not-found', 'Artifact is not recorded for this task');
    if (artifact.mediaType === XLSX_TYPE)
      throw taskError(400, 'invalid-request', 'Use the original task workbook content route');
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
  async artifactBytes(id, artifactId, hostExecutionId, signal) {
    const record = this.read(id);
    if (hostExecutionId !== record.hostExecutionId)
      throw taskError(409, 'execution-mismatch', 'This workbook belongs to another task execution');
    const artifact = record.kind === RECEIPT_KIND && record.artifacts.find(value => value.artifactId === artifactId &&
      value.stepKey === 'writeSheet' && value.mediaType === XLSX_TYPE);
    if (!artifact) throw taskError(404, 'artifact-not-found', 'Workbook is not registered for this task');
    try {
      const actual = await this.fs.dshGoReadTaskArtifactBytes(artifact.reference.directory, artifact.relativePath, artifact, signal);
      return {mediaType: XLSX_TYPE, bytes: actual.bytes};
    } catch (error) {
      if (['FS_NOT_FOUND', 'ENOENT'].includes(error?.code))
        throw taskError(404, 'artifact-missing', 'The original workbook is now missing');
      if (['FS_STALE_VERSION', 'FS_NOT_DIRECTORY', 'ENOTDIR', 'ELOOP'].includes(error?.code))
        throw taskError(409, 'artifact-changed', 'The original workbook or directory changed');
      throw taskError(503, 'artifact-unavailable', 'The original workbook cannot currently be verified');
    }
  }
  async source(id, sourceRef, hostExecutionId, signal) {
    const record = this.read(id);
    if (hostExecutionId !== record.hostExecutionId)
      throw taskError(409, 'execution-mismatch', 'This source belongs to another task execution');
    const source = record.kind === FIND_KIND ? Object.values(record.notes).flatMap(value => value.sources ?? [])
      .find(value => value.sourceRef === sourceRef) : null;
    if (!source) throw taskError(404, 'source-not-found', 'The source is not registered for this find task');
    const envelope = {v:1, hostStoreId:this.hostStoreId, taskId:id, hostExecutionId:record.hostExecutionId,
      sourceRef, taskRev:source.taskRev, stepKey:'readInputs', relativePath:source.entry.name, version:source.entry.version,
      mediaType:source.entry.name.toLowerCase().endsWith('.md')?'text/markdown':'text/plain', content:null, reason:null};
    try {
      const read = await this.fs.dshGoReadNote(source.directory, source.entry, 65536, signal);
      if (source.sha256 !== null && read.sha256 !== source.sha256)
        return {...envelope, status:'changed', reason:'original_changed'};
      return {...envelope, status:'available', content:read.text};
    } catch (error) {
      if (['FS_NOT_FOUND','ENOENT'].includes(error?.code)) return {...envelope, status:'missing', reason:'original_missing'};
      if (['FS_STALE_VERSION','FS_NOT_DIRECTORY','ENOTDIR','ELOOP'].includes(error?.code)) return {...envelope, status:'changed', reason:'original_changed'};
      if (['FS_PERMISSION_DENIED','FS_SANDBOX_DENIED','FS_TOO_LARGE','FS_NOT_TEXT','FS_NOT_REGULAR_FILE','EACCES','EPERM'].includes(error?.code))
        return {...envelope, status:'not_readable', reason:'original_not_readable'};
      return {...envelope, status:'unknown', reason:'original_unavailable'};
    }
  }
}
