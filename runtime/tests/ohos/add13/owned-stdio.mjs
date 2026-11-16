// Owned stdio peer: the actual SDK must register and call it through a Worker.
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { isMainThread } from 'node:worker_threads';
const [output] = process.argv.slice(2);
if (!output?.startsWith('/')) throw new Error('Owned marker path must be absolute');
appendFileSync(output, JSON.stringify({ pid: process.pid, ppid: process.ppid, worker: !isMainThread, utc: new Date().toISOString() }) + '\n');
createInterface({ input: process.stdin }).on('line', line => {
  const message = JSON.parse(line);
  if (message.id === undefined) return;
  const reply = value => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, ...value }) + '\n');
  if (message.method === 'server/discover') { reply({ error: { code: -32601, message: 'Owned legacy peer' } }); return; }
  let result = {};
  if (message.method === 'initialize') result = { protocolVersion: message.params.protocolVersion,
    capabilities: { tools: {} }, serverInfo: { name: 'add13-owned-stdio', version: '1' } };
  if (message.method === 'tools/list') result = { tools: [{ name: 'echo', description: 'Owned stdio echo',
    inputSchema: { type: 'object', properties: { message: { type: 'string' } }, required: ['message'] } }] };
  if (message.method === 'tools/call') result = { content: [{ type: 'text', text: message.params.arguments.message }] };
  reply({ result });
});
