import test from 'node:test';
import assert from 'node:assert/strict';
import { checkSiriRows } from './siri-results.mjs';

const entries = [
  { kind: 'new', text: '测试 DSH\nsecond line' },
  { kind: 'new', text: '测试 DSH\nsecond line' },
  { kind: 'voice' }, { kind: 'new' },
];
const rows = () => ['queued', 'attached'].map((name) => ({ group: 'siri', name, entries: structuredClone(entries) }));
test('accept exact queued and attached payloads', () => assert.deepEqual(checkSiriRows(rows()), []));
test('reject absent, duplicate, unknown or incomplete result rows', () => {
  for (const sample of [[], rows().slice(0, 1), [...rows(), rows()[0]], [...rows(), { group: 'siri', name: 'unexpected' }]]) {
    assert.ok(checkSiriRows(sample).length);
  }
});
test('reject dropped duplicates, reordered, replayed and auto-send entries', () => {
  for (const mutate of [
    (x) => x.pop(), (x) => x.reverse(), (x) => x.push(x[0]),
    (x) => { x[0].send = 'true'; }, (x) => { x[0].text = 'wrong'; },
  ]) {
    const sample = rows();
    mutate(sample[0].entries);
    assert.ok(checkSiriRows(sample).length);
  }
});
