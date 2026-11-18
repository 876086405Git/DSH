import { isDeepStrictEqual } from 'node:util';

// Require the actual recorded payload, including duplicate delivery and no extra send flag.
export function checkSiriRows(rows) {
  const expected = [
    { kind: 'new', text: '测试 DSH\nsecond line' },
    { kind: 'new', text: '测试 DSH\nsecond line' },
    { kind: 'voice' }, { kind: 'new' },
  ];
  const problems = [];
  const siri = rows.filter((row) => row.group === 'siri');
  for (const name of ['queued', 'attached']) {
    const matches = siri.filter((row) => row.name === name);
    if (matches.length !== 1 || !isDeepStrictEqual(matches[0].entries, expected)) {
      problems.push(`siri ${name}: expected one row with four exact ordered handoffs`);
    }
  }
  if (siri.length !== 2) problems.push('siri: expected exactly two result rows');
  return problems;
}
