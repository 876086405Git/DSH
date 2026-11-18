// Private Host fixture, never a product plugin. Loaded as an ordinary test row.
// Calls the actual registered MCP definition; it does not replace MCP/SDK/transport.
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isAbsolute, join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const name = 'add13-owned-mcp-observer';
export const inject = ['tools', 'webServer', 'connection', 'loader'];
const errorRecord = error => ({ name: error?.name, code: error?.code, message: String(error?.message ?? error), stack: error?.stack });

export async function apply(ctx, config) {
  if (!isAbsolute(config.payloadRoot) || !isAbsolute(config.output)) throw new TypeError('Private fixture paths must be absolute');
  const inventoryPath = join(config.payloadRoot, 'node_modules/@deepseek-ai/dsh-host-plugin-inventory/lib/index.js');
  const inventoryBytes = await readFile(inventoryPath);
  const { readPluginInventory } = await import(pathToFileURL(inventoryPath).href);
  const report = {
    scope: 'real Host registry + registered MCP definition, not agent ToolRuntime pipeline',
    inventoryCall: 'actual exported readPluginInventory(ctx), not a bridge inventory HTTP alias',
    inventorySource: { path: inventoryPath, bytes: inventoryBytes.length, sha256: createHash('sha256').update(inventoryBytes).digest('hex') },
    platform: process.platform, execArgv: process.execArgv, events: [], jobs: [],
  };
  const live = new Map();
  let jobCounter = 0;
  const note = (type, detail = {}) => {
    const event = { sequence: report.events.length + 1, type, utc: new Date().toISOString(), monotonicNs: process.hrtime.bigint().toString(), ...detail };
    report.events.push(event);
    return event;
  };
  let saving = Promise.resolve();
  const save = () => {
    const bytes = JSON.stringify(report, null, 2) + '\n';
    const operation = saving.then(() => writeFile(config.output, bytes));
    saving = operation.catch(() => {});
    return operation;
  };
  const definition = (rawName, serverName = config.serverName) => {
    const name = `mcp__${serverName}__${rawName}`;
    const value = ctx.tools.get(name);
    if (!value) throw new Error(`Actual MCP tool has not registered: ${name}`);
    return value;
  };
  const reply = (response, code, value) => {
    const body = Buffer.from(JSON.stringify(value));
    response.writeHead(code, { 'content-type': 'application/json', 'content-length': body.length });
    response.end(body);
  };
  ctx.effect(() => ctx.webServer.register({
    kind: 'prefix', path: '/__add13_mcp',
    handler: async (request, response) => {
      const rejection = ctx.connection.requestRejection(request);
      if (rejection !== undefined) { response.writeHead(rejection); response.end(); return; }
      try {
        const pathname = new URL(request.url, 'http://localhost').pathname;
        if (pathname === '/__add13_mcp/status' && request.method === 'GET') {
          const inventory = await readPluginInventory(ctx);
          const tools = ctx.tools.schemas().map(tool => tool.name);
          const snapshot = { inventory, tools, jobs: report.jobs, events: report.events };
          note('status', { entries: inventory.entries, tools });
          await save();
          reply(response, 200, snapshot);
          return;
        }
        if (request.method !== 'POST') { reply(response, 405, { error: 'Expected POST' }); return; }
        const chunks = [];
        for await (const chunk of request) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (pathname === '/__add13_mcp/echo') {
          const controller = new AbortController();
          const result = await definition('echo').execute({ message: input.message }, { signal: controller.signal });
          note('echo', { input, result });
          await save();
          reply(response, 200, { result });
          return;
        }
        if (pathname === '/__add13_mcp/stdio-echo') {
          const result = await definition('echo', 'add13_stdio').execute({ message: input.message }, { signal: new AbortController().signal });
          note('stdio-echo', { input, result });
          await save(); reply(response, 200, { result }); return;
        }
        if (pathname === '/__add13_mcp/hold') {
          const tool = definition('hold');
          const controller = new AbortController();
          const job = { id: ++jobCounter, state: 'pending', input };
          report.jobs.push(job);
          const promise = tool.execute({ message: input.message }, { signal: controller.signal }).then(
            result => { job.state = 'resolved'; job.result = result; note('hold-resolved', { id: job.id, result }); },
            error => { job.state = 'rejected'; job.error = errorRecord(error); note('hold-rejected', { id: job.id, error: job.error }); },
          ).finally(async () => { live.delete(job.id); await save(); });
          live.set(job.id, { controller, promise });
          note('hold-start', { id: job.id });
          await save();
          reply(response, 200, { id: job.id });
          return;
        }
        if (pathname === '/__add13_mcp/cancel') {
          const job = live.get(input.id);
          if (!job) { reply(response, 404, { error: 'No pending owned job' }); return; }
          note('hold-cancel-request', { id: input.id });
          job.controller.abort(new Error('ADD13 registered MCP request cancelled by its owner'));
          await save();
          reply(response, 200, { requested: true, id: input.id });
          return;
        }
        reply(response, 404, { error: 'No private fixture operation' });
      } catch (error) {
        note('observer-error', { error: errorRecord(error) });
        await save();
        reply(response, 500, { error: errorRecord(error) });
      }
    },
  }), 'add13.owned-mcp-observer');
  ctx.effect(() => async () => {
    note('observer-dispose-start', { liveJobs: live.size });
    const jobs = [...live.values()];
    for (const job of jobs) job.controller.abort(new Error('ADD13 private observer disposed'));
    await Promise.allSettled(jobs.map(job => job.promise));
    note('observer-dispose-end', { liveJobs: live.size });
    await save();
  }, 'add13.owned-mcp-observer-jobs');
  note('observer-ready');
  await save();
}
