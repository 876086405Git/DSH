// Explicit owner runner: capability absence is BLOCKED (exit 2), never success.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ownerPrerequisites } from '../fixtures/companion-receipts-engine.mjs';

const prerequisite = await ownerPrerequisites();
if (prerequisite.blocked) {
  process.stderr.write(`BLOCKED / NOT_RUN: ${prerequisite.blocked}\n`);
  process.exitCode = 2;
} else {
  const child = spawn(process.execPath, [...process.execArgv, '--test', '--test-reporter=tap',
    fileURLToPath(new URL('./companion-receipts-engine.test.mjs', import.meta.url))], {
    env: { ...process.env, COMPANION_J_OWNER_REQUIRED: '1' }, stdio: 'inherit',
  });
  child.once('error', error => { process.stderr.write(`${error.stack}\n`); process.exitCode = 1; });
  child.once('exit', (code, signal) => { process.exitCode = signal ? 1 : code ?? 1; });
}
