import { createHmac } from 'node:crypto';
import { expect, it, vi } from 'vitest';
import type { Env } from '../src/env';
import worker from '../src/index';
import { FakeDataset, makeCtx, makeEnv } from './fakes';

const iid = Buffer.alloc(16, 123).toString('base64url');
const secret = 'synthetic-v4-secret-for-tests';
const report = {
  v: 4, iid, day: '2026-11-20', app: '1.0.21', platform: 'android', maker: 'vivo', model: '', rom: '',
  base: [1, 1],
  chat_log: {
    counts: [3, 2, 0, 0, 1, 0, 1, 1, 0, 1, 0, 2, 0],
    values: [150, 9, 150, 9, 110, 40, 0, 1],
  },
};

async function post(env: Env, body: unknown = report) {
  const clock = vi.spyOn(Date, 'now').mockReturnValue(Date.parse('2026-11-20T16:00:00Z'));
  try {
    return await worker.fetch(new Request('https://go.dshtui.com/api/usage/v4', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    }), env, makeCtx());
  } finally { clock.mockRestore(); }
}

it('keeps a stable v4 hash and exact rows even when a day is retried', async () => {
  const v4 = new FakeDataset();
  const { env, usage } = makeEnv({ USAGE_SECRET: secret, USAGE_V4: v4 });
  expect((await post(env)).status).toBe(204);
  expect((await post(env)).status).toBe(204);
  const device = createHmac('sha256', secret).update(`usage-v4\n${iid}`).digest('hex').slice(0, 32);
  expect(v4.points.slice(0, 3)).toEqual([
    { indexes: [device], blobs: [report.day, device, 'base', report.app, 'android', 'vivo', '', ''], doubles: [1, 1, 3] },
    { indexes: [device], blobs: [report.day, device, 'chat_log_counts'], doubles: report.chat_log.counts },
    { indexes: [device], blobs: [report.day, device, 'chat_log_values'], doubles: report.chat_log.values },
  ]);
  expect(v4.points.slice(3)).toEqual(v4.points.slice(0, 3));
  expect(usage.points).toHaveLength(0);
});

it('rejects open or impossible dates, non-Android payloads and inconsistent final coverage', async () => {
  const v4 = new FakeDataset();
  const { env } = makeEnv({ USAGE_SECRET: secret, USAGE_V4: v4 });
  for (const body of [
    { ...report, day: '2026-11-21' },
    { ...report, day: '2026-11-12' },
    { ...report, day: '2026-11-31' },
    { ...report, platform: 'ohos' },
    { ...report, base: [0, 1] },
    { ...report, chat_log: { ...report.chat_log, counts: [3, 2, 0, 0, 1, 0, 1, 1, 0, 1, 0, 3, 0] } },
  ]) expect((await post(env, body)).status).toBe(400);
  expect(v4.points).toHaveLength(0);
  expect((await post(makeEnv({ USAGE_SECRET: secret }).env)).status).toBe(404);
});

it('writes independent sources and the exact accepted operation buckets', async () => {
  const v4 = new FakeDataset();
  const { env } = makeEnv({ USAGE_SECRET: secret, USAGE_V4: v4 });
  const counters = Array(13).fill(0);
  counters[0] = counters[3] = counters[8] = 1;
  const values = [0, 0, 0, 0, 0, 0, 0, 0, 20, 6];
  const blank = { counts: Array(13).fill(0), values: Array(10).fill(0) };
  const bins = [2, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  const body = { ...report, extra: { tavern: { counts: counters, values }, companion: blank, ssh_reconnect: bins } };
  expect((await post(env, body)).status).toBe(204);
  expect(v4.points.map(point => point.blobs[2])).toEqual([
    'base', 'chat_log_counts', 'chat_log_values', 'tavern_counts', 'tavern_values',
    'companion_counts', 'companion_values', 'ssh_reconnect',
  ]);
  expect(v4.points[0]!.doubles[2]).toBe(63 | (1 << 10));
  expect(v4.points[4]!.doubles).toEqual(values);
  expect((await post(env, { ...body, extra: { ...body.extra, ssh_reconnect: [5, ...bins.slice(1)] } })).status).toBe(400);
});

it('takes a switched-off daily-activity package: the base row and nothing else', async () => {
  const v4 = new FakeDataset();
  const { env } = makeEnv({ USAGE_SECRET: secret, USAGE_V4: v4 });
  const daily = {
    v: 4, iid, day: '2026-11-20', app: '1.0.21', platform: 'android', maker: '', model: '', rom: '', base: [1, 0],
  };
  expect((await post(env, daily)).status).toBe(204);
  const device = createHmac('sha256', secret).update('usage-v4\n' + iid).digest('hex').slice(0, 32);
  expect(v4.points).toEqual([
    { indexes: [device], blobs: [daily.day, device, 'base', daily.app, 'android', '', '', ''], doubles: [1, 0, 1] },
  ]);
  // Tokens or sources cannot come with the switch off, and a day without a
  // foreground flag is not an active day.
  expect((await post(env, { ...daily, extra: {} })).status).toBe(400);
  expect((await post(env, { ...daily, base: [0, 0] })).status).toBe(400);
  expect((await post(env, { ...daily, base: [0, 1] })).status).toBe(400);
});
