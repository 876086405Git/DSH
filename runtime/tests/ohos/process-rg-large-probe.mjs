// A host-launched probe. The virtual rg still runs in its unmodified 256 MiB Worker.
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
const processRoot = process.env.M4_PROCESS_ROOT
  ? pathToFileURL(resolve(process.env.M4_PROCESS_ROOT) + '/')
  : new URL('../../ohos/process/', import.meta.url);
const mode = process.env.M4_LARGE_MODE || 'large';
const root = await mkdtemp(join(tmpdir(), 'ohos-rg-large-'));
const work = join(root, 'work'), temp = join(root, 'temp');
await mkdir(work); await mkdir(temp);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const sourceSHA256 = sha(await readFile(new URL('rg.mjs', processRoot)));
const started = performance.now();
const report = { mode, node: process.version, sourceSHA256, workerOldGenerationMb: 256, strict: globalThis.WebAssembly === undefined };
let runtime;
try {
  if (mode === 'reads') {
    const { createFilesystem } = await import(new URL('filesystem.mjs', processRoot));
    const { executeRg } = await import(new URL('rg.mjs', processRoot));
    await writeFile(join(work, 'text.txt'), 'abc\n');
    await writeFile(join(work, 'binary.txt'), 'abc\0tail\n');
    const filesystem = createFilesystem([work, temp]); filesystem.seal();
    const reads = [];
    const counted = new Proxy(filesystem.fs, { get(target, key) {
      const value = target[key];
      if (typeof value !== 'function') return value;
      return (...args) => {
        if (key === 'readFileBuffer') reads.push(args[0]);
        return value.apply(target, args);
      };
    } });
    const ctx = { fs: counted, cwd: work, limits: { maxArrayElements: 1000000, maxOutputSize: 64 * 1024 * 1024, maxGlobOperations: 1000000 }, origCommand: () => { throw new Error('unexpected bundled command'); } };
    report.records = [];
    for (const [name, args] of [
      ['explicit-text', ['--json', '--regexp=abc', '--', 'text.txt']],
      ['explicit-binary', ['--json', '--regexp=abc', '--', 'binary.txt']],
      ['explicit-text-mode', ['--json', '--text', '--regexp=abc', '--', 'binary.txt']],
    ]) {
      reads.length = 0;
      const result = await executeRg(args, ctx);
      report.records.push({ name, reads: reads.map(value => value.slice(work.length + 1)), result });
    }
  } else {
    const bytes = Number(process.env.M4_LARGE_BYTES || 48 * 1024 * 1024);
    if (!Number.isInteger(bytes) || bytes < 1 || bytes > 64 * 1024 * 1024) throw new Error('probe bytes must be in 1..64 MiB');
    const input = Buffer.alloc(bytes, 0x61);
    await writeFile(join(work, 'large.txt'), input);
    Object.assign(report, { inputBytes: bytes, inputSHA256: sha(input), pattern: 'z', inputLF: false, collectorMaxBytes: 64 * 1024 * 1024 });
    // A fatal V8 OOM can abort the whole process before finally runs. Save the
    // exact owned fixture before starting the Worker so a host can clean it up.
    if (process.env.M4_LARGE_PRE_REPORT) await writeFile(process.env.M4_LARGE_PRE_REPORT, JSON.stringify({ ...report, ownedFixture: root }, null, 2) + '\n');
    const { VirtualSubprocessRuntime } = await import(new URL('runtime.mjs', processRoot));
    runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp });
    const handle = runtime.spawn({ argv: ['rg', '--json', '--regexp=z', '--', 'large.txt'], cwd: work, graceMs: 100, stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 * 1024 }, stderr: { maxBytes: 1024 * 1024 } } });
    const timer = setTimeout(() => { report.timedOut = true; handle.terminate(); }, 30000);
    try { report.done = await handle.done; }
    catch (error) { report.failure = { name: error.name, code: error.code, message: error.message }; }
    finally { clearTimeout(timer); }
    report.stdout = handle.collected.stdout.readFrom(0).text;
    report.stderr = handle.collected.stderr.readFrom(0).text;
    report.runtimeLiveAfter = runtime.live.size;
  }
} finally {
  await runtime?.dispose();
  await rm(root, { recursive: true, force: true });
  report.elapsedMs = performance.now() - started;
  report.resourceUsage = process.resourceUsage();
  console.log(JSON.stringify(report, null, 2));
}
