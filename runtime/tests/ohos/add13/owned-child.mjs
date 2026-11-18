import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
const [id, output] = process.argv.slice(2);
if (!/^[A-Za-z0-9_.-]+$/.test(id) || !output?.startsWith('/')) throw new Error('Owned child arguments are invalid');
const value = { id, pid: process.pid, ppid: process.ppid, platform: process.platform, argv: process.argv.slice(2) };
writeFileSync(join(output, `${id}.json`), JSON.stringify(value) + '\n', { flag: 'wx' });
process.stdout.write(`ADD13_CHILD:${id}\n`);
