// Synthetic MCP peer: no phone access. Only tests consume the echoed metadata.
import { closeSync, openSync } from 'node:fs';
import { createInterface } from 'node:readline';

// `--first-end=<exit|refuse|drop>:<marker>`: the first run end this fixture sees across reconnected
// processes (claimed by creating the marker) is lost before any ACK, or answered with a peer error.
const firstEnd = process.argv.find(arg => arg.startsWith('--first-end='))?.slice('--first-end='.length);
const claimFirstEnd = () => {
  if (firstEnd === undefined) return undefined;
  const split = firstEnd.indexOf(':');
  try { closeSync(openSync(firstEnd.slice(split + 1), 'wx')); } catch { return undefined; }
  return firstEnd.slice(0, split);
};
const ends = [], refused = [], dropped = [];
const button = process.argv.includes('--button');
let presses = 0;
for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (request.id === undefined) continue;
  let result;
  switch (request.method) {
    case 'initialize':
      result = {
        protocolVersion: request.params.protocolVersion,
        capabilities: {
          tools: { listChanged: false },
          ...(['supported', 'lifecycle'].includes(process.argv[2]) ? {
            experimental: { 'dsh-go/phone-caller': { v: 1, taskIsolation: 0, ...(process.argv[2] === 'lifecycle' ? { runLifecycle: 1 } : {}) } },
          } : {}),
        },
        serverInfo: { name: 'synthetic-phone-caller', version: '1' },
      };
      break;
    case 'tools/list':
      result = { tools: button ? [{ name: 'tap', description: 'Press the synthetic button', inputSchema: {
        type: 'object', properties: { screen: { type: 'string' }, id: { type: 'integer' } }, required: ['screen', 'id'],
      } }] : [{ name: 'screen', description: 'Synthetic caller probe', inputSchema: { type: 'object' } }] };
      break;
    case 'tools/call':
      if (button) {
        const { name, arguments: args, _meta } = request.params;
        const accepted = name === 'tap' && args?.screen === 'fixture' && args?.id === 1 && ++presses === 1;
        result = { isError: !accepted, content: [{ type: 'text', text: accepted
          ? 'fixture-button-pressed-once ' + _meta?.['dsh-go/phone-caller']?.sessionId : 'unexpected button press' }] };
        break;
      }
      result = { content: [{ type: 'text', text: JSON.stringify({
        args: request.params.arguments,
        ends,
        refused,
        dropped,
        pid: process.pid,
        caller: request.params._meta?.['dsh-go/phone-caller'] ?? null,
      }) }] };
      if (request.params.arguments?.exit === true) {
        // Reply, then retire this connection as a relay or bridge loss would.
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\n', () => process.exit(0));
        continue;
      }
      break;
    case 'dsh-go/phone-run-end': {
      const fault = claimFirstEnd();
      if (fault === 'exit') process.exit(0);
      if (fault === 'drop') {
        dropped.push(request.params);
        continue; // Keep this transport live; the host must retry without another owned call.
      }
      if (fault === 'refuse') {
        refused.push(request.params);
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, error: { code: -32000, message: 'Synthetic end refusal' } }) + '\n');
        continue;
      }
      ends.push(request.params);
      result = {}; // ACK records intent only; this fixture has no device work.
      break;
    }
    case 'ping':
      result = {};
      break;
    default:
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, error: { code: -32601, message: 'Method not found' } }) + '\n');
      continue;
  }
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\n');
}
