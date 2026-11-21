// Local usage transport. Its only state is daily counters, with no session or
// tool identifiers. An opted-in app refreshes the lease; it expires if it goes away.
import { randomUUID } from 'node:crypto';

const MAX_COUNT = 100000;
const MAX_TOKENS = 1000000000000;
const LEASE = 3 * 60 * 1000;
const dayAt = at => new Date(at + 8 * 3600 * 1000).toISOString().slice(0, 10);
const vector = size => Array(size).fill(0);

export function createUsage(now = Date.now) {
  let lease = 0;
  let epoch = randomUUID();
  let days = new Map();

  function day() {
    const at = now();
    if (at >= lease) return;
    const key = dayAt(at);
    for (const date of days.keys()) if (date < dayAt(at - 7 * 86400000)) days.delete(date);
    if (!days.has(key)) days.set(key, { counts: vector(13), values: vector(10), plugins: vector(16) });
    return days.get(key);
  }

  function observe(event) {
    const committed = event.type === 'assistant/message';
    if (!committed && event.type !== 'assistant/attempt') return;
    const stats = day();
    if (!stats) return;
    const { counts, values } = stats;
    if (counts[0] === MAX_COUNT) { counts[12] = 1; return; }
    const stream = Array.isArray(event.data?.stream) ? event.data.stream : [];
    const last = stream.findLast(row => row.type === 'chunk' && row.chunk?.type === 'usage')?.chunk.usage;
    const raw = event.data?.usage ?? last;
    const evidence = raw?.reported ?? raw;
    const partial = !committed || event.data?.interrupted === true;
    function read(key) {
      const n = evidence?.[key];
      if (n == null) return [3, 0];
      if (!Number.isSafeInteger(n) || n < 0) return [4, 0];
      // A legacy adapter's normalized zero cannot prove field presence.
      if (!raw?.reported && n === 0) return [3, 0];
      return [partial ? 2 : n ? 0 : 1, n];
    }
    let [inputState, input] = read('inputTokens');
    const [outputState, output] = read('outputTokens');
    const [readState, cacheRead] = read('cacheReadTokens');
    const [writeState, cacheWrite] = read('cacheWriteTokens');
    const total = input + cacheRead + cacheWrite;
    if (inputState < 3) {
      if (!Number.isSafeInteger(total) || readState === 4 || writeState === 4) inputState = 4;
      else if (!partial && total > 0) inputState = 0;
    }
    counts[0]++;
    counts[1 + inputState]++;
    counts[6 + outputState]++;
    function add(i, n) {
      const result = values[i] + n;
      if (result > MAX_TOKENS) counts[12] = 1;
      values[i] = Math.min(result, MAX_TOKENS);
    }
    if (inputState < 2) {
      add(0, total); add(4, input); add(5, cacheRead); add(6, cacheWrite);
      if (readState < 2 && writeState < 2) values[7]++;
    } else if (inputState === 2) add(8, total);
    if (outputState < 2) add(1, output);
    else if (outputState === 2) add(9, output);
    if (inputState < 2 && outputState < 2) {
      counts[11]++; add(2, total); add(3, output);
    }
  }

  function beginPlugin() {
    if (now() >= lease) return () => {};
    const owner = epoch;
    const wall = performance.now();
    let settled = false;
    return outcome => {
      if (settled || owner !== epoch) return;
      settled = true;
      const row = day()?.plugins;
      if (!row) return;
      if (row[0] === MAX_COUNT) { row[15] = 1; return; }
      row[0]++;
      row[outcome]++;
      if (outcome !== 1) return;
      const elapsed = performance.now() - wall;
      const index = [250, 500, 1000, 2000, 5000, 10000, 30000, 60000, 180000].findIndex(n => elapsed <= n);
      row[index < 0 ? 14 : 5 + index]++;
    };
  }

  function pull(enabled) {
    if (!enabled) {
      lease = 0;
      epoch = randomUUID();
      days.clear();
    } else {
      lease = now() + LEASE;
      day();
    }
    return { v: 1, epoch, days: Object.fromEntries(days) };
  }
  return { pull, observe, beginPlugin };
}
