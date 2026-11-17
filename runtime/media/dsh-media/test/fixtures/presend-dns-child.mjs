// Isolated default-client regression: real admission/ledger/store/engine;
// Network boundaries are controlled; the budget day is fixed within this child.
import assert from 'node:assert/strict';
import dns, { lookup as namedLookup } from 'node:dns/promises';
import http, { request as namedHttpRequest } from 'node:http';
import https, { request as namedHttpsRequest } from 'node:https';
import { syncBuiltinESMExports } from 'node:module';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const original = { lookup: dns.lookup, http: http.request, https: https.request, now: Date.now };
const budgetNow = Date.now();
const dnsCalls = [];
let httpRequests = 0, httpsRequests = 0;
const lookup = async (hostname, options) => {
  dnsCalls.push({ hostname, all: options.all, verbatim: options.verbatim });
  throw Object.assign(new Error('controlled DNS failure'), { code: 'EAI_AGAIN' });
};
const httpRequest = () => { httpRequests++; throw new Error('unexpected HTTP request creation'); };
const httpsRequest = () => { httpsRequests++; throw new Error('unexpected HTTPS request creation'); };
const directory = await mkdtemp(join(tmpdir(), 'media-presend-dns-'));
try {
  Date.now = () => budgetNow; // Keep both admissions in the same budget day.
  dns.lookup = lookup; http.request = httpRequest; https.request = httpsRequest;
  syncBuiltinESMExports();
  assert.equal(namedLookup, lookup);
  assert.equal(namedHttpRequest, httpRequest);
  assert.equal(namedHttpsRequest, httpsRequest);
  // The default HTTP transport captures lookup when its module is first loaded.
  const [{ CATALOG, HARD_LIMITS }, { admitGeneration }, { createBudgetLedger }, { generateMedia }] = await Promise.all([
    import('../../src/config.js'), import('../../src/budget.js'),
    import('../../src/budget-ledger.js'), import('../../src/media-engine.js'),
  ]);
  const workspace = join(directory, 'workspace'); await mkdir(workspace);
  const request = {
    prompt: 'synthetic circle', n: 1, refs: [],
    service: { id: 'probe', provider: 'openai', profile: 'openai-gpt-image', baseUrl: 'https://api.openai.com/v1' },
    model: CATALOG.models.find(row => row.profile === 'openai-gpt-image' && !row.editOnly),
  };
  const context = {
    hostStateDir: join(directory, 'host-state'), sessionId: 'session-1', keyRef: 'TEST_MEDIA_KEY',
    signal: new AbortController().signal, limits: { ...HARD_LIMITS },
    budget: { dailyMicros: 20_000_000, unknownHoldMicros: 20_000_000 },
    approve: async () => 'allowed-once', resolveCredential: async () => 'synthetic-not-a-real-key',
    authorizeWorkspace: async () => ({ cwd: workspace, workspaceRoot: workspace, mode: 'workspace-write' }),
  };
  context.admission = await admitGeneration(request, context);
  const ledger = createBudgetLedger(join(context.hostStateDir, 'budget'));
  const rid = context.admission.rid;
  const before = (await ledger.snapshot()).requests.find(record => record.rid === rid);
  let failure;
  try { await generateMedia(request, context); } catch (error) { failure = error; }
  const after = (await ledger.snapshot()).requests.find(record => record.rid === rid);
  let next, nextFailure;
  try { next = await admitGeneration(request, context); } catch (error) { nextFailure = error; }
  const second = (await ledger.snapshot()).requests.find(record => record.rid === next?.rid);
  const observed = {
    dnsCalls, httpRequests, httpsRequests, beforeState: before?.state,
    errorCode: failure?.code ?? null, afterState: after?.state,
    nextErrorCode: nextFailure?.code ?? null, nextState: second?.state ?? null,
    sameDay: !!second && second.day === after?.day, distinctRid: !!second && second.rid !== rid,
  };
  // Preserve both admissions and the ledger evidence before any outcome assertion.
  process.stdout.write(JSON.stringify(observed, null, 2) + '\n');
  assert.deepEqual(observed, {
    dnsCalls: [{ hostname: 'api.openai.com', all: true, verbatim: true }],
    httpRequests: 0, httpsRequests: 0, beforeState: 'reserved',
    errorCode: 'network', afterState: 'released',
    nextErrorCode: null, nextState: 'reserved', sameDay: true, distinctRid: true,
  });
} finally {
  Date.now = original.now;
  dns.lookup = original.lookup; http.request = original.http; https.request = original.https;
  syncBuiltinESMExports();
  await rm(directory, { recursive: true, force: true });
}
