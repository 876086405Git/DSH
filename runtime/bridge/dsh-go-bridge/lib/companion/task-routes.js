import { taskId, taskError, FIND_KIND, COMPARE_KIND, RECEIPT_KIND } from './task-schema.js';
import { findDraftSupported } from './find-draft.js';
import { compareDraftSupported } from './compare-drafts.js';
import { receiptsToSheetSupported, receiptInputFormats } from './receipts-to-sheet.js';

const ROOT = '/dsh-go/v1/companion/tasks';
const jsonType = req => String(req.headers['content-type'] ?? '').split(';', 1)[0].trim().toLowerCase() === 'application/json';

export function createCompanionTaskRoutes({ctx, send, readJson}) {
  function owner(req) {
    const connection = ctx.get('connection');
    if (typeof connection?.admit !== 'function') throw taskError(503, 'unavailable', 'Host owner admission is unavailable');
    const admission = connection.admit(req);
    if (admission?.peer?.principal?.kind !== 'owner') throw taskError(admission?.rejection ?? 403, 'forbidden', 'Tasks require the paired host owner');
  }
  async function foreground(req, res, store, id) {
    const controller = new AbortController();
    const abort = () => controller.abort(new Error('Original foreground response closed'));
    req.once('aborted', abort); res.once('close', abort);
    let unwatch = () => {}, completed;
    try {
      const body = await readJson(req, 32768, true);
      if (req.aborted || res.destroyed) abort();
      controller.signal.throwIfAborted();
      completed = store.foreground(id, body, controller.signal);
      let blocked = false, pending = null, ended = false;
      const write = snapshot => {
        if (controller.signal.aborted || res.destroyed) return;
        if (blocked) { pending = snapshot; return; }
        try { blocked = !res.write(`${JSON.stringify(snapshot)}\n`); }
        catch { abort(); }
      };
      const drained = () => {
        blocked = false;
        if (pending) { const latest = pending; pending = null; write(latest); }
        if (ended && !blocked && !res.destroyed) res.end();
      };
      const delivered = new Promise(resolve => {res.once('finish', resolve); res.once('close', resolve);});
      res.on('drain', drained);
      try {
        res.writeHead(200, {'content-type': 'application/x-ndjson; charset=utf-8', 'cache-control': 'no-store'});
        unwatch = store.observe(id, write); write(store.snapshot(id));
        await completed;
        unwatch(); write(store.snapshot(id)); ended = true;
        if (!blocked && !res.destroyed) res.end();
        if (!res.destroyed) await delivered;
      } finally {res.removeListener('drain', drained);}
    } finally {
      // Withdraw synchronously before awaiting the original task's observations.
      abort(); unwatch(); await completed;
      req.removeListener('aborted', abort); res.removeListener('close', abort);
    }
  }
  return {
    async handle(req, res, path) {
      if (path !== ROOT && !path.startsWith(`${ROOT}/`)) return false;
      try {
        owner(req);
        const store = ctx.get('dshGoCompanionTasks');
        if (path === `${ROOT}/capabilities` && req.method === 'GET') {
          const ready = !!store?.runner && !store.stopping;
          const findReady = ready && store.runner.kinds?.includes(FIND_KIND) && findDraftSupported(store.fs);
          const compareReady = ready && store.runner.kinds?.includes(COMPARE_KIND) && compareDraftSupported(store.fs);
          const receiptReady = ready && store.runner.kinds?.includes(RECEIPT_KIND) && receiptsToSheetSupported(store.fs);
          send(res, 200, {v: 1, hostStoreId: store?.hostStoreId ?? null, durableAcceptance: ready,
            kinds: ready ? (store.runner.kinds ?? ['host.notes_to_todo'])
              .filter(kind=>(kind!==FIND_KIND||findReady)&&(kind!==COMPARE_KIND||compareReady)&&(kind!==RECEIPT_KIND||receiptReady)) : [],
            sourceRead:!!findReady, artifactRead: typeof store?.fs?.dshGoReadNotesArtifact === 'function',
            ...(receiptReady ? {receiptInputs: {formats: receiptInputFormats(), maxFiles: 4, maxBytes: 4194304,
              maxPdfPages: 5, workbookBytes: 262144}} : {}),
            ...(ready && typeof store.runner.foreground === 'function' ? {notesForeground: true} : {}),
            afterExit: ['continue'], pauseBehavior: 'waiting', reason: ready ? null : 'task_service_unavailable'});
          return true;
        }
        if (!store || store.stopping) throw taskError(503, 'unavailable', 'The durable task service is unavailable');
        const url = new URL(req.url, 'http://dsh-go.invalid');
        const part = path.slice(ROOT.length).split('/').filter(Boolean).map(decodeURIComponent);
        if (part.length && part[0] !== 'folders' && !taskId.safeParse(part[0]).success)
          throw taskError(400, 'invalid-request', 'Invalid task identity');
        if (req.method === 'GET') {
          store.checkStore(url.searchParams.get('hostStoreId'));
          if (part.length === 0) send(res, 200, store.list(url.searchParams.get('cursor')));
          else if (part.length === 1) send(res, 200, store.snapshot(part[0]));
          else if (part.length === 3 && part[1] === 'artifacts' && taskId.safeParse(part[2]).success)
            send(res, 200, await store.artifact(part[0], part[2]));
          else if (part.length === 4 && part[1] === 'artifacts' && taskId.safeParse(part[2]).success && part[3] === 'content') {
            const keys = [...url.searchParams.keys()];
            if (keys.length !== 2 || new Set(keys).size !== 2 ||
                !keys.every(key => ['hostStoreId', 'hostExecutionId'].includes(key)) ||
                !taskId.safeParse(url.searchParams.get('hostExecutionId')).success)
              throw taskError(400, 'invalid-request', 'Workbook reads require only the original store and execution identity');
            const actual = await store.artifactBytes(part[0], part[2], url.searchParams.get('hostExecutionId'));
            res.writeHead(200, {'content-type': actual.mediaType, 'content-length': String(actual.bytes.length), 'cache-control': 'no-store'});
            res.end(actual.bytes);
          }
          else if (part.length === 3 && part[1] === 'sources' && taskId.safeParse(part[2]).success) {
            const keys = [...url.searchParams.keys()];
            if (keys.length !== 2 || new Set(keys).size !== 2 ||
              !keys.every(key=>['hostStoreId','hostExecutionId'].includes(key)) ||
              !taskId.safeParse(url.searchParams.get('hostExecutionId')).success)
              throw taskError(400, 'invalid-request', 'Source reads require only the original store and execution identity');
            send(res, 200, await store.source(part[0],part[2],url.searchParams.get('hostExecutionId')));
          }
          else throw taskError(404, 'not-found', 'Task route does not exist');
        } else if (req.method === 'POST') {
          if (!jsonType(req)) { req.resume(); throw taskError(415, 'invalid-request', 'Task requests require application/json'); }
          if (part.length === 2 && part[1] === 'foreground') {
            await foreground(req, res, store, part[0]); return true;
          }
          const body = await readJson(req, 32768, true);
          if (part.length === 0) {
            if (!store.runner || body?.kind === FIND_KIND &&
              (!store.runner.kinds?.includes(FIND_KIND) || !findDraftSupported(store.fs)) || body?.kind === COMPARE_KIND &&
              (!store.runner.kinds?.includes(COMPARE_KIND) || !compareDraftSupported(store.fs)) || body?.kind === RECEIPT_KIND &&
              (!store.runner.kinds?.includes(RECEIPT_KIND) || !receiptsToSheetSupported(store.fs)))
              throw taskError(503, 'unavailable', 'The fixed task runner is unavailable');
            const result = await store.create(body); send(res, result.created ? 201 : 200, result.snapshot);
          } else if (part.length === 1 && part[0] === 'folders') send(res, 201, await store.bindFolder(body));
          else if (part.length === 1 && part[0] === 'inputs') {
            if (body?.kind === RECEIPT_KIND ? !store.runner?.kinds?.includes(RECEIPT_KIND) || !receiptsToSheetSupported(store.fs) :
              !store.runner?.kinds?.includes(COMPARE_KIND) || !compareDraftSupported(store.fs))
              throw taskError(503,'unavailable','The original draft binding service is unavailable');
            send(res,201,await store.bindInput(body));
          }
          else if (part.length === 2 && part[1] === 'amend') send(res, 200, await store.amend(part[0], body));
          else if (part.length === 2 && part[1] === 'cancel') send(res, 200, await store.cancel(part[0], body));
          else throw taskError(404, 'not-found', 'Task route does not exist');
        } else throw taskError(405, 'invalid-request', 'Unsupported task method');
      } catch (error) {
        if (res.headersSent || res.destroyed) { if (!res.destroyed) res.destroy(); return true; }
        if (typeof error?.code === 'string' && error.code.startsWith('companion/') && !error.code.startsWith('companion/task-'))
          error = taskError(error.status, 'invalid-request', 'Invalid task request');
        const known = typeof error?.code === 'string' && error.code.startsWith('companion/');
        send(res, known ? error.status : 503, {error: {code: known ? error.code : 'companion/task-unavailable',
          message: known ? error.message : 'Task persistence or execution is unavailable'},
          ...(error?.snapshot ? {snapshot: error.snapshot} : {})});
      }
      return true;
    },
  };
}
