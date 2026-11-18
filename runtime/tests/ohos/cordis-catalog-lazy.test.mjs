import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire, registerHooks } from 'node:module';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = resolve(process.env.DSH_PREFIX);
const require = createRequire(join(prefix, 'package.json'));
const load = name => import(pathToFileURL(require.resolve('@deepseek-ai/' + name)));
const loads = [];
const hooks = registerHooks({ load(url, context, next) {
  const result = next(url, context);
  if (url.endsWith('/dsh-tool-cordis/lib/types/api-catalog.js')) loads.push(url);
  return result;
} });
const [{ Context }, { SystemPrompt }, { ToolsService }, { CordisInspectRegistryService }] = await Promise.all([
  load('cordis'), load('dsh-system-prompt'), load('dsh-tools'), load('dsh-cordis-host-runner'),
]);
const ctx = new Context();
await ctx.plugin(SystemPrompt, {});
await ctx.plugin(ToolsService);
new CordisInspectRegistryService(ctx, 1000);
await ctx.plugin(await load('dsh-tool-cordis/host'));
await ctx.plugin(await load('dsh-tool-cordis'));
const atRegistration = loads.length;
const signal = new AbortController().signal;
const query = (provider, method, input, chosenSignal = signal) =>
  ctx.cordisInspect.query('host', provider, method, input, undefined, chosenSignal);
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const contract = {};
let services, events;
after(async () => {
  await ctx.fiber.dispose();
  hooks.deregister();
  if (process.env.CATALOG_CAPTURE) writeFileSync(process.env.CATALOG_CAPTURE,
    JSON.stringify({ contract, catalogLoads: loads, atRegistration }, null, 2) + '\n');
});

test('Host registration and provider directory do not load the static API catalog', () => {
  const providers = ctx.cordisInspect.list();
  assert.deepEqual(providers.map(x => x.id), ['Service', 'Event', 'Config', 'Tool']);
  contract.manifests = hash(providers);
  assert.equal(atRegistration, 0, 'static API catalog loaded before any Service/Event query');
});

test('Tool and live Config remain available without loading Service/Event data', async () => {
  const tools = await query('Tool', 'listTools');
  assert.deepEqual(tools.tools.map(x => x.name).sort(), ['cordis_inspect_list', 'cordis_inspect_query']);
  contract.tools = hash(tools);
  await assert.rejects(query('Config', 'listConfigs'), /requires the Loader/);
  ctx.provide('loader', { *entries() {} });
  const config = await query('Config', 'listConfigs');
  assert.deepEqual(config, { entries: [], total: 0, nextOffset: null });
  contract.config = hash(config);
  assert.equal(loads.length, 0);
});

test('invalid or already cancelled host queries fail before catalog loading', async () => {
  await assert.rejects(query('Service', 'wrongMethod'), /method/);
  await assert.rejects(query('Service', 'listService', { service: 12 }), /string/);
  const controller = new AbortController();
  const reason = new Error('catalog caller cancelled');
  controller.abort(reason);
  await assert.rejects(query('Service', 'listService', undefined, controller.signal), error => error === reason);
  assert.equal(loads.length, 0);
});

test('concurrent first Service and Event queries load one catalog and retain host filtering', async () => {
  [services, events] = await Promise.all([
    query('Service', 'listService'), query('Event', 'listEvents'),
    query('Service', 'listService'), query('Event', 'listEvents'),
  ]);
  assert.equal(services.mode, 'catalog');
  assert.equal(events.mode, 'catalog');
  assert(services.services.length > 0);
  assert(events.events.length > 0);
  assert(events.events.every(x => !x.name.startsWith('cordis/')));
  assert.equal(loads.length, 1);
  contract.serviceDirectory = hash(services);
  contract.eventDirectory = hash(events);
  contract.serviceCount = services.services.length;
  contract.eventCount = events.events.length;
});

test('every published exact Service/Event contract preserves original bytes and errors', async () => {
  const serviceContracts = [], eventContracts = [];
  for (const item of services.services) serviceContracts.push(await query('Service', 'listService', { service: item.key }));
  for (const item of events.events) eventContracts.push(await query('Event', 'listEvents', { event: item.name }));
  contract.allServices = hash(serviceContracts);
  contract.allEvents = hash(eventContracts);
  for (const [provider, method, input, message] of [
    ['Service', 'listService', { service: '__missing_catalog_service__' }, 'no catalogued Service named "__missing_catalog_service__"'],
    ['Event', 'listEvents', { event: '__missing_catalog_event__' }, 'no catalogued Event named "__missing_catalog_event__"'],
  ]) await assert.rejects(query(provider, method, input), error => error.message === message);
  assert.equal(loads.length, 1);
  const golden = JSON.parse(readFileSync(new URL('./cordis-catalog-golden.json', import.meta.url), 'utf8'));
  assert.deepEqual(contract, golden.contract);
});
