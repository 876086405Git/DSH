// Actual task store/Domain/JSON/F02 IO. Only the task-agent and model boundary are supplied.
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, rm, writeFile, utimes, link} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {notesProviders, notesSourceRoot} from './companion-notes-files-source.mjs';

export const harness = process.env.COMPANION_TASK_HARNESS;
assert(harness, 'the exact prepared task source harness is required');
export const load = relative => import(pathToFileURL(resolve(harness, relative)).href);
const {JsonStorageBackend} = await load('node_modules/@deepseek-ai/dsh-storage-json/index.js');
const {DomainFacility} = await load('node_modules/@deepseek-ai/dsh-storage-domain/index.js');
const {BackendRegistry} = await load('node_modules/@deepseek-ai/dsh-storage/index.js');
const {openCompanionTaskStore} = await load('companion/task-store.js');
const {createNotesToTodosRunner} = await load('companion/notes-to-todos.js');
const providers = await notesProviders(notesSourceRoot());
export const proposal = {todos: [{source: 'one.md', startLine: 2, endLine: 2,
  quote: 'TODO: 周五配镜', task: '周五配镜', assignee: null, due: '周五'}]};

export async function until(check, label, ms = 6000) {
  const deadline = Date.now() + ms;
  while (!await check()) {
    if (Date.now() > deadline) throw new Error('Timed out: ' + label);
    await delay(5);
  }
}
export async function writeNote(root, name, data) {
  const file = join(root, 'notes', name);
  await writeFile(file, data);
  const time = new Date('2026-11-20T12:00:00Z');
  await utimes(file, time, time);
}
export function modelPeer(counters, options = {}) {
  return {
    companionAuxiliaryCapability: () => ({physicalDispatch: 'fetch-invoked', rawUsage: 'deepseek-messages-cumulative', maxPhysicalRequests: 1, noTools: true}),
    async prepareCompanionAuxiliaryCall(config, signal, observer) {
      counters.prepared++;
      if (options.prepare) await options.prepare({config, signal, observer});
      return {config, contextWindow: Object.hasOwn(options, 'window') ? options.window : 64000,
        async *stream(request) {
          counters.streams++;
          const body = JSON.stringify({model: config.model, system: request.system,
            messages: [{role: 'user', content: [{type: 'text', text: request.input}]}], max_tokens: config.maxTokens});
          assert.equal(observer.checkRequest(body, 'provider-request'), true);
          observer.guard(); counters.modelCalls++; counters.requests.push(JSON.parse(body));
          observer.observe({type: 'dispatch', atMs: Date.now(), boundary: 'fetch-invoked'});
          observer.observe({type: 'http', status: 200});
          observer.observe({type: 'usage', event: 'message_start', raw: {input_tokens: 17}});
          if (options.stream) yield* options.stream({config, signal, observer, request, counters});
          else {
            yield {type: 'text-delta', text: JSON.stringify(options.proposal ?? proposal)};
            if (options.beforeFinish) await options.beforeFinish();
            observer.observe({type: 'usage', event: 'message_delta', raw: {output_tokens: 13}});
            observer.observe({type: 'stop', stopReason: 'end_turn'});
            observer.observe({type: 'complete'});
            yield {type: 'finish', reason: {kind: 'stop'}};
          }
        }};
    },
  };
}

export async function openFixture(root, options = {}) {
  const backend = new JsonStorageBackend(join(root, 'storage'));
  backend.dshGoCompanionStatfs = async () => ({type: 0xef53n});
  const registry = new BackendRegistry(); registry.register('fixture-json', backend);
  const context = {storage: {backend: registry}, emit() {}, logger: {warn() {}, error() {}}, fiber: {assertActive() {}}};
  const facility = new DomainFacility(context, {backend: 'fixture-json'});
  const fs = new providers.LocalFileSystem({}, {cwd: root, diffBasisMaxBytes: 10485760});
  fs.internals.companionStatfs = async () => ({type: 0xef53n});
  const counters = {prepared: 0, streams: 0, modelCalls: 0, links: 0, lists: 0, reads: 0, turnEnds: 0, requests: []};
  const list = fs.dshGoListNotes.bind(fs), read = fs.dshGoReadNote.bind(fs);
  fs.dshGoListNotes = (...args) => {counters.lists++; return list(...args);};
  fs.dshGoReadNote = (...args) => {counters.reads++; return read(...args);};
  fs.internals.linkFile = async (from, to) => {
    counters.links++;
    if (options.link) return options.link(from, to);
    return link(from, to);
  };
  const store = await openCompanionTaskStore({facility, fs});
  let runner;
  const execution = {async openExecution(_record, signal) {
    return {selected: options.selected ?? {provider: 'fixture', model: 'fixture-model'},
      llm: options.llm ?? modelPeer(counters, options), fs,
      standingPolicy: undefined, guard() {signal.throwIfAborted(); options.guard?.();},
      async runTurn(job) {try {return await job(signal);} finally {counters.turnEnds++;}},
      async approve() {assert.fail('unconfined local provider requires no invented approval');}};
  }, async close() {options.closed?.();}};
  const start = () => {
    assert(!runner); runner = createNotesToTodosRunner({ctx: {get: key => key === 'fs' ? fs : undefined}, store, execution});
    store.attachRunner(runner);
    for (const id of store.runnable()) runner.wake(id);
    return runner;
  };
  return {root, fs, store, backend, facility, counters, start,
    async close() {await store.close(); await backend.close();}};
}

export async function fixture(t, options = {}) {
  const root = await mkdtemp(join(process.cwd(), 'notes-runner-'));
  await mkdir(join(root, 'notes')); await mkdir(join(root, 'storage'));
  await writeNote(root, 'one.md', '随手记录。\nTODO: 周五配镜\n');
  const f = await openFixture(root, options);
  const folder = await f.store.bindFolder({v: 1, hostStoreId: f.store.hostStoreId, path: join(root, 'notes')});
  const body = {v: 1, hostStoreId: f.store.hostStoreId, taskId: 'task-one', taskRev: 1, kind: 'host.notes_to_todo',
    origin: {sourceSessionId: 'light:original-room', messageId: 'original-message', itemNo: 0}, hostSessionId: null,
    deadlineAtMs: null, afterExit: 'continue', allowQueue: true,
    args: {folderRef: folder.folderRef, outputDirRef: folder.folderRef, localDate: '2026-11-20', timeZone: 'UTC',
      dateBy: 'modified', outputName: '今日待办.md', writeMode: 'createNew'}};
  t.after(async () => {await f.close(); await rm(root, {recursive: true, force: true});});
  return {...f, body};
}
