import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { VirtualSubprocessRuntime } from '../../ohos/process/runtime.mjs';

let root, work, runtime;
before(async () => {
  root = await mkdtemp(join(tmpdir(), 'ohos-date-timezone-'));
  work = join(root, 'work');
  const temp = join(root, 'temp');
  await mkdir(work); await mkdir(temp);
  runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot: temp });
});
after(async () => {
  await runtime?.dispose();
  await rm(root, { recursive: true, force: true });
});

// Fixed winter dates avoid current time, ambiguous DST transitions and abbreviations.
const zones = [
  ['UTC', '2024-01-02T03:04:05+0000', 1704164645],
  ['Asia/Taipei', '2024-01-02T11:04:05+0800', 1704135845],
  ['America/New_York', '2024-01-01T22:04:05-0500', 1704182645],
];
for (const [zone, epochLocal, naiveEpoch] of zones) {
  for (const [form, input] of [['epoch', '@1704164645'], ['naive', '2024-01-02 03:04:05']]) {
    for (const utc of [false, true]) {
      test(`date ${form} TZ=${zone}${utc ? ' -u' : ''}`, async () => {
        const command = `date -d '${input}' ${utc ? '-u' : ''} '+%Y-%m-%dT%H:%M:%S%z|%s'`;
        const handle = runtime.spawn({ argv: ['bash', '-c', command], cwd: work, env: { TZ: zone }, graceMs: 100,
          stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
        const result = await handle.done;
        assert.equal(result.exitCode, 0); assert.equal(result.signal, null);
        assert.equal(handle.collected.stderr.readFrom(0).text, '');
        const local = form === 'epoch' ? epochLocal : `2024-01-02T03:04:05${epochLocal.slice(-5)}`;
        const expected = utc ? '2024-01-02T03:04:05+0000|1704164645\n'
          : `${local}|${form === 'epoch' ? 1704164645 : naiveEpoch}\n`;
        assert.equal(handle.collected.stdout.readFrom(0).text, expected);
        assert(await handle.waitForExit());
      });
    }
  }
}

for (const [input, expected] of [
  ['2024-01-02T03:04:05Z', '2024-01-02T03:04:05+0000|1704164645\n'],
  ['2024-01-02T03:04:05+08:00', '2024-01-01T19:04:05+0000|1704135845\n'],
]) {
  test(`date -u preserves explicit input zone: ${input}`, async () => {
    const handle = runtime.spawn({ argv: ['bash', '-c', `date -u -d '${input}' '+%Y-%m-%dT%H:%M:%S%z|%s'`],
      cwd: work, env: { TZ: 'America/New_York' }, graceMs: 100,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
    const result = await handle.done;
    assert.equal(result.exitCode, 0); assert.equal(result.signal, null);
    assert.equal(handle.collected.stderr.readFrom(0).text, '');
    assert.equal(handle.collected.stdout.readFrom(0).text, expected);
    assert(await handle.waitForExit());
  });
}
