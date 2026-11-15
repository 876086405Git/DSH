import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const runtimeURL = process.env.M4_PROCESS_RUNTIME
  ? pathToFileURL(process.env.M4_PROCESS_RUNTIME)
  : new URL('../../ohos/process/runtime.mjs', import.meta.url);
const { VirtualSubprocessRuntime } = await import(runtimeURL);
const base = await mkdtemp(join(tmpdir(), 'ohos-command-limit-'));
const work = join(base, '工作区'), temporaryRoot = join(base, '临时');
await Promise.all([mkdir(work), mkdir(temporaryRoot)]);
const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot });
const rows = [];
try {
  for (const iterations of [10000, 50000, 100000]) {
    const script = `for ((i=0; i<${iterations}; i++)); do :; done; printf 'completed\\n'`;
    const start = performance.now();
    const handle = runtime.spawn({ argv: ['bash', '-c', script], cwd: work,
      graceMs: 200, stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
    const result = await handle.done;
    const row = { iterations, script, elapsedMs: performance.now() - start, result,
      stdout: handle.collected.stdout.readFrom(0).text,
      stderr: handle.collected.stderr.readFrom(0).text,
      processPeakRSSKiB: process.resourceUsage().maxRSS };
    rows.push(row); console.log(JSON.stringify(row));
  }
  const report = { node: process.version, platform: process.platform,
    noWasm: typeof WebAssembly === 'undefined',
    simulationMarker: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
    scope: 'Linux samples using unchanged production virtual worker and dependency defaults; not a device latency or memory bound', rows };
  if (process.env.M4_LIMIT_REPORT) await writeFile(process.env.M4_LIMIT_REPORT, JSON.stringify(report, null, 2) + '\n');
} finally {
  await runtime.dispose();
  await rm(base, { recursive: true, force: true });
}
