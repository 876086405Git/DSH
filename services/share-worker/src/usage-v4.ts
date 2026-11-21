import { json, readCapped } from './api';
import type { Env } from './env';
import { burstAllowed, clientKey } from './limits';
import { addDays, hmacHex, statsDay } from './stats';

const MAX_BODY = 16 * 1024;
const MAX_CALLS = 100_000;
const MAX_TOKENS = 1_000_000_000_000;
const DEVICE = /^(?:[a-z0-9][a-z0-9 ._-]{0,31})?$/;
const APP = /^\d{1,3}\.\d{1,3}\.\d{1,3}(?:-[0-9A-Za-z.]{1,20})?$/;

type Row = { type: string; counts: number[] };
type Report = { iid: string; day: string; app: string; maker: string; model: string; rom: string; rows: Row[] };

function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

function vector(value: unknown, lengths: readonly number[]): number[] | undefined {
  if (!Array.isArray(value) || value.length !== lengths.length ||
    !value.every((n, i) => Number.isSafeInteger(n) && n >= 0 && n <= lengths[i]!)) return undefined;
  return value as number[];
}

const operations = ['runtime_direct', 'runtime_proot', 'runtime_other',
  'ssh_initial', 'ssh_reconnect', 'relay_initial', 'relay_reconnect',
  'chat_turn_local', 'chat_turn_remote', 'chat_first_text_local', 'chat_first_text_remote', 'phone_task', 'update_download', 'update_install', 'call_connect', 'call_session', 'plugin_install',
  'plugin_execute', 'onboarding_local', 'onboarding_remote', 'onboarding_tavern', 'crash', 'anr'] as const;

function tokenRows(value: unknown, source: string): Row[] | undefined {
  const token = object(value);
  if (!token || Object.keys(token).length !== 2) return undefined;
  const counters = vector(token.counts, [...Array<number>(12).fill(MAX_CALLS), 1]);
  const limits = [...Array<number>(7).fill(MAX_TOKENS), MAX_CALLS];
  const values = vector(token.values, source === 'chat_log' && Array.isArray(token.values) && token.values.length === 8
    ? limits : [...limits, MAX_TOKENS, MAX_TOKENS]);
  if (!counters || !values) return undefined;
  const total = counters[0]!;
  const input = counters[1]! + counters[2]!;
  const output = counters[6]! + counters[7]!;
  const sum = (from: number, to: number) => counters.slice(from, to).reduce((a, b) => a + b, 0);
  if (sum(1, 6) !== total || sum(6, 11) !== total || counters[11]! > Math.min(input, output) ||
    counters[11]! < input + output - total || values[7]! > input ||
    values[2]! > values[0]! || values[3]! > values[1]! ||
    (!input && values[0] !== 0) || (!output && values[1] !== 0) ||
    (!counters[3] && (values[8] ?? 0) !== 0) || (!counters[8] && (values[9] ?? 0) !== 0) ||
    (!counters[11] && (values[2] !== 0 || values[3] !== 0))) return undefined;
  return [{ type: `${source}_counts`, counts: counters }, { type: `${source}_values`, counts: values }];
}

function parse(value: unknown, now: number): Report | undefined {
  const obj = object(value);
  if (!obj) return undefined;
  // A switched-off install sends the base row alone: no chat_log tokens and no
  // extra sources. Those packages carry daily activity and nothing else.
  const hasChat = Object.hasOwn(obj, 'chat_log');
  const hasExtra = Object.hasOwn(obj, 'extra');
  if (hasExtra && !hasChat) return undefined;
  if (Object.keys(obj).length !== 9 + (hasChat ? 1 : 0) + (hasExtra ? 1 : 0)) return undefined;
  const { v, iid, day, app, platform, maker, model, rom, base, chat_log } = obj;
  if (v !== 4 || platform !== 'android' || typeof iid !== 'string' || !/^[A-Za-z0-9_-]{21}[AQgw]$/.test(iid) ||
    typeof day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(day) || typeof app !== 'string' || !APP.test(app) ||
    typeof maker !== 'string' || !DEVICE.test(maker) || typeof model !== 'string' || !DEVICE.test(model) ||
    typeof rom !== 'string' || !DEVICE.test(rom)) return undefined;
  const date = Date.parse(`${day}T00:00:00Z`);
  const today = statsDay(now);
  if (!Number.isFinite(date) || new Date(date).toISOString().slice(0, 10) !== day || day < addDays(today, -7) || day >= today) return undefined;

  const flags = vector(base, [1, 1]);
  if (!flags || flags[1]! > flags[0]!) return undefined;
  const rows: Row[] = [];
  let mask = 1;
  if (hasChat) {
    const token = tokenRows(chat_log, 'chat_log');
    if (!token) return undefined;
    rows.push(...token);
    mask = 3;
  }
  if (hasExtra) {
    const extra = object(obj.extra);
    if (!extra || Object.keys(extra).some((key) =>
      key !== 'tavern' && key !== 'companion' && key !== 'engine' && !operations.some((kind) => key === kind))) return undefined;
    for (const source of ['tavern', 'companion']) {
      const pair = tokenRows(extra[source], source);
      if (!pair) return undefined;
      rows.push(...pair);
    }
    mask = 63;
    if (Object.hasOwn(extra, 'engine')) {
      const pair = tokenRows(extra.engine, 'engine');
      if (!pair) return undefined;
      rows.push(...pair);
      mask |= (1 << 27) | (1 << 28);
    }
    for (const [index, kind] of operations.entries()) {
      if (!Object.hasOwn(extra, kind)) continue;
      const bins = vector(extra[kind], [...Array<number>(15).fill(MAX_CALLS), 1]);
      if (!bins || !bins[0] || bins.slice(1, 5).reduce((a, b) => a + b, 0) !== bins[0] ||
        bins.slice(5, 15).reduce((a, b) => a + b, 0) !== bins[1]) return undefined;
      rows.push({ type: kind, counts: bins });
      mask |= 1 << (index + 6);
    }
  }
  if (!flags[0] && !rows.some((row) => row.counts[0]! > 0)) return undefined;
  return { iid, day, app, maker, model, rom, rows: [{ type: 'base', counts: [...flags, mask] }, ...rows] };
}

export async function usageV4(request: Request, env: Env, now = Date.now()): Promise<Response> {
  if (request.method !== 'POST') return json(405, { error: 'method_not_allowed' }, { Allow: 'POST' });
  const { USAGE_SECRET: secret, USAGE_V4: dataset } = env;
  if (!secret || !dataset) return json(404, { error: 'not_found' });
  if (!(await burstAllowed(env.USAGE_LIMIT, `usage-v4:${clientKey(request)}`))) return json(429, { error: 'too_many_requests' }, { 'Retry-After': '60' });
  if (!/^application\/json\s*(;|$)/i.test(request.headers.get('Content-Type') ?? '')) return json(415, { error: 'unsupported_media_type' });
  if (Number(request.headers.get('Content-Length') ?? '0') > MAX_BODY) return json(413, { error: 'too_large' });
  const bytes = await readCapped(request, MAX_BODY);
  if (!bytes) return json(413, { error: 'too_large' });
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    return json(400, { error: 'bad_json' });
  }
  const report = parse(body, now);
  if (!report) return json(400, { error: 'invalid_usage_v4' });
  const device = await hmacHex(secret, `usage-v4\n${report.iid}`, 16);
  // Analytics writes are asynchronous. A synchronous failure can leave some rows
  // written; the report deduplicates immutable retries by day, device and row type.
  for (const row of report.rows) {
    const blobs = [report.day, device, row.type];
    if (row.type === 'base') blobs.push(report.app, 'android', report.maker, report.model, report.rom);
    dataset.writeDataPoint({ indexes: [device], blobs, doubles: row.counts });
  }
  return new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store' } });
}
