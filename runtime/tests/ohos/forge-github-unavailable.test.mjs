import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// This is the existing explicit, isolate-local OH test marker. No built-in is replaced.
const marker = Symbol.for('dsh.go.ohos.sim');
const prefix = resolve(process.env.OHOS_TEST_DSH_PREFIX);
const { apply } = await import(pathToFileURL(join(prefix,
  'node_modules/@deepseek-ai/dsh-experimental-forge-github/lib/index.js')).href);

async function observe(ohos) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-forge-gh-'));
  const executable = join(directory, 'controlled-gh.mjs');
  const callsFile = join(directory, 'calls.jsonl');
  const previous = Object.getOwnPropertyDescriptor(globalThis, marker);
  try {
    await writeFile(executable, `#!${process.execPath}\nimport { appendFileSync } from 'node:fs';\nappendFileSync(${JSON.stringify(callsFile)}, JSON.stringify(process.argv.slice(2)) + '\\n');\nprocess.stdout.write('controlled gh: authenticated\\n');\n`, { mode: 0o700 });
    if (ohos) globalThis[marker] = true;
    else delete globalThis[marker];
    const providers = [];
    apply({ forge: { register(provider) { providers.push(provider); } } }, {
      ghCommand: executable, hosts: ['github.com'], timeoutMs: 2000,
      maxOutputBytes: 8192,
    });
    assert.equal(providers.length, 1);
    const readiness = await providers[0].readiness('github.com', new AbortController().signal);
    let calls = [];
    try {
      calls = (await readFile(callsFile, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    const observation = { ohos, readiness, calls };
    console.log(JSON.stringify({ forgeGhObservation: observation }));
    return observation;
  } finally {
    if (previous) Object.defineProperty(globalThis, marker, previous);
    else delete globalThis[marker];
    await rm(directory, { recursive: true, force: true });
  }
}

test('non-OH public forge readiness retains the real configured gh invocation', { timeout: 5000 }, async () => {
  const observed = await observe(false);
  assert.deepEqual(observed.readiness, { state: 'ready', message: null });
  assert.deepEqual(observed.calls, [['auth', 'status', '--hostname', 'github.com']]);
});

test('OH public forge readiness reports unavailable without starting configured gh', { timeout: 5000 }, async () => {
  const observed = await observe(true);
  assert.equal(observed.readiness.state, 'unavailable');
  assert.match(observed.readiness.message, /OpenHarmony.*gh.*computer/i);
  assert.deepEqual(observed.calls, []);
});
