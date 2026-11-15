// A deliberately short owned command, not a conforming stdio MCP server.
// This records whether the actual SDK ever creates a process; no external command runs.
import { appendFileSync } from 'node:fs';
const [output] = process.argv.slice(2);
if (!output?.startsWith('/')) throw new Error('Owned marker path must be absolute');
appendFileSync(output, JSON.stringify({ pid: process.pid, ppid: process.ppid, utc: new Date().toISOString() }) + '\n');
