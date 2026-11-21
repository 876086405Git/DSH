import { z } from 'zod';
import { Temporal } from '@js-temporal/polyfill';
import { createHash } from 'node:crypto';
import { CompanionError } from './schema.js';

export const TASK_KIND = 'host.notes_to_todo';
export const TASK_LIMIT_MS = 300_000;
export const taskId = z.string().min(1).max(128).regex(/^[A-Za-z0-9][A-Za-z0-9._:-]*$/);
const integer = z.number().int().nonnegative().safe();
const revision = integer.min(1);
const text = z.string().min(1);
const args = z.object({
  folderRef: taskId, localDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), timeZone: text.max(128).refine(value => !/^[+-]/.test(value)),
  dateBy: z.literal('modified'), outputDirRef: taskId,
  outputName: text.max(255).refine(value => !/[\\/\u0000-\u001f\u007f]/.test(value) &&
    value !== '.' && value !== '..' && /\.(md|txt)$/i.test(value)), writeMode: z.literal('createNew'),
}).strict();
export const agreementSchema = z.object({args, deadlineAtMs: integer.nullable(),
  afterExit: z.enum(['continue', 'pause']), allowQueue: z.boolean()}).strict();
const origin = z.object({sourceSessionId: text.max(256), messageId: taskId, itemNo: integer}).strict();
const base = {v: z.literal(1), hostStoreId: taskId};
export const createSchema = agreementSchema.extend({...base, taskId, taskRev: z.literal(1),
  kind: z.literal(TASK_KIND), origin, hostSessionId: taskId.nullable()}).strict();
export const amendSchema = z.object({...base, operationId: taskId, expectedTaskRev: revision,
  taskRev: revision, changes: agreementSchema}).strict().refine(value => value.taskRev === value.expectedTaskRev + 1);
export const cancelSchema = z.object({...base, operationId: taskId, expectedTaskRev: revision,
  taskRev: revision}).strict().refine(value => value.taskRev === value.expectedTaskRev + 1);
export const folderSchema = z.object({...base, path: text.max(4096)}).strict();
const states = z.enum(['queued', 'waiting', 'running', 'unknown', 'done', 'partial', 'failed', 'cancelled']);
const stepKeys = z.enum(['selectInputs', 'readInputs', 'model', 'writePage']);
const object = z.record(z.string(), z.json());
const approval = z.object({taskRev: revision, stepKey: stepKeys, agentId: taskId,
  approvalId: taskId, eventId: taskId, callId: taskId.nullable()}).strict();
const directory = z.object({target: z.object({targetKey: text, displayPath: text}).strict(),
  identity: text}).strict();
export const folderRecordSchema = z.object({folderRef: taskId, directory, createdAtMs: integer}).strict();
export const globalSchema = z.object({v: z.literal(1), hostStoreId: taskId.nullable(), createdAtMs: integer}).strict();
export const recordSchema = z.object({
  v: z.literal(1), taskId, hostExecutionId: taskId, kind: z.literal(TASK_KIND),
  taskRev: revision, runnerReceiptSeq: integer, originalCreate: createSchema.nullable(),
  originalFingerprint: text.nullable(), origin: origin.nullable(), hostSessionId: taskId.nullable(),
  state: states, waitReason: text.nullable(), cancelRequested: z.boolean(),
  createdAtMs: integer, updatedAtMs: integer, agreement: agreementSchema.nullable(),
  revisions: z.array(z.object({taskRev: revision, operation: z.enum(['create', 'amend', 'cancel']),
    acceptedAtMs: integer, agreement: agreementSchema.nullable()}).strict()),
  operations: z.record(z.string(), z.object({fingerprint: text, taskRev: revision}).strict()),
  steps: z.array(z.object({taskRev: revision, stepKey: stepKeys, attemptId: taskId, state: states,
    startedAtMs: integer, finishedAtMs: integer.nullable(), reason: text.nullable(), result: object.nullable(),
    reserveMs: integer, finishFingerprint: text.nullable()}).strict()),
  artifacts: z.array(z.object({artifactId: taskId, taskRev: revision, stepKey: stepKeys,
    relativePath: text, mediaType: z.enum(['text/markdown', 'text/plain']), size: integer,
    sha256: z.string().regex(/^[a-f0-9]{64}$/), verifiedAtMs: integer, sourceCount: integer,
    identity: text, reference: object}).strict()),
  approval: approval.nullable(), budget: z.object({limitMs: z.literal(TASK_LIMIT_MS), spentMs: integer, heldMs: integer}).strict(),
  execution: object.nullable(), notes: z.record(z.string(), object),
}).strict();

export function taskError(status, code, message, snapshot) {
  const error = new CompanionError(status, `task-${code}`, message);
  if (snapshot) error.snapshot = snapshot;
  return error;
}
export function parseTask(schema, input) {
  const parsed = schema.safeParse(input);
  if (!parsed.success) throw taskError(400, 'invalid-request', 'Invalid task request');
  return parsed.data;
}
export function fingerprint(value) {
  const sorted = input => Array.isArray(input) ? input.map(sorted) :
    input !== null && typeof input === 'object' ? Object.fromEntries(Object.keys(input).sort().map(key => [key, sorted(input[key])])) : input;
  return createHash('sha256').update(JSON.stringify(sorted(value))).digest('hex');
}
export function taskAgreement(request) {
  return agreementSchema.parse({args: request.args, deadlineAtMs: request.deadlineAtMs,
    afterExit: request.afterExit, allowQueue: request.allowQueue});
}
export function dayRange(agreement) {
  try {
    const date = Temporal.PlainDate.from(agreement.args.localDate, {overflow: 'reject'});
    const start = date.toZonedDateTime(agreement.args.timeZone);
    const end = date.add({days: 1}).toZonedDateTime(agreement.args.timeZone);
    // A civil date skipped by its zone is not silently moved to another date.
    if (start.toPlainDate().toString() !== agreement.args.localDate || end.epochMilliseconds <= start.epochMilliseconds)
      throw new Error('missing local date');
    return {startAtMs: start.epochMilliseconds, endAtMs: end.epochMilliseconds};
  } catch { throw taskError(400, 'invalid-request', 'The original local date and time zone do not identify a day'); }
}
